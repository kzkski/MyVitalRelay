import XCTest
@testable import MyVitalRelay

final class HealthKitDeletionBatchesTests: XCTestCase {
    func testEmptyInput() {
        XCTAssertEqual(HealthKitDeletionBatches.batches(of: []), [])
    }

    func testSingleBatchWhenUnderLimit() {
        let uuids = (0..<3).map { _ in UUID() }
        let batches = HealthKitDeletionBatches.batches(of: uuids, size: 100)
        XCTAssertEqual(batches, [uuids])
    }

    func testSplitsOnBatchSize() {
        let uuids = (0..<250).map { _ in UUID() }
        let batches = HealthKitDeletionBatches.batches(of: uuids, size: 100)
        XCTAssertEqual(batches.map(\.count), [100, 100, 50])
        XCTAssertEqual(batches.flatMap { $0 }, uuids)
    }
}
