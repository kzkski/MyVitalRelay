import XCTest
@testable import MyVitalRelay

final class GarminSyncRequestRecordTests: XCTestCase {
    func testHealthKitActivitiesFactory() {
        let record = GarminSyncRequestRecord.healthKitActivities(
            dateFrom: "2026-07-05",
            dateTo: "2026-07-11"
        )

        XCTAssertEqual(record.scope, "activities")
        XCTAssertEqual(record.dateFrom, "2026-07-05")
        XCTAssertEqual(record.dateTo, "2026-07-11")
        XCTAssertEqual(record.triggerSource, "healthkit")
    }

    func testActivitiesDateRangeFromRecords() {
        let records = [
            makeRecord(date: "2026-07-10"),
            makeRecord(date: "2026-07-05"),
            makeRecord(date: "2026-07-08"),
        ]

        let range = GarminSyncRequestRecord.activitiesDateRange(from: records)
        XCTAssertEqual(range?.dateFrom, "2026-07-05")
        XCTAssertEqual(range?.dateTo, "2026-07-10")
    }

    func testActivitiesDateRangeEmpty() {
        XCTAssertNil(GarminSyncRequestRecord.activitiesDateRange(from: []))
    }

    func testIsPendingDuplicateError() {
        XCTAssertTrue(
            GarminSyncRequestEnqueuer.isPendingDuplicateError(
                NSError(domain: "Postgrest", code: 23505)
            )
        )
        XCTAssertTrue(
            GarminSyncRequestEnqueuer.isPendingDuplicateError(
                NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "duplicate key"])
            )
        )
        XCTAssertFalse(
            GarminSyncRequestEnqueuer.isPendingDuplicateError(
                NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "network error"])
            )
        )
    }

    private func makeRecord(date: String) -> TrainingLogRecord {
        TrainingLogRecord(
            userId: UUID(),
            date: date,
            dataSource: "garmin",
            healthkitUuid: UUID(),
            discipline: "run",
            workoutType: "Running",
            startTime: "2026-07-10T00:00:00Z",
            endTime: "2026-07-10T01:00:00Z",
            durationMin: 60,
            distanceKm: 10,
            avgSpeedKmh: 10,
            caloriesBurned: 500,
            avgHr: 140,
            maxHr: 160,
            hrZoneMinutes: nil,
            elevationGainM: 50,
            strokeCount: nil,
            metadata: .init(sourceName: "Garmin", sourceBundleId: "com.garmin.connect.mobile"),
            updatedAt: "2026-07-10T01:00:00Z"
        )
    }
}
