import Foundation
#if canImport(QuotaBarCore)
import QuotaBarCore
#endif

@main
struct ParserCheck {
    static func main() throws {
        AppLocalization.language = .english
        let standard = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":37,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":81,"windowDurationMins":10080,"resetsAt":2000100000}}}}"#
        let payload = try require(RateLimitParser.parseResponse(Data(standard.utf8), now: Date(timeIntervalSince1970: 1)))
        precondition(payload.snapshot.primary?.remainingPercent == 63)
        precondition(payload.snapshot.secondary?.remainingPercent == 19)
        precondition(payload.snapshot.mostConstrainedRemaining == 19)
        precondition(payload.snapshot.mostConstrainedWindow == payload.snapshot.secondary)
        precondition(payload.snapshot.primary?.displayName == "5-hour limit")
        precondition(payload.snapshot.secondary?.displayName == "Weekly limit")
        precondition(payload.availableResetCredits == nil)

        let withBankedResets = #"{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":10}},"rateLimitResetCredits":{"availableCount":2,"credits":null}}}"#
        let banked = try require(RateLimitParser.parseResponse(Data(withBankedResets.utf8)))
        precondition(banked.availableResetCredits == 2)

        let withBalance = #"{"id":3,"result":{"accountId":"account-a","rateLimits":{"limitId":"codex","primary":{"usedPercent":10},"credits":{"hasCredits":true,"unlimited":false,"balance":"123.456789"}}}}"#
        let balance = try require(RateLimitParser.parseResponse(Data(withBalance.utf8)))
        precondition(balance.accountID == "account-a")
        precondition(balance.snapshot.credits?.balance == "123.456789")
        precondition(balance.snapshot.credits?.displayBalance == "123")
        precondition(AccountCredits(hasCredits: true, unlimited: false, balance: "90.9999").displayBalance == "90")
        precondition(AccountCredits(hasCredits: true, unlimited: false, balance: "-0.9999").displayBalance == "0")
        precondition(AccountCredits(hasCredits: true, unlimited: false, balance: "9007199254740993.99").displayBalance == "9007199254740993")
        precondition(payload.snapshot.credits == nil)
        precondition(AccountCredits(hasCredits: true, unlimited: true, balance: nil).displayBalance == "Unlimited")
        precondition(AccountCredits(hasCredits: true, unlimited: false, balance: nil).displayBalance == "Unavailable")
        precondition(AccountCredits(hasCredits: false, unlimited: false, balance: nil).displayBalance == "No credits")
        // Snapshots exported by earlier versions still decode with absent fields.
        let legacy = #"{"snapshot":{"primary":{"usedPercent":10}},"fetchedAt":1}"#
        let decodedLegacy = try JSONDecoder().decode(RateLimitPayload.self, from: Data(legacy.utf8))
        precondition(decodedLegacy.accountID == nil && decodedLegacy.snapshot.credits == nil)

        let buckets = #"{"id":2,"result":{"rateLimits":{},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":4}},"codex":{"primary":{"usedPercent":22}}}}}"#
        let selected = try require(RateLimitParser.parseResponse(Data(buckets.utf8)))
        precondition(selected.snapshot.primary?.remainingPercent == 78)

        // When a server's map has no "codex" entry, use the server-selected
        // historical bucket rather than dictionary order or another model.
        let canonicalFallback = #"{"id":2,"result":{"rateLimits":{"limitId":"main-default","planType":"pro","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":2000000000}},"rateLimitsByLimitId":{"codex_other":{"limitId":"codex_other","primary":{"usedPercent":88,"windowDurationMins":30}}},"rateLimitResetCredits":{"availableCount":3}}}"#
        let canonical = try require(RateLimitParser.parseResponse(Data(canonicalFallback.utf8)))
        precondition(canonical.snapshot.limitID == "main-default")
        precondition(canonical.snapshot.planType == "pro")
        precondition(canonical.snapshot.primary?.remainingPercent == 80)
        precondition(canonical.snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 2_000_000_000))
        precondition(canonical.availableResetCredits == 3)

        let multiBucketFallback = #"{"id":2,"result":{"rateLimits":{"limitId":"main-default","primary":{"usedPercent":20}},"rateLimitsByLimitId":{"main-default":{"limitId":"main-default","primary":{"usedPercent":20}},"codex_other":{"limitId":"codex_other","primary":{"usedPercent":88}}}}}"#
        let multiBucket = try require(RateLimitParser.parseResponse(Data(multiBucketFallback.utf8)))
        precondition(multiBucket.snapshot.limitID == "main-default")
        precondition(multiBucket.snapshot.mostConstrainedRemaining == 80)

        let codexMapOnly = #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","secondary":{"usedPercent":99,"windowDurationMins":10080}}}}}"#
        let codexOnly = try require(RateLimitParser.parseResponse(Data(codexMapOnly.utf8)))
        precondition(codexOnly.snapshot.mostConstrainedRemaining == 1)

        let unrelatedMapOnly = #"{"id":2,"result":{"rateLimitsByLimitId":{"codex_other":{"primary":{"usedPercent":88}}}}}"#
        let unrelatedOnly = try RateLimitParser.parseResponse(Data(unrelatedMapOnly.utf8))
        precondition(unrelatedOnly == nil)

        // Quota periods are backend-defined; nonstandard periods must not be
        // presented as a five-hour, daily, or weekly allowance.
        let durations: [(Int?, String)] = [
            (nil, "Usage window"),
            (0, "Usage window"),
            (-60, "Usage window"),
            (60, "1-hour limit"),
            (120, "2-hour limit"),
            (300, "5-hour limit"),
            (360, "6-hour limit"),
            (480, "8-hour limit"),
            (45, "45-minute limit"),
            (1_200, "20-hour limit"),
            (1_440, "Daily limit"),
            (9_000, "150-hour limit"),
            (10_080, "Weekly limit")
        ]
        for (minutes, expectedLabel) in durations {
            let window = RateLimitWindow(usedPercent: 20, resetsAt: nil, durationMinutes: minutes)
            precondition(window.displayName == expectedLabel)
            precondition(window.remainingPercent == 80)
        }

        let clamped = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":125},"secondary":{"usedPercent":-4}}}}"#
        let clampedPayload = try require(RateLimitParser.parseResponse(Data(clamped.utf8)))
        precondition(clampedPayload.snapshot.primary?.remainingPercent == 0)
        precondition(clampedPayload.snapshot.secondary?.remainingPercent == 100)

        let update = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":9,"windowDurationMins":300}}}}"#
        let updated = try require(RateLimitParser.parseNotification(Data(update.utf8)))
        precondition(updated.snapshot.primary?.remainingPercent == 91)

        let now = Date(timeIntervalSince1970: 1_000_000)
        let multiDay = ResetCountdownFormatter.format(until: now.addingTimeInterval((2 * 86_400) + (8 * 3_600)), now: now)
        precondition(multiDay.daysText == "2d")
        precondition(multiDay.hoursText == "8h")
        precondition(multiDay.accessibilityText == "2 days, 8 hours until reset")

        let sameDay = ResetCountdownFormatter.format(until: now.addingTimeInterval(8 * 3_600), now: now)
        precondition(sameDay.daysText == "0d")
        precondition(sameDay.hoursText == "8h")

        let underOneHour = ResetCountdownFormatter.format(until: now.addingTimeInterval(59 * 60), now: now)
        precondition(underOneHour.daysText == "0d")
        precondition(underOneHour.hoursText == "<1h")

        let expired = ResetCountdownFormatter.format(until: now.addingTimeInterval(-1), now: now)
        precondition(expired.daysText == "0d")
        precondition(expired.hoursText == "0h")

        let unavailable = ResetCountdownFormatter.format(until: nil, now: now)
        precondition(unavailable.daysText == "--")
        precondition(unavailable.hoursText == "--")

        let tiedPrimary = RateLimitWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(3_600), durationMinutes: 300)
        let tiedSecondary = RateLimitWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(86_400), durationMinutes: 10_080)
        let tied = RateLimitSnapshot(limitID: "codex", limitName: "Codex", planType: "plus", primary: tiedPrimary, secondary: tiedSecondary)
        precondition(tied.mostConstrainedWindow == tiedPrimary)
        // Crossing a deadline makes the current account allowance unknown,
        // including when the expired window was previously the less constrained.
        precondition(tied.currentMostConstrainedWindow(at: now) == tiedPrimary)
        precondition(tied.currentMostConstrainedWindow(at: tiedPrimary.resetsAt!) == nil)
        precondition(tiedPrimary.isAwaitingReset(at: tiedPrimary.resetsAt!))
        precondition(!RateLimitWindow(usedPercent: 50, resetsAt: nil, durationMinutes: 300).isAwaitingReset(at: now))
        precondition(RateLimitWindow(usedPercent: Int.min, resetsAt: nil, durationMinutes: nil).remainingPercent == 100)
        precondition(RateLimitWindow(usedPercent: Int.max, resetsAt: nil, durationMinutes: nil).remainingPercent == 0)
        for invalid in ["true", "1.5", "9223372036854775808"] {
            let malformed = "{\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":\(invalid)}}}}"
            let malformedPayload = try require(RateLimitParser.parseResponse(Data(malformed.utf8)))
            precondition(malformedPayload.snapshot.primary == nil)
        }
        let invalidReset = ResetCountdownFormatter.format(until: Date(timeIntervalSince1970: .infinity), now: now)
        precondition(invalidReset.daysText == "--")
        print("Parser checks passed")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CodexClientError.invalidResponse }
        return value
    }
}
