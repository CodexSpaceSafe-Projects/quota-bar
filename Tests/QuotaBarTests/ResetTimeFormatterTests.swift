import Foundation
import XCTest
import QuotaBarCore
@testable import QuotaBar

final class ResetTimeFormatterTests: XCTestCase {
    func testLowQuotaNotificationIncludesTheFullResetDate() throws {
        let reset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-20T09:47:00Z"))
        let laterReset = reset.addingTimeInterval(2 * 86_400)
        let exactReset = try XCTUnwrap(ResetTimeFormatter.absoluteText(for: laterReset))

        let message = ResetTimeFormatter.notificationText(for: laterReset)
        XCTAssertEqual(message, AppLocalization.format("It resets %@.", exactReset))
        XCTAssertNotEqual(message, ResetTimeFormatter.notificationText(for: reset))
        XCTAssertEqual(ResetTimeFormatter.notificationText(for: nil), AppLocalization.text("The reset time is unavailable."))
    }
}
