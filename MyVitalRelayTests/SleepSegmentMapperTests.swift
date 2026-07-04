import XCTest
import HealthKit
@testable import MyVitalRelay

final class SleepSegmentMapperTests: XCTestCase {
    private let userId = UUID()

    private func makeSnapshot(
        stage: HKCategoryValueSleepAnalysis,
        startDate: Date = Date(timeIntervalSince1970: 1_780_000_000),
        durationSec: TimeInterval = 3600
    ) -> SleepSegmentSnapshot {
        SleepSegmentSnapshot(
            uuid: UUID(),
            startDate: startDate,
            endDate: startDate.addingTimeInterval(durationSec),
            stage: stage,
            sourceName: "Apple Watch",
            sourceBundleId: "com.apple.health"
        )
    }

    func testCoreSleepSegment() {
        let record = SleepSegmentMapper.record(from: makeSnapshot(stage: .asleepCore), userId: userId)

        XCTAssertEqual(record?.stage, "core")
        XCTAssertEqual(record?.durationSec, 3600)
        XCTAssertEqual(record?.userId, userId)
    }

    func testDeepRemAndUnspecifiedStages() {
        XCTAssertEqual(SleepSegmentMapper.record(from: makeSnapshot(stage: .asleepDeep), userId: userId)?.stage, "deep")
        XCTAssertEqual(SleepSegmentMapper.record(from: makeSnapshot(stage: .asleepREM), userId: userId)?.stage, "rem")
        XCTAssertEqual(SleepSegmentMapper.record(from: makeSnapshot(stage: .asleepUnspecified), userId: userId)?.stage, "unspecified")
    }

    func testAwakeAndInBedAreSkipped() {
        XCTAssertNil(SleepSegmentMapper.record(from: makeSnapshot(stage: .awake), userId: userId))
        XCTAssertNil(SleepSegmentMapper.record(from: makeSnapshot(stage: .inBed), userId: userId))
    }

    func testZeroDurationIsSkipped() {
        XCTAssertNil(SleepSegmentMapper.record(from: makeSnapshot(stage: .asleepCore, durationSec: 0), userId: userId))
    }
}
