import Foundation
import XCTest
import QuotaBarCore
@testable import QuotaBar

final class ResetTimeFormatterTests: XCTestCase {
    func testLowQuotaNotificationShowsDaysAndLocalResetTime() throws {
        let originalLanguage = AppLocalization.language
        defer { AppLocalization.language = originalLanguage }
        AppLocalization.language = .simplifiedChinese

        let dates = ISO8601DateFormatter()
        let now = try XCTUnwrap(dates.date(from: "2026-11-19T15:55:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))

        for (timestamp, expected) in [
            ("2026-11-19T15:58:00Z", "今天23点58分重置。"),
            ("2026-11-19T16:00:00Z", "明天0点重置。"),
            ("2026-11-22T01:00:00Z", "3天后9点重置。"),
            ("2026-11-22T01:47:00Z", "3天后9点47分重置。")
        ] {
            let reset = try XCTUnwrap(dates.date(from: timestamp))
            XCTAssertEqual(ResetTimeFormatter.notificationText(for: reset, now: now, calendar: calendar), expected)
        }

        XCTAssertEqual(ResetTimeFormatter.notificationText(for: nil, now: now, calendar: calendar), "重置时间不可用。")
        XCTAssertEqual(ResetTimeFormatter.notificationText(for: now, now: now, calendar: calendar), "正在重置")
    }

    func testEnglishNotificationPreservesNonzeroMinutesInLocalTime() throws {
        let originalLanguage = AppLocalization.language
        defer { AppLocalization.language = originalLanguage }
        AppLocalization.language = .english

        let dates = ISO8601DateFormatter()
        let now = try XCTUnwrap(dates.date(from: "2026-11-19T15:55:00Z"))
        let reset = try XCTUnwrap(dates.date(from: "2026-11-22T01:47:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))

        let message = ResetTimeFormatter.notificationText(for: reset, now: now, calendar: calendar)
        XCTAssertEqual(message.split(whereSeparator: \.isWhitespace).joined(separator: " "), "It resets in 3 days at 9:47 AM.")
    }
}
