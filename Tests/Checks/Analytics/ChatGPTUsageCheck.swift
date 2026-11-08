import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
enum ChatGPTUsageCheck {
    static func parse(_ raw: String) throws -> [AccountUsageDay] {
        try AccountUsageParser.parseWebResponse(Data(raw.utf8))
    }

    static func main() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-20T17:00:00Z")!
        var shanghai = AccountUsageDay.calendar
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let credential = ChatGPTUsageCredentials(token: "fixture-token", accountID: "fixture-account")
        let request = ChatGPTUsageClient.request(credentials: credential, now: now, calendar: shanghai)
        let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: url.queryItems!.map { ($0.name, $0.value!) })
        precondition(url.host == "chatgpt.com" && url.scheme == "https")
        precondition(url.path == "/backend-api/wham/analytics/daily-workspace-usage-counts")
        precondition(query == ["start_date": "2026-09-22", "end_date": "2026-10-22", "group_by": "day", "workspace_user": "true"])
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        precondition(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "fixture-account")
        precondition(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)

        var newYork = AccountUsageDay.calendar
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        for (date, start, end) in [("2026-11-02T01:00:00Z", "2026-10-03", "2026-11-02"),
                                   ("2026-03-09T01:00:00Z", "2026-02-07", "2026-03-09")] {
            let request = ChatGPTUsageClient.request(credentials: credential,
                now: ISO8601DateFormatter().date(from: date)!, calendar: newYork)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.first(where: { $0.name == "start_date" })?.value == start)
            precondition(query.first(where: { $0.name == "end_date" })?.value == end)
        }

        let days = try parse(#"{"data":[{"date":"2026-10-21","totals":{"text_total_tokens":"9007199254740993"}},{"date":"2026-10-20","totals":{"cached_text_input_tokens":10,"uncached_text_input_tokens":"20","text_output_tokens":30}},{"date":"2026-10-19","totals":{"text_total_tokens":0}},{"date":"2026-10-18","totals":{"credits":12}},{"date":"2026-10-19","totals":{"text_total_tokens":0}}]}"#)
        precondition(days.count == 4 && days.last?.tokens == 9_007_199_254_740_993)
        precondition(days[0].tokens == nil && days[1].tokens == 0 && days[2].tokens == 60)
        let zeroWithParts = try parse(#"{"data":[{"date":"2026-10-21","totals":{"text_total_tokens":0,"cached_text_input_tokens":9,"uncached_text_input_tokens":8,"text_output_tokens":7}}]}"#)
        precondition(zeroWithParts.first?.tokens == 0)
        let partial = try parse(#"{"data":[{"date":"2026-10-21","totals":{"cached_text_input_tokens":9,"text_output_tokens":7}}]}"#)
        precondition(partial.first?.tokens == nil)

        for invalid in [
            #"{"data":null}"#,
            #"{}"#,
            #"{"data":[],"units":"percent"}"#,
            #"{"data":[],"group_by":"month"}"#,
            #"{"data":[{"date":"2026-02-30","totals":{"text_total_tokens":1}}]}"#,
            #"{"data":[{"date":"2026-10-21","totals":{"text_total_tokens":-1}}]}"#,
            #"{"data":[{"date":"2026-10-21","totals":{"text_total_tokens":true}}]}"#,
            #"{"data":[{"date":"2026-10-21","totals":{"text_total_tokens":1.5}}]}"#,
            #"{"data":[{"date":"2026-10-21","totals":{"text_total_tokens":"9223372036854775808"}}]}"#,
            #"{"data":[{"date":"2026-10-21","totals":{"cached_text_input_tokens":9223372036854775807,"uncached_text_input_tokens":1,"text_output_tokens":0}}]}"#,
            #"{"data":[{"date":"2026-10-21","totals":{"text_total_tokens":1}},{"date":"2026-10-21","totals":{"text_total_tokens":2}}]}"#
        ] {
            do { _ = try parse(invalid); preconditionFailure("Invalid web analytics accepted") }
            catch let error as AccountUsageError { precondition(error == .invalidResponse) }
        }

        let baseline = AccountUsagePayload(summary: AccountUsageSummary(lifetimeTokens: 99),
            days: [AccountUsageDay(day: "2026-10-20", tokens: 5)!], fetchedAt: now.addingTimeInterval(-1))
        let combined = baseline.includingWebUsage(days, now: now, calendar: shanghai)
        precondition(combined.dailySource == .chatGPT && combined.days == days)
        precondition(combined.summary == baseline.summary && combined.fetchedAt == now)
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = shanghai.timeZone
        precondition(baseline.includingWebUsage(days, now: now, calendar: buddhist) == combined)
        // Whole-series replacement prevents incompatible historical totals from
        // being spliced into a web total. Explicit zero is a reported day, too.
        precondition(combined.days?.first(where: { $0.day == "2026-10-20" })?.tokens == 60)
        precondition(baseline.includingWebUsage(zeroWithParts, now: now, calendar: shanghai).dailySource == .chatGPT)
        precondition(baseline.includingWebUsage(partial, now: now, calendar: shanghai) == baseline)
        precondition(baseline.includingWebUsage([], now: now, calendar: shanghai) == baseline)

        let claims = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"fixture-account"}}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let token = "fixture.\(claims).signature"
        let auth = try JSONSerialization.data(withJSONObject: ["result": ["authMethod": "chatgpt", "authToken": token]])
        let parsed = try ChatGPTUsageCredentials.parseResponse(auth)
        precondition(parsed.token == token && parsed.accountID == "fixture-account")
        for invalid in [#"{"error":{"code":-32601}}"#, #"{"result":{"authMethod":"apikey","authToken":"secret-fixture"}}"#,
                        #"{"result":{"authMethod":"chatgpt","authToken":null}}"#, #"{"result":{"authMethod":"chatgpt","authToken":"invalid.jwt.token"}}"#] {
            do { _ = try ChatGPTUsageCredentials.parseResponse(Data(invalid.utf8)); preconditionFailure("Invalid auth accepted") }
            catch let error as AccountUsageError { precondition(error == .unsupported) }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UsageFixtureProtocol.self]
        let client = ChatGPTUsageClient(session: URLSession(configuration: config))
        let fetched = try await client.readDailyUsage(credentials: credential, now: now, calendar: shanghai)
        precondition(fetched.first?.tokens == 123 && fetched.first?.day == "2026-10-21")

        let transientConfig = URLSessionConfiguration.ephemeral
        transientConfig.protocolClasses = [TransientUsageFixtureProtocol.self]
        let transientClient = ChatGPTUsageClient(session: URLSession(configuration: transientConfig))
        let recovered = try await transientClient.readDailyUsage(credentials: credential, now: now, calendar: shanghai)
        precondition(recovered == fetched && TransientUsageFixtureProtocol.counter.count == 3)

        TransientUsageFixtureProtocol.counter.reset()
        do {
            _ = try await transientClient.readDailyUsage(credentials: credential, now: now, calendar: shanghai,
                isCurrent: { TransientUsageFixtureProtocol.counter.count == 0 })
            preconditionFailure("An invalidated session must stop web retries")
        } catch is CancellationError {}
        precondition(TransientUsageFixtureProtocol.counter.count == 1)
        print("ChatGPT daily usage request, HTTP, parsing, provenance, fallback and date-boundary checks passed")
    }
}

private final class TransientUsageFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let counter = RequestCounter()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let statusCode = Self.counter.increment() < 3 ? 503 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"date":"2026-10-21","totals":{"text_total_tokens":123}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var count: Int { lock.withLock { requests } }
    func reset() { lock.withLock { requests = 0 } }
    func increment() -> Int {
        lock.withLock {
            requests += 1
            return requests
        }
    }
}

private final class UsageFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.host == "chatgpt.com")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"date":"2026-10-21","totals":{"text_total_tokens":123}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
