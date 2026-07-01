import XCTest
@testable import Pulse

final class SessionListSidebarViewTests: XCTestCase {
    func testMetadataTextAppendsFormattedUpdatedAtTimestamp() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, HH:mm"

        let date = Date(timeIntervalSince1970: 1_782_887_520)

        let text = SessionListRowFormatting.metadataText(
            subtitle: "openai / gpt-5.4",
            updatedAt: date,
            formatter: formatter
        )

        XCTAssertEqual(text, "openai / gpt-5.4 • Jul 1, 06:32")
    }
}
