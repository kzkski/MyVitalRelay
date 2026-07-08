import XCTest
@testable import MyVitalRelay

final class JSTDateUtilitiesTests: XCTestCase {
    private var jstCalendar: Calendar { JSTDateUtilities.jstCalendar }

    private func jstDate(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = jstCalendar
        components.timeZone = WorkoutMapper.tokyo
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return jstCalendar.date(from: components)!
    }

    func testDayStringUsesTokyoTimeZone() {
        let formatter = ISO8601DateFormatter()
        let utcDate = formatter.date(from: "2026-07-03T16:00:00Z")!

        XCTAssertEqual(JSTDateUtilities.dayStringJST(utcDate), "2026-07-04")
    }

    func testStorageDateOffsetsActivityDayByOne() {
        let activityDay = jstDate(year: 2026, month: 7, day: 3)

        XCTAssertEqual(JSTDateUtilities.storageDateString(forActivityDay: activityDay), "2026-07-04")
    }

    func testStorageDateRollsOverMonthEnd() {
        let activityDay = jstDate(year: 2026, month: 7, day: 31)

        XCTAssertEqual(JSTDateUtilities.storageDateString(forActivityDay: activityDay), "2026-08-01")
    }

    func testIsFinalizedActivityDayExcludesToday() {
        let today = jstDate(year: 2026, month: 7, day: 8, hour: 12)
        let yesterday = jstDate(year: 2026, month: 7, day: 7)

        XCTAssertFalse(JSTDateUtilities.isFinalizedActivityDay(today, now: today))
        XCTAssertTrue(JSTDateUtilities.isFinalizedActivityDay(yesterday, now: today))
    }

    func testStartOfTodayJST() {
        let now = jstDate(year: 2026, month: 7, day: 8, hour: 15)
        let start = JSTDateUtilities.startOfTodayJST(now: now)

        XCTAssertEqual(JSTDateUtilities.dayStringJST(start), "2026-07-08")
        XCTAssertEqual(jstCalendar.component(.hour, from: start), 0)
    }
}
