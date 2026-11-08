import Foundation

public actor CodexAppServerClient {
    private let codexHome: URL?
    private let explicitExecutableURL: URL?
    private let appBundleURLs: [URL]
    private let webUsageClient: ChatGPTUsageClient
    private var process: Process?
    private var input: FileHandle?
    private var readTask: Task<Void, Never>?
    private var nextID = 1
    private var initializationID: Int?
    private var initialized = false
    private var initializationError: CodexClientError?
    private var sessionID = UUID()
    private var lastExitStatus: Int32?
    private var processDiagnostics = CodexProcessDiagnostics()
    private var errorOutput: FileHandle?
    private var pendingReads: [Int: CheckedContinuation<RateLimitPayload, Error>] = [:]
    private var pendingUsageReads: [Int: CheckedContinuation<AccountUsagePayload, Error>] = [:]
    private var pendingUsageAuthReads: [Int: CheckedContinuation<ChatGPTUsageCredentials, Error>] = [:]
    private var pendingAccountReads: [Int: CheckedContinuation<CodexAccount?, Error>] = [:]
    private var pendingLoginStarts: [Int: CheckedContinuation<CodexLoginSession, Error>] = [:]
    private var pendingLogouts: [Int: CheckedContinuation<Void, Error>] = [:]
    private var pendingLoginCompletions: [String: CheckedContinuation<Void, Error>] = [:]
    private var completedLogins: [String: Result<Void, Error>] = [:]
    private var latestSnapshot: RateLimitPayload?
    private var executablePath: String?
    private var protocolStage = "not started"

    public static func executableCandidatePaths(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appBundleURLs: [URL] = []
    ) -> [String] {
        CodexExecutableLocator.candidatePaths(home: home, environment: environment, appBundleURLs: appBundleURLs)
    }

    public static func locateExecutable(appBundleURLs: [URL] = []) -> URL? {
        CodexExecutableLocator.locate(appBundleURLs: appBundleURLs)
    }

    deinit {
        readTask?.cancel()
        errorOutput?.readabilityHandler = nil
        process?.terminate()
    }

    public init(codexHome: URL? = nil, executableURL: URL? = nil, appBundleURLs: [URL] = [],
                webUsageClient: ChatGPTUsageClient = ChatGPTUsageClient()) {
        self.codexHome = codexHome
        self.explicitExecutableURL = executableURL
        self.appBundleURLs = appBundleURLs
        self.webUsageClient = webUsageClient
    }

    public func readRateLimits() async throws -> RateLimitPayload {
        if process?.isRunning != true || initializationError != nil { try start() }
        let session = sessionID
        try await ensureInitialized()
        try requireInitializedSession(session)

        protocolStage = "waiting for account/rateLimits/read"
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingReads[id] = continuation
            do {
                try send(["method": "account/rateLimits/read", "id": id])
            } catch {
                pendingReads.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                self.timeoutRead(id: id)
            }
        }
    }

    public func readAccountUsage() async throws -> AccountUsagePayload {
        if process?.isRunning != true || initializationError != nil { try start() }
        let session = sessionID
        try await ensureInitialized()
        try requireInitializedSession(session)
        protocolStage = "waiting for account/usage/read"
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingUsageReads[id] = continuation
            do {
                // Omitting threadId requests full account history. Date filters
                // operate on returned day buckets; unsupported params are not sent.
                try send(["method": "account/usage/read", "id": id, "params": [:]])
            } catch {
                pendingUsageReads.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                self.timeoutUsageRead(id: id)
            }
        }
    }

    public func readAccount(refreshToken: Bool = false) async throws -> CodexAccount? {
        if process?.isRunning != true || initializationError != nil { try start() }
        let session = sessionID
        try await ensureInitialized()
        try requireInitializedSession(session)

        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingAccountReads[id] = continuation
            do {
                try send(["method": "account/read", "id": id, "params": ["refreshToken": refreshToken]])
            } catch {
                pendingAccountReads.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                self.timeoutAccountRead(id: id)
            }
        }
    }

    /// Call between matching account/read responses, as UsageStore does. A web
    /// failure never discards usable Codex history or changes quota polling.
    public func readAccountUsageIncludingToday(now: Date = Date(), calendar: Calendar = .current) async throws -> AccountUsagePayload {
        let usage = try await readAccountUsage()
        let session = sessionID
        do {
            let credentials = try await readUsageCredentials()
            try requireInitializedSession(session)
            let days = try await webUsageClient.readDailyUsage(credentials: credentials, now: now, calendar: calendar,
                isCurrent: {
                    do {
                        try await self.requireInitializedSession(session)
                        return true
                    } catch {
                        return false
                    }
                })
            try requireInitializedSession(session)
            return usage.includingWebUsage(days, now: now, calendar: calendar)
        } catch {
            // A profile/process handoff must still invalidate the whole request.
            try requireInitializedSession(session)
            return usage
        }
    }

    private func readUsageCredentials() async throws -> ChatGPTUsageCredentials {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingUsageAuthReads[id] = continuation
            do {
                // Compatibility RPC: Codex remains responsible for credential
                // storage and refresh. Do not inspect auth.json or the Keychain.
                try send(["method": "getAuthStatus", "id": id,
                          "params": ["includeToken": true, "refreshToken": false]])
            } catch {
                pendingUsageAuthReads.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                self.pendingUsageAuthReads.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
            }
        }
    }

    public func logoutAccount() async throws {
        if process?.isRunning != true { try start() }
        let session = sessionID
        try await ensureInitialized()
        try requireInitializedSession(session)

        let id = nextID
        nextID += 1
        try await withCheckedThrowingContinuation { continuation in
            pendingLogouts[id] = continuation
            do {
                try send(["method": "account/logout", "id": id])
            } catch {
                pendingLogouts.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                self.timeoutLogout(id: id)
            }
        }
    }

    public func startChatGPTLogin() async throws -> CodexLoginSession {
        if process?.isRunning != true { try start() }
        let session = sessionID
        try await ensureInitialized()
        try requireInitializedSession(session)

        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingLoginStarts[id] = continuation
            do {
                try send([
                    "method": "account/login/start",
                    "id": id,
                    "params": ["type": "chatgpt", "appBrand": "codex", "codexStreamlinedLogin": true]
                ])
            } catch {
                pendingLoginStarts.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                self.timeoutLoginStart(id: id)
            }
        }
    }

    public func waitForLogin(id loginID: String) async throws {
        guard initialized, process?.isRunning == true else { throw CodexClientError.disconnected }
        if let result = completedLogins.removeValue(forKey: loginID) {
            return try result.get()
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingLoginCompletions[loginID] = continuation
            Task {
                try? await Task.sleep(for: .seconds(300))
                self.timeoutLoginCompletion(id: loginID)
            }
        }
    }

    public func stop() {
        sessionID = UUID()
        initialized = false
        initializationID = nil
        initializationError = nil
        errorOutput?.readabilityHandler = nil
        errorOutput = nil
        readTask?.cancel()
        readTask = nil
        input?.closeFile()
        input = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        completedLogins.removeAll()
        failPending(with: CodexClientError.disconnected)
    }

    public func diagnosticSummary() -> String {
        let inheritedHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let homeDescription = codexHome?.path ?? inheritedHome
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        var lines = [
            AppLocalization.format("Executable: %@", executablePath ?? explicitExecutableURL?.path ?? AppLocalization.text("not resolved")),
            AppLocalization.format("CODEX_HOME: %@", homeDescription),
            AppLocalization.format("Protocol stage: %@", AppLocalization.text(protocolStage)),
            AppLocalization.format("Process running: %@", AppLocalization.text(process?.isRunning == true ? "yes" : "no"))
        ]
        if executablePath == nil {
            if !appBundleURLs.isEmpty {
                lines.append(AppLocalization.format("Desktop app candidates:\n%@", appBundleURLs.map(\.path).joined(separator: "\n")))
            }
            lines.append(AppLocalization.format("Executable search paths:\n%@", Self.executableCandidatePaths(appBundleURLs: appBundleURLs).joined(separator: "\n")))
        }
        if let lastExitStatus {
            lines.append(AppLocalization.format("Process exit status: %d", lastExitStatus))
        }
        let stderr = processDiagnostics.summary()
        if !stderr.isEmpty {
            lines.append(AppLocalization.format("Codex process errors:\n%@", stderr))
        }
        return CodexProcessDiagnostics.redact(lines.joined(separator: "\n"))
    }

    private func timeoutRead(id: Int) {
        pendingReads.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
    }

    private func timeoutUsageRead(id: Int) {
        pendingUsageReads.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
    }

    private func timeoutAccountRead(id: Int) {
        pendingAccountReads.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
    }

    private func timeoutLoginStart(id: Int) {
        pendingLoginStarts.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
    }

    private func timeoutLogout(id: Int) {
        pendingLogouts.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
    }

    private func timeoutLoginCompletion(id: String) {
        pendingLoginCompletions.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
    }

    private func start() throws {
        // A dead process may still have queued stdout callbacks and requests.
        // Finish those requests before replacing the connection identity.
        stop()
        let executable = explicitExecutableURL?.path
            ?? Self.locateExecutable(appBundleURLs: appBundleURLs)?.path
        guard let executable else {
            throw CodexClientError.executableNotFound
        }

        sessionID = UUID()
        let session = sessionID
        initialized = false
        initializationID = nil
        initializationError = nil
        lastExitStatus = nil
        processDiagnostics = CodexProcessDiagnostics()
        let diagnostics = processDiagnostics
        executablePath = executable
        protocolStage = "starting app-server"

        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { handle in
            do {
                guard let data = try handle.read(upToCount: 4_096), !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                diagnostics.append(data)
            } catch {
                handle.readabilityHandler = nil
            }
        }
        errorOutput = stderr.fileHandleForReading
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { await self?.recordExitStatus(session: session, status: status) }
        }
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let executableDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let requiredPaths = [executableDirectory, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (requiredPaths + [inheritedPath]).joined(separator: ":")
        if let codexHome {
            environment["CODEX_HOME"] = codexHome.path
        }
        process.environment = environment

        do { try process.run() } catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            errorOutput = nil
            throw CodexClientError.launch(error.localizedDescription)
        }

        self.process = process
        self.input = stdin.fileHandleForWriting
        self.readTask = Task { [weak self] in
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    guard let data = line.data(using: .utf8) else { continue }
                    await self?.handle(data, session: session)
                }
                await self?.connectionEnded(session: session)
            } catch {
                await self?.connectionEnded(session: session)
            }
        }
    }

    private func ensureInitialized() async throws {
        try Task.checkCancellation()
        if initialized { return }
        if let failure = initializationError { throw failure }
        let session = sessionID
        if initializationID == nil {
            let id = nextID
            nextID += 1
            initializationID = id
            protocolStage = "waiting for initialize response"
            try send([
                "method": "initialize",
                "id": id,
                "params": ["clientInfo": ["name": "quota_bar", "title": "QuotaBar", "version": "1.7.5"]]
            ])
        }

        let deadline = ContinuousClock.now + .seconds(30)
        while !initialized {
            try Task.checkCancellation()
            guard session == sessionID else { throw CodexClientError.disconnected }
            if let failure = initializationError { throw failure }
            guard process?.isRunning == true else { throw CodexClientError.disconnected }
            if ContinuousClock.now >= deadline {
                stop()
                throw CodexClientError.timedOut
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // A replacement process can initialize while this task is sleeping.
        try requireInitializedSession(session)
    }

    private func requireInitializedSession(_ session: UUID) throws {
        try Task.checkCancellation()
        guard session == sessionID, initialized, process?.isRunning == true else {
            throw CodexClientError.disconnected
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw CodexClientError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        do { try input.write(contentsOf: data) } catch { throw CodexClientError.disconnected }
    }

    private func handle(_ data: Data, session: UUID) {
        guard session == sessionID else { return }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = (root["id"] as? NSNumber)?.intValue, id == initializationID {
            initializationID = nil
            if let error = responseError(root) {
                initializationError = error
                protocolStage = "initialize rejected"
                return
            }
            guard root["result"] is [String: Any] else {
                initializationError = .invalidResponse
                protocolStage = "initialize rejected"
                return
            }
            do {
                try send(["method": "initialized", "params": [:]])
                initialized = true
                protocolStage = "initialized"
            } catch {
                initializationError = .disconnected
            }
            return
        }

        if let id = (root["id"] as? NSNumber)?.intValue, let continuation = pendingReads.removeValue(forKey: id) {
            do {
                guard let payload = try RateLimitParser.parseResponse(data) else { throw CodexClientError.invalidResponse }
                latestSnapshot = payload
                protocolStage = "rate limits received"
                continuation.resume(returning: payload)
            } catch {
                continuation.resume(throwing: error)
            }
            return
        }

        if let id = (root["id"] as? NSNumber)?.intValue, let continuation = pendingUsageReads.removeValue(forKey: id) {
            do {
                let usage = try AccountUsageParser.parseResponse(data)
                protocolStage = "account usage received"
                continuation.resume(returning: usage)
            } catch {
                continuation.resume(throwing: error)
            }
            return
        }

        if let id = (root["id"] as? NSNumber)?.intValue, let continuation = pendingUsageAuthReads.removeValue(forKey: id) {
            do { continuation.resume(returning: try ChatGPTUsageCredentials.parseResponse(data)) }
            catch { continuation.resume(throwing: error) }
            return
        }

        if let id = (root["id"] as? NSNumber)?.intValue, let continuation = pendingAccountReads.removeValue(forKey: id) {
            if let error = responseError(root) {
                continuation.resume(throwing: error)
            } else if let result = root["result"] as? [String: Any] {
                continuation.resume(returning: CodexAccount.parse(result["account"]))
            } else {
                continuation.resume(throwing: CodexClientError.invalidResponse)
            }
            return
        }

        if let id = (root["id"] as? NSNumber)?.intValue, let continuation = pendingLoginStarts.removeValue(forKey: id) {
            if let error = responseError(root) {
                continuation.resume(throwing: error)
            } else if let result = root["result"] as? [String: Any],
                      let loginID = result["loginId"] as? String,
                      let authURLString = result["authUrl"] as? String,
                      let authURL = URL(string: authURLString) {
                continuation.resume(returning: CodexLoginSession(id: loginID, authorizationURL: authURL))
            } else {
                continuation.resume(throwing: CodexClientError.invalidResponse)
            }
            return
        }

        if let id = (root["id"] as? NSNumber)?.intValue, let continuation = pendingLogouts.removeValue(forKey: id) {
            if let error = responseError(root) {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
            return
        }

        if root["method"] as? String == "account/login/completed",
           let params = root["params"] as? [String: Any],
           let loginID = params["loginId"] as? String {
            let success = params["success"] as? Bool ?? false
            let result: Result<Void, Error> = success
                ? .success(())
                : .failure(CodexClientError.server(params["error"] as? String ?? "OpenAI sign-in did not complete."))
            if let continuation = pendingLoginCompletions.removeValue(forKey: loginID) {
                continuation.resume(with: result)
            } else {
                completedLogins[loginID] = result
            }
            return
        }

        if let payload = try? RateLimitParser.parseNotification(data) { latestSnapshot = payload }
    }

    private func recordExitStatus(session: UUID, status: Int32) {
        guard session == sessionID else { return }
        lastExitStatus = status
    }

    private func connectionEnded(session: UUID) {
        guard session == sessionID else { return }
        if let process, !process.isRunning { lastExitStatus = process.terminationStatus }
        initialized = false
        process = nil
        input = nil
        initializationID = nil
        protocolStage = "app-server disconnected"
        failPending(with: CodexClientError.disconnected)
    }

    private func failPending(with error: Error) {
        let continuations = pendingReads.values
        pendingReads.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        let usageContinuations = pendingUsageReads.values
        pendingUsageReads.removeAll()
        usageContinuations.forEach { $0.resume(throwing: error) }
        let authContinuations = pendingUsageAuthReads.values
        pendingUsageAuthReads.removeAll()
        authContinuations.forEach { $0.resume(throwing: error) }
        let accountContinuations = pendingAccountReads.values
        pendingAccountReads.removeAll()
        accountContinuations.forEach { $0.resume(throwing: error) }
        let loginContinuations = pendingLoginStarts.values
        pendingLoginStarts.removeAll()
        loginContinuations.forEach { $0.resume(throwing: error) }
        let logoutContinuations = pendingLogouts.values
        pendingLogouts.removeAll()
        logoutContinuations.forEach { $0.resume(throwing: error) }
        let completionContinuations = pendingLoginCompletions.values
        pendingLoginCompletions.removeAll()
        completionContinuations.forEach { $0.resume(throwing: error) }
    }

    private func responseError(_ root: [String: Any]) -> CodexClientError? {
        guard let error = root["error"] as? [String: Any] else { return nil }
        return .server(error["message"] as? String ?? "Codex returned an unknown error.")
    }
}

public struct CodexAccount: Equatable, Sendable {
    public let type: String
    public let email: String?
    public let planType: String?

    fileprivate static func parse(_ value: Any?) -> CodexAccount? {
        guard let raw = value as? [String: Any], let type = raw["type"] as? String else { return nil }
        return CodexAccount(type: type, email: raw["email"] as? String, planType: raw["planType"] as? String)
    }
}

public struct CodexLoginSession: Equatable, Sendable {
    public let id: String
    public let authorizationURL: URL
}
