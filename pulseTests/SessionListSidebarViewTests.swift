import XCTest
@testable import Pulse

final class SessionListSidebarViewTests: XCTestCase {
    func testMetadataSubtitleTextAddsTrailingSeparator() {
        XCTAssertEqual(
            SessionListRowFormatting.metadataSubtitleText("openai / gpt-5.4"),
            "openai / gpt-5.4 •"
        )
    }

    func testTimestampTextUsesSharedShortDateTimeStyle() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let date = Date(timeIntervalSince1970: 1_782_887_520)

        let text = SessionListRowFormatting.timestampText(
            updatedAt: date,
            formatter: formatter
        )

        XCTAssertEqual(text, "2026-07-01 06:32")
    }
}
