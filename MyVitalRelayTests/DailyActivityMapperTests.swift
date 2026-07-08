import XCTest
@testable import MyVitalRelay

final class DailyActivityMapperTests: XCTestCase {
    private let userId = UUID()

    private var jstCalendar: Calendar { JSTDateUtilities.jstCalendar }

    private func jstDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.calendar = jstCalendar
        components.timeZone = WorkoutMapper.tokyo
        components.year = year
        components.month = month
        components.day = day
        return jstCalendar.date(from: components)!
    }

    func testMapsFinalizedDayWithOffset() {
        let activityDay = jstDate(year: 2026, month: 7, day: 3)
        let now = jstDate(year: 2026, month: 7, day: 8)

        let record = DailyActivityMapper.record(
            from: DailyActivityDayTotal(
                activityDay: activityDay,
                activeCaloriesKcal: 450,
                basalCaloriesKcal: 1200
            ),
            userId: userId,
            now: now
        )

        XCTAssertEqual(record?.date, "2026-07-04")
        XCTAssertEqual(record?.activeCaloriesKcal, 450)
        XCTAssertEqual(record?.basalCaloriesKcal, 1200)
        XCTAssertEqual(record?.userId, userId)
    }

    func testSkipsTodayActivityDay() {
        let today = jstDate(year: 2026, month: 7, day: 8)

        let record = DailyActivityMapper.record(
            from: DailyActivityDayTotal(
                activityDay: today,
                activeCaloriesKcal: 100,
                basalCaloriesKcal: 500
            ),
            userId: userId,
            now: today
        )

        XCTAssertNil(record)
    }

    func testSkipsDayWithBothCaloriesNil() {
        let activityDay = jstDate(year: 2026, month: 7, day: 3)
        let now = jstDate(year: 2026, month: 7, day: 8)

        let record = DailyActivityMapper.record(
            from: DailyActivityDayTotal(
                activityDay: activityDay,
                activeCaloriesKcal: nil,
                basalCaloriesKcal: nil
            ),
            userId: userId,
            now: now
        )

        XCTAssertNil(record)
    }

    func testAllowsActiveOnlyDay() {
        let activityDay = jstDate(year: 2026, month: 7, day: 3)
        let now = jstDate(year: 2026, month: 7, day: 8)

        let record = DailyActivityMapper.record(
            from: DailyActivityDayTotal(
                activityDay: activityDay,
                activeCaloriesKcal: 300,
                basalCaloriesKcal: nil
            ),
            userId: userId,
            now: now
        )

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.basalCaloriesKcal, nil)
    }

    func testEncodeIncludesNullKeysForNilCalories() throws {
        let record = DailyActivitySummaryRecord(
            userId: userId,
            date: "2026-07-04",
            activeCaloriesKcal: 100,
            basalCaloriesKcal: nil,
            syncedAt: "2026-07-08T00:00:00Z"
        )

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"active_calories_kcal\""))
        XCTAssertTrue(json.contains("\"basal_calories_kcal\":null"))
        XCTAssertFalse(json.contains("\"notes\""))
    }
}
