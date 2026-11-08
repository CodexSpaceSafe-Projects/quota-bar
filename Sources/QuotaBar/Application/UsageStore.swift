import AppKit
import QuotaBarCore
import Foundation
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
    private static let defaultAccountID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    @Published private(set) var payload: RateLimitPayload?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var operationError: String?
    @Published private(set) var quotaHistory: AccountQuotaHistory?
    @Published private(set) var historyError: String?
    @Published private(set) var analytics: AccountUsagePayload?
    @Published private(set) var analyticsError: String?
    @Published private(set) var isLoadingAnalytics = false
    @Published var analyticsRange: AccountUsageRange = .week {
        didSet { UserDefaults.standard.set(analyticsRange.rawValue, forKey: Self.analyticsRangeKey) }
    }
    @Published var language: AppLanguage {
        didSet {
            AppLocalization.language = language
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
            renderLocalizedMessages()
        }
    }
    @Published var alertThreshold: Int {
        didSet { UserDefaults.standard.set(alertThreshold, forKey: Self.thresholdKey) }
    }
    @Published private(set) var launchAtLogin = false
    @Published var displayMode: MenuBarDisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: Self.displayModeKey) }
    }
    @Published private(set) var accounts: [AccountProfile]
    @Published var activeAccountID: UUID {
        didSet { UserDefaults.standard.set(activeAccountID.uuidString, forKey: Self.activeAccountKey) }
    }
    @Published private(set) var celebration: Celebration?
    @Published private(set) var isSwitchingCodexAccount = false
    @Published private(set) var accountSwitchStatus: String?

    private var client: CodexAppServerClient
    private var clientGeneration = UUID()
    private var rediscoverClientOnNextRefresh = false
    private let quotaHistoryStore = AccountQuotaHistoryStore()
    private let previewMode: Bool
    private var pollingTask: Task<Void, Never>?
    private var analyticsPollingTask: Task<Void, Never>?
    private var analyticsGeneration = UUID()
    private var analyticsAccountKey: String?
    private var lastAnalyticsAttemptAt: Date?
    private var loginTasks: [UUID: Task<Void, Never>] = [:]
    private var loginClients: [UUID: CodexAppServerClient] = [:]
    private var pendingNotificationIDs = Set<String>()
    private var lastUsageDiagnostics: String?
    // Retain message sources for language changes; renderers capture local values,
    // rather than this store, so keeping a message cannot create a retain cycle.
    private var errorMessageRenderer: (() -> String?)?
    private var operationErrorRenderer: (() -> String?)?
    private var historyErrorRenderer: (() -> String?)?
    private var analyticsErrorRenderer: (() -> String?)?
    private var accountSwitchStatusRenderer: (() -> String?)?
    private var celebrationRenderer: (() -> Celebration?)?
    private var celebrationGeneration = UUID()
    private static let languageKey = "appLanguage"
    private static let thresholdKey = "alertThreshold"
    private static let notifiedResetKey = "lastNotifiedReset"
    private static let displayModeKey = "menuBarDisplayMode"
    private static let accountsKey = "accountProfiles"
    private static let activeAccountKey = "activeAccountID"
    private static let resetMilestoneKey = "lastBankedReset"
    private static let selectedCodexAppKey = "selectedCodexAppPath"
    private static let analyticsRangeKey = "analyticsDays"

    init(previewMode: Bool = false) {
        let savedLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.languageKey) ?? "") ?? .system
        AppLocalization.language = savedLanguage
        self.language = savedLanguage
        let defaultAccount = AccountProfile(id: Self.defaultAccountID, name: "Default", homePath: nil, email: nil)
        let loadedAccounts: [AccountProfile]
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([AccountProfile].self, from: data), !decoded.isEmpty {
            let separateAccounts = decoded.filter { $0.homePath != nil }
            loadedAccounts = [defaultAccount] + separateAccounts
        } else {
            loadedAccounts = [defaultAccount]
        }
        let savedAccount = UserDefaults.standard.string(forKey: Self.activeAccountKey).flatMap(UUID.init(uuidString:))
        let migratedSavedAccount = savedAccount.flatMap { candidate in
            decodedDefaultID(from: UserDefaults.standard.data(forKey: Self.accountsKey)) == candidate
                ? Self.defaultAccountID
                : candidate
        }
        let chosenAccountID = migratedSavedAccount.flatMap { candidate in
            loadedAccounts.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? Self.defaultAccountID
        self.previewMode = previewMode
        self.accounts = loadedAccounts
        self.activeAccountID = chosenAccountID
        self.client = Self.makeClient(codexHome: loadedAccounts.first(where: { $0.id == chosenAccountID })?.homeURL)
        UserDefaults.standard.set(try? JSONEncoder().encode(loadedAccounts), forKey: Self.accountsKey)
        UserDefaults.standard.set(chosenAccountID.uuidString, forKey: Self.activeAccountKey)
        let saved = UserDefaults.standard.integer(forKey: Self.thresholdKey)
        alertThreshold = saved == 0 ? 20 : saved
        displayMode = MenuBarDisplayMode(rawValue: UserDefaults.standard.string(forKey: Self.displayModeKey) ?? "") ?? .iconAndPercentage
        analyticsRange = AccountUsageRange(rawValue: UserDefaults.standard.integer(forKey: Self.analyticsRangeKey)) ?? .week
        if previewMode {
            let now = Date()
            payload = RateLimitPayload(
                snapshot: RateLimitSnapshot(
                    limitID: "codex",
                    limitName: "Codex",
                    planType: "plus",
                    primary: RateLimitWindow(usedPercent: 58, resetsAt: now.addingTimeInterval(8_040), durationMinutes: 300),
                    secondary: RateLimitWindow(usedPercent: 32, resetsAt: now.addingTimeInterval(403_200), durationMinutes: 10_080),
                    credits: AccountCredits(hasCredits: true, unlimited: false, balance: "120.50")
                ),
                fetchedAt: now,
                availableResetCredits: 3
            )
            var history = AccountQuotaHistory(accountKey: "preview")
            for offset in stride(from: 60, through: 0, by: -1) {
                history.record(RateLimitPayload(
                    snapshot: RateLimitSnapshot(limitID: "codex", limitName: "Codex", planType: "plus",
                        primary: RateLimitWindow(usedPercent: 28 + (60 - offset) / 2, resetsAt: now.addingTimeInterval(8_040), durationMinutes: 300),
                        secondary: RateLimitWindow(usedPercent: 20 + (60 - offset) / 5, resetsAt: now.addingTimeInterval(403_200), durationMinutes: 10_080)),
                    fetchedAt: now.addingTimeInterval(Double(-offset * 120))))
            }
            quotaHistory = history
            analytics = AccountUsagePayload(
                summary: AccountUsageSummary(lifetimeTokens: 123_456_789, peakDailyTokens: 9_000_000,
                    currentStreakDays: 4, longestStreakDays: 12),
                days: (0..<30).compactMap { offset in
                    guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { return nil }
                    return AccountUsageDay(day: AccountUsageDay.key(for: date), tokens: Int64((offset * 7 + 3) % 10) * 600_000)
                }, fetchedAt: now)
        }
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    var windows: [RateLimitWindow] { payload?.snapshot.windows ?? [] }
    var activeAccountName: String {
        guard let account = accounts.first(where: { $0.id == activeAccountID }) else { return AppLocalization.text("Default") }
        return account.homePath == nil ? AppLocalization.text("Default") : account.name
    }
    var activeAccountDisplayName: String { accounts.first(where: { $0.id == activeAccountID })?.displayName ?? AppLocalization.text("Default") }
    var canDeleteActiveAccount: Bool { accounts.first(where: { $0.id == activeAccountID })?.homePath != nil }
    var bankedResetCount: Int? { payload?.availableResetCredits }
    var menuBarRemaining: Int? {
        guard errorMessage == nil, !isStale else { return nil }
        return menuBarWindow?.remainingPercent
    }
    var menuBarWindow: RateLimitWindow? {
        guard errorMessage == nil, !isStale else { return nil }
        return payload?.snapshot.currentMostConstrainedWindow()
    }
    var planLabel: String? {
        payload?.snapshot.planType?.replacingOccurrences(of: "_", with: " ").capitalized
    }
    var isStale: Bool {
        guard let fetchedAt = payload?.fetchedAt else { return false }
        return Date().timeIntervalSince(fetchedAt) > 180
    }

    private func setErrorMessage(_ render: @autoclosure @escaping () -> String?) {
        errorMessageRenderer = render
        errorMessage = render()
    }

    private func setOperationError(_ render: @autoclosure @escaping () -> String?) {
        operationErrorRenderer = render
        operationError = render()
    }

    private func setHistoryError(_ render: @autoclosure @escaping () -> String?) {
        historyErrorRenderer = render
        historyError = render()
    }

    private func setAnalyticsError(_ render: @autoclosure @escaping () -> String?) {
        analyticsErrorRenderer = render
        analyticsError = render()
    }

    private func clearAnalytics() {
        analyticsGeneration = UUID()
        analytics = nil
        analyticsAccountKey = nil
        lastAnalyticsAttemptAt = nil
        isLoadingAnalytics = false
        setAnalyticsError(nil)
    }

    private static func analyticsIdentity(for account: CodexAccount?) -> String? {
        guard let account, let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else { return nil }
        return "\(account.type):\(email.lowercased())"
    }

    private func setAccountSwitchStatus(_ render: @autoclosure @escaping () -> String?) {
        accountSwitchStatusRenderer = render
        accountSwitchStatus = render()
    }

    private func setCelebration(_ render: @autoclosure @escaping () -> Celebration?) {
        celebrationGeneration = UUID()
        celebrationRenderer = render
        celebration = render()
    }

    private func renderLocalizedMessages() {
        errorMessage = errorMessageRenderer?()
        operationError = operationErrorRenderer?()
        historyError = historyErrorRenderer?()
        analyticsError = analyticsErrorRenderer?()
        accountSwitchStatus = accountSwitchStatusRenderer?()
        celebration = celebrationRenderer?()
    }

    private static func makeClient(codexHome: URL? = nil) -> CodexAppServerClient {
        let selectedApp = selectedCodexAppURL()
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .compactMap(\.bundleURL)
        let registeredApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        return CodexAppServerClient(
            codexHome: codexHome,
            appBundleURLs: [selectedApp].compactMap { $0 } + runningApps + [registeredApp].compactMap { $0 }
        )
    }

    private static func selectedCodexAppURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: selectedCodexAppKey) else { return nil }
        let appURL = URL(fileURLWithPath: path, isDirectory: true)
        guard CodexExecutableLocator.desktopExecutableURL(in: appURL) != nil else { return nil }
        return appURL
    }

    private func rebuildCurrentClient() -> CodexAppServerClient {
        let previousClient = client
        let codexHome = accounts.first(where: { $0.id == activeAccountID })?.homeURL
        clientGeneration = UUID()
        client = Self.makeClient(codexHome: codexHome)
        rediscoverClientOnNextRefresh = false
        payload = nil
        clearAnalytics()
        setErrorMessage(nil)
        lastUsageDiagnostics = nil
        isRefreshing = false
        return previousClient
    }

    func selectCodexApp() {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.text("Select Codex App…")
        panel.message = AppLocalization.text("Choose the installed Codex or ChatGPT app. QuotaBar will use its bundled Codex command-line tool.")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let appURL = selectedURL.standardizedFileURL
        guard CodexExecutableLocator.desktopExecutableURL(in: appURL) != nil else {
            setOperationError(AppLocalization.text("The selected app is not a supported Codex desktop app with a bundled Codex command-line tool."))
            return
        }

        UserDefaults.standard.set(appURL.path, forKey: Self.selectedCodexAppKey)
        setOperationError(nil)
        pollingTask?.cancel()
        analyticsPollingTask?.cancel()
        let previousClient = rebuildCurrentClient()
        let nextClient = client
        let generation = clientGeneration
        let accountID = activeAccountID
        Task {
            await previousClient.stop()
            guard isCurrentRequest(client: nextClient, accountID: accountID, generation: generation) else { return }
            start()
        }
    }

    private func isCurrentRequest(client requestClient: CodexAppServerClient, accountID: UUID, generation: UUID) -> Bool {
        client === requestClient && activeAccountID == accountID && clientGeneration == generation
    }

    func start() {
        guard !previewMode else { return }
        pollingTask?.cancel()
        analyticsPollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(120))
            }
        }
        analyticsPollingTask = Task {
            while !Task.isCancelled {
                await refreshAnalytics()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    func refreshAll() async {
        async let quota: Void = refresh()
        async let history: Void = refreshAnalytics(force: true)
        _ = await (quota, history)
    }

    func refresh() async {
        guard !previewMode, !Task.isCancelled, !isRefreshing else { return }
        let previousClient = rediscoverClientOnNextRefresh ? rebuildCurrentClient() : nil
        let requestClient = client
        let generation = clientGeneration
        let accountID = activeAccountID
        var shouldRefreshAnalytics = false
        isRefreshing = true
        defer {
            if isCurrentRequest(client: requestClient, accountID: accountID, generation: generation) {
                isRefreshing = false
                if shouldRefreshAnalytics {
                    Task { await refreshAnalytics() }
                }
            }
        }
        if let previousClient {
            await previousClient.stop()
            guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation) else { return }
        }
        do {
            let (accountBefore, newPayload) = try await UsageFetchRetry.run(
                shouldRetry: { ($0 as? CodexClientError) != .executableNotFound }
            ) {
                guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation) else {
                    throw CancellationError()
                }
                let account = try? await requestClient.readAccount()
                try Task.checkCancellation()
                guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation) else {
                    throw CancellationError()
                }
                let payload = try await requestClient.readRateLimits()
                return (account, payload)
            }
            guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation) else { return }
            if let key = analyticsAccountKey, Self.analyticsIdentity(for: accountBefore) != key {
                clearAnalytics()
                shouldRefreshAnalytics = true
            }
            payload = newPayload
            setErrorMessage(newPayload.snapshot.windows.isEmpty ? AppLocalization.text("No Codex rate-limit windows were returned for this account.") : nil)
            if newPayload.snapshot.windows.isEmpty && newPayload.snapshot.credits == nil && newPayload.availableResetCredits == nil {
                quotaHistory = nil
                let diagnostics = await requestClient.diagnosticSummary()
                guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation) else { return }
                lastUsageDiagnostics = diagnostics
                return
            }
            lastUsageDiagnostics = nil
            let identity: String?
            if let backendID = newPayload.accountID, !backendID.isEmpty {
                identity = "account:\(backendID)"
            } else {
                // Older servers omit accountId. Verify account identity on both
                // sides of the quota read before comparing historical values.
                let accountAfter = try? await requestClient.readAccount()
                guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation) else { return }
                if let accountBefore, accountBefore == accountAfter,
                   let email = accountBefore.email, !email.isEmpty {
                    identity = "\(accountBefore.type):\(email.lowercased())"
                } else {
                    identity = nil
                }
            }
            var previousAccountPayload: RateLimitPayload?
            if let identity {
                if let previousIdentity = quotaHistory?.accountKey, previousIdentity != identity {
                    clearAnalytics()
                    shouldRefreshAnalytics = true
                }
                previousAccountPayload = quotaHistory.flatMap { $0.accountKey == identity ? $0.observations.last?.payload : nil }
                do {
                    let history = try await quotaHistoryStore.record(newPayload, profileID: accountID, accountKey: identity)
                    guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation) else { return }
                    quotaHistory = history
                    setHistoryError(nil)
                } catch {
                    guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation) else { return }
                    var history = quotaHistory.flatMap { $0.accountKey == identity ? $0 : nil } ?? AccountQuotaHistory(accountKey: identity)
                    history.record(newPayload)
                    quotaHistory = history
                    setHistoryError(AppLocalization.text("Quota history could not be saved. Current account quota is still available; changes may be lost after quitting."))
                }
            } else {
                quotaHistory = nil
                setHistoryError(AppLocalization.text("Codex did not return a verifiable account identity. Current quota is shown without combining account history."))
            }
            detectBankedResetMilestone(previous: previousAccountPayload, current: newPayload)
            Task { [weak self] in
                await self?.notifyIfNeeded(newPayload, accountID: accountID, generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation) else { return }
            rediscoverClientOnNextRefresh = (error as? CodexClientError) == .executableNotFound
            setErrorMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            let diagnostics = await requestClient.diagnosticSummary()
            guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation) else { return }
            lastUsageDiagnostics = diagnostics
            await requestClient.stop()
        }
    }

    /// Account history is fetched independently of quota. Unsupported analytics
    /// and analytics failures never make a successful quota read fail.
    func refreshAnalytics(force: Bool = false) async {
        guard !previewMode, !Task.isCancelled, !isLoadingAnalytics else { return }
        if !force, let lastAnalyticsAttemptAt, Date().timeIntervalSince(lastAnalyticsAttemptAt) < 600 { return }
        let requestClient = client
        let generation = clientGeneration
        let accountID = activeAccountID
        let analyticsToken = analyticsGeneration
        isLoadingAnalytics = true
        lastAnalyticsAttemptAt = Date()
        defer {
            if isCurrentRequest(client: requestClient, accountID: accountID, generation: generation), analyticsToken == analyticsGeneration {
                isLoadingAnalytics = false
            }
        }
        do {
            let usage = try await UsageFetchRetry.run(shouldRetry: { error in
                (error as? CodexClientError) != .executableNotFound
                    && (error as? AccountUsageError) != .unsupported
                    && (error as? AccountUsageError) != .unverifiedAccount
            }) {
                guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation), analyticsToken == analyticsGeneration else {
                    throw CancellationError()
                }
                let before = try await requestClient.readAccount()
                guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation), analyticsToken == analyticsGeneration else {
                    throw CancellationError()
                }
                guard let identity = Self.analyticsIdentity(for: before) else { throw AccountUsageError.unverifiedAccount }
                if analyticsAccountKey != identity { analytics = nil }
                analyticsAccountKey = identity
                let usage = try await requestClient.readAccountUsageIncludingToday()
                guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation), analyticsToken == analyticsGeneration else {
                    throw CancellationError()
                }
                let after = try await requestClient.readAccount()
                guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation), analyticsToken == analyticsGeneration else {
                    throw CancellationError()
                }
                guard before == after, Self.analyticsIdentity(for: after) == identity else { throw AccountUsageError.unverifiedAccount }
                return usage
            }
            guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation), analyticsToken == analyticsGeneration else { return }
            analytics = usage
            setAnalyticsError(nil)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentRequest(client: requestClient, accountID: accountID, generation: generation), analyticsToken == analyticsGeneration else { return }
            if error as? AccountUsageError == .unverifiedAccount {
                analytics = nil
                analyticsAccountKey = nil
            }
            setAnalyticsError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func copyUsageDiagnostics() {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let text = [
            AppLocalization.text("QuotaBar diagnostics"),
            AppLocalization.format("Version: %@", appVersion),
            AppLocalization.format("Time: %@", Date().formatted(.dateTime.locale(AppLocalization.locale))),
            AppLocalization.format("Active profile: %@ (%@)", activeAccountName, AppLocalization.text(activeAccountID == Self.defaultAccountID ? "default CODEX_HOME" : "isolated CODEX_HOME")),
            AppLocalization.format("Last successful refresh: %@", payload?.fetchedAt.formatted(.dateTime.locale(AppLocalization.locale)) ?? AppLocalization.text("none")),
            AppLocalization.format("Usage error: %@", errorMessage ?? AppLocalization.text("none")),
            lastUsageDiagnostics ?? AppLocalization.text("Protocol diagnostics: unavailable")
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CodexProcessDiagnostics.redact(text), forType: .string)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        setOperationError(nil)
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            setOperationError(AppLocalization.format("Launch at login could not be changed: %@", error.localizedDescription))
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openCodex() {
        setOperationError(nil)
        let settingsURL = URL(string: "codex://settings")
        if let selectedApp = Self.selectedCodexAppURL(), let settingsURL {
            NSWorkspace.shared.open([settingsURL], withApplicationAt: selectedApp, configuration: .init()) { [weak self] _, error in
                Task { @MainActor in
                    if let error {
                        self?.setOperationError(AppLocalization.format("Codex could not be opened: %@", error.localizedDescription))
                    }
                }
            }
            return
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first {
            running.activate(options: [.activateAllWindows])
            if let settingsURL { _ = NSWorkspace.shared.open(settingsURL) }
            return
        }
        let discoveredURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        let fallbackURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        guard let appURL = discoveredURL ?? (FileManager.default.fileExists(atPath: fallbackURL.path) ? fallbackURL : nil) else {
            setOperationError(AppLocalization.text("Codex is not installed in /Applications."))
            return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.setOperationError(AppLocalization.format("Codex could not be opened: %@", error.localizedDescription))
                } else if let settingsURL {
                    _ = NSWorkspace.shared.open(settingsURL)
                }
            }
        }
    }

    func requestAccountSwitch(to id: UUID) {
        guard accounts.contains(where: { $0.id == id }), id != activeAccountID else { return }
        guard let profile = accounts.first(where: { $0.id == id }) else { return }

        let alert = NSAlert()
        alert.messageText = AppLocalization.format("Switch to %@?", profile.displayName)
        alert.informativeText = profile.homeURL == nil
            ? AppLocalization.text("This is the Codex desktop profile. QuotaBar will switch its usage view to the account currently signed in there.")
            : AppLocalization.text("Choose whether to switch only QuotaBar, or also sign the Codex desktop app out and open OpenAI's secure browser login for this account.")
        if profile.homeURL == nil {
            alert.addButton(withTitle: AppLocalization.text("Switch QuotaBar"))
            alert.addButton(withTitle: AppLocalization.text("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            switchActiveProfile(to: id)
            return
        }
        alert.addButton(withTitle: AppLocalization.text("QuotaBar + Codex"))
        alert.addButton(withTitle: AppLocalization.text("QuotaBar Only"))
        alert.addButton(withTitle: AppLocalization.text("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            switchActiveProfile(to: id)
            Task { await switchCodexDesktopAccount(to: profile) }
        case .alertSecondButtonReturn:
            switchActiveProfile(to: id)
        default:
            return
        }
    }

    private func switchActiveProfile(to id: UUID) {
        guard let profile = accounts.first(where: { $0.id == id }), id != activeAccountID else { return }
        pollingTask?.cancel()
        analyticsPollingTask?.cancel()
        let previousClient = client
        let generation = UUID()
        clientGeneration = generation
        rediscoverClientOnNextRefresh = false
        activeAccountID = id
        let nextClient = Self.makeClient(codexHome: profile.homeURL)
        client = nextClient
        payload = nil
        clearAnalytics()
        quotaHistory = nil
        setErrorMessage(nil)
        setOperationError(nil)
        setHistoryError(nil)
        lastUsageDiagnostics = nil
        isRefreshing = false
        Task {
            await previousClient.stop()
            guard isCurrentRequest(client: nextClient, accountID: id, generation: generation) else { return }
            start()
        }
    }

    func addAccount() {
        guard !isSwitchingCodexAccount else { return }
        let alert = NSAlert()
        alert.messageText = AppLocalization.text("Add Codex account")
        alert.informativeText = AppLocalization.text("Choose a label. QuotaBar will open OpenAI's secure browser sign-in for a private profile on this Mac. Passwords and verification codes stay on OpenAI's page.")
        let field = NSTextField(string: AppLocalization.text("Work"))
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: AppLocalization.text("Continue"))
        alert.addButton(withTitle: AppLocalization.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        setOperationError(nil)
        let id = UUID()
        // Keep existing and newly added profiles in the same legacy storage root.
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-meter", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let config = home.appendingPathComponent("config.toml")
            if !FileManager.default.fileExists(atPath: config.path) {
                try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: config, options: .atomic)
            }
            let profile = AccountProfile(id: id, name: name, homePath: home.path, email: nil)
            accounts.append(profile)
            persistAccounts()
            startLogin(for: profile)
        } catch {
            setOperationError(AppLocalization.format("The account profile could not be created: %@", error.localizedDescription))
        }
    }

    func deleteActiveAccount() {
        deleteAccount(id: activeAccountID)
    }

    func deleteAccount(id: UUID) {
        guard !isSwitchingCodexAccount else { return }
        guard let profile = accounts.first(where: { $0.id == id }), let home = profile.homeURL else { return }
        let wasActive = profile.id == activeAccountID
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppLocalization.format("Delete %@?", profile.name)
        alert.informativeText = AppLocalization.text("This removes the locally saved Codex credentials and usage profile from this Mac. It does not delete the OpenAI account.")
        alert.addButton(withTitle: AppLocalization.text("Delete Account"))
        alert.addButton(withTitle: AppLocalization.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setOperationError(nil)
        loginTasks.removeValue(forKey: profile.id)?.cancel()
        let pendingLoginClient = loginClients.removeValue(forKey: profile.id)
        let deletionClient = client
        if wasActive {
            pollingTask?.cancel()
            analyticsPollingTask?.cancel()
            clientGeneration = UUID()
            rediscoverClientOnNextRefresh = false
            payload = nil
            clearAnalytics()
            quotaHistory = nil
            setErrorMessage(nil)
            setHistoryError(nil)
            lastUsageDiagnostics = nil
            isRefreshing = false
        }
        let deletionGeneration = clientGeneration
        Task {
            if let pendingLoginClient { await pendingLoginClient.stop() }
            if wasActive { await deletionClient.stop() }
            do {
                try AccountProfileStorage.removeLocalProfile(at: home)
                var historyCleanupFailed = false
                do {
                    try await quotaHistoryStore.remove(profileID: profile.id)
                } catch {
                    historyCleanupFailed = true
                }
                accounts.removeAll { $0.id == profile.id }
                persistAccounts()
                if wasActive,
                   isCurrentRequest(client: deletionClient, accountID: profile.id, generation: deletionGeneration),
                   let fallback = accounts.first {
                    switchActiveProfile(to: fallback.id)
                }
                setCelebration(Celebration(title: AppLocalization.text("Account removed"), subtitle: AppLocalization.text("Local credentials were deleted"), symbol: "trash"))
                dismissCelebration()
                if historyCleanupFailed {
                    setOperationError(AppLocalization.text("The account was removed, but its local quota history could not be deleted."))
                }
            } catch {
                if wasActive, isCurrentRequest(client: deletionClient, accountID: profile.id, generation: deletionGeneration) {
                    clientGeneration = UUID()
                    client = Self.makeClient(codexHome: profile.homeURL)
                    isRefreshing = false
                    start()
                }
                setOperationError(AppLocalization.format("The local account could not be deleted: %@", error.localizedDescription))
            }
        }
    }

    private func startLogin(for profile: AccountProfile) {
        guard let home = profile.homeURL else { return }
        setOperationError(nil)
        loginTasks[profile.id]?.cancel()
        let previousLoginClient = loginClients[profile.id]
        let loginClient = Self.makeClient(codexHome: home)
        loginClients[profile.id] = loginClient
        loginTasks[profile.id] = Task { [weak self] in
            guard let self else { return }
            @MainActor func checkCurrentLogin() throws {
                guard !Task.isCancelled, self.loginClients[profile.id] === loginClient,
                      self.accounts.contains(where: { $0.id == profile.id }) else { throw CancellationError() }
            }
            defer {
                if self.loginClients[profile.id] === loginClient {
                    self.loginClients.removeValue(forKey: profile.id)
                    self.loginTasks.removeValue(forKey: profile.id)
                }
            }
            do {
                if let previousLoginClient { await previousLoginClient.stop() }
                try checkCurrentLogin()
                let login = try await loginClient.startChatGPTLogin()
                try checkCurrentLogin()
                guard NSWorkspace.shared.open(login.authorizationURL) else {
                    throw CodexClientError.server("The OpenAI sign-in page could not be opened in your browser.")
                }
                try await loginClient.waitForLogin(id: login.id)
                try checkCurrentLogin()
                guard let account = try await loginClient.readAccount(refreshToken: true) else {
                    throw CodexClientError.server("Codex did not report a signed-in account after login.")
                }
                await loginClient.stop()
                try checkCurrentLogin()
                if let index = self.accounts.firstIndex(where: { $0.id == profile.id }) {
                    self.accounts[index].email = account.email
                    self.persistAccounts()
                }
                self.switchActiveProfile(to: profile.id)
                self.setCelebration(Celebration(title: AppLocalization.text("Account ready"), subtitle: AppLocalization.text("Secure sign-in completed"), symbol: "person.crop.circle.badge.checkmark"))
                self.dismissCelebration()
            } catch is CancellationError {
                await loginClient.stop()
            } catch {
                await loginClient.stop()
                guard (try? checkCurrentLogin()) != nil else { return }
                self.accounts.removeAll { $0.id == profile.id }
                self.persistAccounts()
                try? AccountProfileStorage.removeLocalProfile(at: home)
                if self.activeAccountID == profile.id, let fallback = self.accounts.first {
                    self.switchActiveProfile(to: fallback.id)
                }
                self.setOperationError(AppLocalization.format("OpenAI sign-in failed: %@", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    private func persistAccounts() {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: Self.accountsKey)
    }

    private func detectBankedResetMilestone(previous: RateLimitPayload?, current: RateLimitPayload) {
        guard !previewMode,
              let previousCount = previous?.availableResetCredits,
              let currentCount = current.availableResetCredits,
              currentCount > previousCount else { return }
        let key = "\(current.accountID ?? quotaHistory?.accountKey ?? activeAccountID.uuidString)-\(currentCount)"
        guard UserDefaults.standard.string(forKey: Self.resetMilestoneKey) != key else { return }
        UserDefaults.standard.set(key, forKey: Self.resetMilestoneKey)
        setCelebration(Celebration(title: AppLocalization.text("Reset banked"), subtitle: AppLocalization.format("%lld available for this account", Int64(currentCount)), symbol: "arrow.counterclockwise.circle.fill"))
        dismissCelebration()
    }

    private func switchCodexDesktopAccount(to profile: AccountProfile) async {
        guard !isSwitchingCodexAccount else { return }
        isSwitchingCodexAccount = true
        setAccountSwitchStatus(AppLocalization.text("Signing Codex out…"))
        setOperationError(nil)

        let desktopClient = Self.makeClient()
        do {
            var expectedEmail = profile.email
            if expectedEmail == nil, let home = profile.homeURL {
                setAccountSwitchStatus(AppLocalization.format("Checking %@…", profile.name))
                let profileClient = Self.makeClient(codexHome: home)
                if let account = try? await profileClient.readAccount() {
                    expectedEmail = account.email
                    if let index = accounts.firstIndex(where: { $0.id == profile.id }) {
                        accounts[index].email = account.email
                        persistAccounts()
                    }
                }
                await profileClient.stop()
            }
            setAccountSwitchStatus(AppLocalization.text("Signing Codex out…"))
            try await closeCodexDesktop()
            try await desktopClient.logoutAccount()
            setAccountSwitchStatus(AppLocalization.text("Waiting for secure OpenAI sign-in…"))
            let login = try await desktopClient.startChatGPTLogin()
            guard NSWorkspace.shared.open(login.authorizationURL) else {
                throw CodexClientError.server("The OpenAI sign-in page could not be opened in your browser.")
            }
            try await desktopClient.waitForLogin(id: login.id)
            guard let signedIn = try await desktopClient.readAccount(refreshToken: true) else {
                throw CodexClientError.server("Codex did not report a signed-in account after login.")
            }
            if let expected = expectedEmail, let actual = signedIn.email,
               expected.caseInsensitiveCompare(actual) != .orderedSame {
                throw AccountMismatchError(actualEmail: actual, expectedEmail: expected)
            }
            await desktopClient.stop()
            setAccountSwitchStatus(nil)
            isSwitchingCodexAccount = false
            openCodex()
            setCelebration(Celebration(
                title: AppLocalization.text("Codex account switched"),
                subtitle: signedIn.email ?? profile.displayName,
                symbol: "person.crop.circle.badge.checkmark"
            ))
            dismissCelebration()
        } catch {
            await desktopClient.stop()
            setAccountSwitchStatus(nil)
            isSwitchingCodexAccount = false
            openCodex()
            setOperationError(AppLocalization.format("Codex account switch failed: %@", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    private func closeCodexDesktop() async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        running.forEach { _ = $0.terminate() }
        let deadline = ContinuousClock.now + .seconds(8)
        while NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").contains(where: { !$0.isTerminated }) {
            guard ContinuousClock.now < deadline else {
                throw CodexClientError.server("Codex could not be closed before signing out. Quit Codex and try again.")
            }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    private func dismissCelebration() {
        let generation = celebrationGeneration
        Task {
            try? await Task.sleep(for: .seconds(4))
            if celebrationGeneration == generation { setCelebration(nil) }
        }
    }

    private func notifyIfNeeded(_ payload: RateLimitPayload, accountID: UUID, generation: UUID) async {
        guard clientGeneration == generation, activeAccountID == accountID,
              let constrained = payload.snapshot.currentMostConstrainedWindow(),
              constrained.remainingPercent <= alertThreshold else { return }

        let fallbackBucket = Int(Date().timeIntervalSince1970 / 86_400)
        let resetComponent = constrained.resetsAt.flatMap { Int(exactly: $0.timeIntervalSince1970.rounded(.towardZero)) } ?? fallbackBucket
        let identity = payload.accountID ?? quotaHistory?.accountKey ?? accountID.uuidString
        let resetID = "\(identity)-\(constrained.durationMinutes ?? 0)-\(resetComponent)-\(alertThreshold)"
        guard UserDefaults.standard.string(forKey: Self.notifiedResetKey) != resetID,
              pendingNotificationIDs.insert(resetID).inserted else { return }
        defer { pendingNotificationIDs.remove(resetID) }

        if !previewMode {
            setCelebration(Celebration(title: AppLocalization.text("Usage running low"), subtitle: AppLocalization.format("%d%% remains in the tightest window", constrained.remainingPercent), symbol: "exclamationmark.triangle.fill"))
            dismissCelebration()
        }

        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted, clientGeneration == generation, activeAccountID == accountID,
              self.payload == payload, !constrained.isAwaitingReset() else { return }

        let content = UNMutableNotificationContent()
        content.title = AppLocalization.text("Codex usage is running low")
        content.body = AppLocalization.format("%d%% remains. %@", constrained.remainingPercent, ResetTimeFormatter.notificationText(for: constrained.resetsAt))
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: "quota-bar-low-\(resetID)", content: content, trigger: nil))
        } catch { return }
        guard clientGeneration == generation, activeAccountID == accountID, self.payload == payload else { return }
        UserDefaults.standard.set(resetID, forKey: Self.notifiedResetKey)
    }
}

private struct AccountMismatchError: LocalizedError {
    let actualEmail: String
    let expectedEmail: String

    var errorDescription: String? {
        AppLocalization.format(
            "Codex signed in as %@, not %@. Sign in again and choose the intended account.",
            actualEmail,
            expectedEmail
        )
    }
}

private func decodedDefaultID(from data: Data?) -> UUID? {
    guard let data,
          let decoded = try? JSONDecoder().decode([AccountProfile].self, from: data) else { return nil }
    return decoded.first(where: { $0.homePath == nil })?.id
}

enum ResetTimeFormatter {
    static func relativeText(for date: Date?, now: Date = Date()) -> String {
        guard let date else { return AppLocalization.text("Reset time unavailable") }
        if date <= now { return AppLocalization.text("Resetting now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = AppLocalization.locale
        return AppLocalization.format("Resets %@", formatter.localizedString(for: date, relativeTo: now))
    }

    static func absoluteText(for date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(AppLocalization.locale))
    }

    static func notificationText(for date: Date?) -> String {
        guard let date else { return AppLocalization.text("The reset time is unavailable.") }
        return AppLocalization.format("It resets %@.", date.formatted(.dateTime.hour().minute().locale(AppLocalization.locale)))
    }
}
