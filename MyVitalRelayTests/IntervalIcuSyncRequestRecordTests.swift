import XCTest
@testable import MyVitalRelay

final class IntervalIcuSyncRequestRecordTests: XCTestCase {
    func testHealthKitFactory() {
        let record = IntervalIcuSyncRequestRecord.healthKit(date: "2026-07-27")
        XCTAssertEqual(record.date, "2026-07-27")
        XCTAssertEqual(record.triggerSource, "healthkit")
    }

    func testSyncDatesDistinctAndFiltersEmptyMetrics() {
        let userId = UUID()
        let records = [
            makeRecord(userId: userId, date: "2026-07-27", weight: 70, bodyFat: nil),
            makeRecord(userId: userId, date: "2026-07-26", weight: nil, bodyFat: 15),
            makeRecord(userId: userId, date: "2026-07-27", weight: 71, bodyFat: 14),
            makeRecord(userId: userId, date: "2026-07-25", weight: nil, bodyFat: nil),
        ]

        XCTAssertEqual(
            IntervalIcuSyncRequestRecord.syncDates(from: records),
            ["2026-07-26", "2026-07-27"]
        )
    }

    func testSyncDatesEmpty() {
        XCTAssertEqual(IntervalIcuSyncRequestRecord.syncDates(from: []), [])
    }

    func testIsPendingDuplicateError() {
        XCTAssertTrue(
            IntervalIcuSyncRequestEnqueuer.isPendingDuplicateError(
                NSError(domain: "Postgrest", code: 23505)
            )
        )
        XCTAssertTrue(
            IntervalIcuSyncRequestEnqueuer.isPendingDuplicateError(
                NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "duplicate key"])
            )
        )
        XCTAssertFalse(
            IntervalIcuSyncRequestEnqueuer.isPendingDuplicateError(
                NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "network error"])
            )
        )
    }

    private func makeRecord(
        userId: UUID,
        date: String,
        weight: Double?,
        bodyFat: Double?
    ) -> BodyCompositionSampleRecord {
        BodyCompositionSampleRecord(
            userId: userId,
            measuredAt: "\(date)T01:00:00Z",
            date: date,
            weightKg: weight,
            bodyFatPct: bodyFat,
            healthkitUuid: UUID(),
            sourceName: "Test",
            sourceBundleId: "test.bundle",
            metadata: .init(
                sampleType: "bodyMass",
                sourceName: "Test",
                sourceBundleId: "test.bundle"
            )
        )
    }
}
