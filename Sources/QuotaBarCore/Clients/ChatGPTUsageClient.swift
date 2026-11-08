import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Short-lived credentials exported by the selected app-server session. They
/// are never read from disk, persisted, or included in diagnostics/errors.
struct ChatGPTUsageCredentials: Sendable {
    let token: String
    let accountID: String

    static func parseResponse(_ data: Data) throws -> Self {
        struct Result: Decodable { let authMethod: String?; let authToken: String? }
        struct Response: Decodable { let result: Result? }
        struct Claims: Decodable {
            struct Account: Decodable { let chatgpt_account_id: String? }
            let account: Account?
            enum CodingKeys: String, CodingKey { case account = "https://api.openai.com/auth" }
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.result?.authMethod == "chatgpt",
              let token = response.result?.authToken, !token.isEmpty,
              token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw AccountUsageError.unsupported }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { throw AccountUsageError.unsupported }
        var encoded = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let claims = try? JSONDecoder().decode(Claims.self, from: data),
              let accountID = claims.account?.chatgpt_account_id, !accountID.isEmpty,
              accountID.utf8.allSatisfy({ (33...126).contains($0) }) else { throw AccountUsageError.unsupported }
        // Claims supply routing metadata only; Codex and the HTTPS service
        // authenticate the token. This does not locally verify a JWT signature.
        return Self(token: token, accountID: accountID)
    }
}

public final class ChatGPTUsageClient: Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        self.session = URLSession(configuration: config, delegate: NoUsageRedirects(), delegateQueue: nil)
    }

    // Allows offline contract tests without contacting a user's account.
    init(session: URLSession) { self.session = session }

    deinit { session.invalidateAndCancel() }

    static func request(credentials: ChatGPTUsageCredentials, now: Date, calendar: Calendar) -> URLRequest {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = calendar.timeZone
        let today = local.startOfDay(for: now)
        let start = local.date(byAdding: .day, value: -29, to: today)!
        let end = local.date(byAdding: .day, value: 1, to: today)!
        var url = URLComponents(string: "https://chatgpt.com/backend-api/wham/analytics/daily-workspace-usage-counts")!
        url.queryItems = [
            URLQueryItem(name: "start_date", value: AccountUsageDay.key(for: start, calendar: local)),
            // The reference extension uses an exclusive end date: tomorrow
            // includes today's bucket, including around local midnight and DST.
            URLQueryItem(name: "end_date", value: AccountUsageDay.key(for: end, calendar: local)),
            URLQueryItem(name: "group_by", value: "day"),
            URLQueryItem(name: "workspace_user", value: "true")
        ]
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func readDailyUsage(credentials: ChatGPTUsageCredentials, now: Date = Date(),
                        calendar: Calendar = .current,
                        isCurrent: @Sendable () async -> Bool = { true }) async throws -> [AccountUsageDay] {
        do {
            return try await UsageFetchRetry.run(shouldRetry: { error in
                if let failure = error as? UsageHTTPFailure {
                    return failure.statusCode == 408 || failure.statusCode == 429 || (500...599).contains(failure.statusCode)
                }
                return (error as? AccountUsageError) != .invalidResponse
            }) {
                guard await isCurrent() else { throw CancellationError() }
                let (data, response) = try await self.session.data(for: Self.request(credentials: credentials, now: now, calendar: calendar))
                guard let http = response as? HTTPURLResponse else { throw AccountUsageError.invalidResponse }
                guard http.statusCode == 200 else { throw UsageHTTPFailure(statusCode: http.statusCode) }
                guard data.count <= 2_000_000 else { throw AccountUsageError.invalidResponse }
                return try AccountUsageParser.parseWebResponse(data)
            }
        } catch is UsageHTTPFailure {
            throw AccountUsageError.invalidResponse
        }
    }
}

private struct UsageHTTPFailure: Error {
    let statusCode: Int
}

private final class NoUsageRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
