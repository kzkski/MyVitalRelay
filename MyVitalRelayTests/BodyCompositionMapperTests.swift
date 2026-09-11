import XCTest
import HealthKit
@testable import MyVitalRelay

final class BodyCompositionMapperTests: XCTestCase {
    private let userId = UUID()

    private func makeSnapshot(
        sampleType: HKQuantityTypeIdentifier,
        measuredAt: Date = Date(timeIntervalSince1970: 1_780_000_000),
        value: Double,
        sourceName: String = "Health",
        sourceBundleId: String = "com.apple.Health"
    ) -> BodyCompositionSnapshot {
        BodyCompositionSnapshot(
            uuid: UUID(),
            sampleType: sampleType,
            measuredAt: measuredAt,
            value: value,
            sourceName: sourceName,
            sourceBundleId: sourceBundleId
        )
    }

    func testBodyMassMapping() throws {
        let record = try XCTUnwrap(
            BodyCompositionMapper.record(
                from: makeSnapshot(sampleType: .bodyMass, value: 72.3),
                userId: userId
            )
        )

        XCTAssertEqual(record.weightKg, 72.3)
        XCTAssertNil(record.bodyFatPct)
        XCTAssertEqual(record.metadata.sampleType, HKQuantityTypeIdentifier.bodyMass.rawValue)
        XCTAssertEqual(record.userId, userId)
    }

    func testBodyFatMapping() throws {
        let record = try XCTUnwrap(
            BodyCompositionMapper.record(
                from: makeSnapshot(sampleType: .bodyFatPercentage, value: 15.2),
                userId: userId
            )
        )

        XCTAssertNil(record.weightKg)
        XCTAssertEqual(record.bodyFatPct, 15.2)
    }

    func testDateUsesTokyoTimeZone() throws {
        let formatter = ISO8601DateFormatter()
        let measuredAt = formatter.date(from: "2026-07-03T16:00:00Z")!
        let record = try XCTUnwrap(
            BodyCompositionMapper.record(
                from: makeSnapshot(sampleType: .bodyMass, measuredAt: measuredAt, value: 70.0),
                userId: userId
            )
        )

        XCTAssertEqual(record.date, "2026-07-04")
    }

    func testDeniesGarminConnectMobileBodyMass() {
        let record = BodyCompositionMapper.record(
            from: makeSnapshot(
                sampleType: .bodyMass,
                value: 64.2,
                sourceName: "Connect",
                sourceBundleId: "com.garmin.connect.mobile"
            ),
            userId: userId
        )
        XCTAssertNil(record)
    }

    func testDeniesGarminConnectMobileBodyFat() {
        let record = BodyCompositionMapper.record(
            from: makeSnapshot(
                sampleType: .bodyFatPercentage,
                value: 18.0,
                sourceName: "Connect",
                sourceBundleId: "com.garmin.connect.mobile"
            ),
            userId: userId
        )
        XCTAssertNil(record)
    }

    func testAllowsEufyLife() throws {
        let record = try XCTUnwrap(
            BodyCompositionMapper.record(
                from: makeSnapshot(
                    sampleType: .bodyMass,
                    value: 64.3,
                    sourceName: "eufy Life",
                    sourceBundleId: "com.oceanwing.z.smarthome"
                ),
                userId: userId
            )
        )
        XCTAssertEqual(record.weightKg, 64.3)
        XCTAssertEqual(record.sourceBundleId, "com.oceanwing.z.smarthome")
    }

    func testAllowsOmronConnect() throws {
        let record = try XCTUnwrap(
            BodyCompositionMapper.record(
                from: makeSnapshot(
                    sampleType: .bodyMass,
                    value: 71.0,
                    sourceName: "omron connect",
                    sourceBundleId: "jp.co.omron.healthcare.omronconnect"
                ),
                userId: userId
            )
        )
        XCTAssertEqual(record.weightKg, 71.0)
    }

    func testDenylistUsesBundleIdNotSourceName() throws {
        let record = try XCTUnwrap(
            BodyCompositionMapper.record(
                from: makeSnapshot(
                    sampleType: .bodyMass,
                    value: 64.2,
                    sourceName: "Connect",
                    sourceBundleId: "com.example.other"
                ),
                userId: userId
            )
        )
        XCTAssertEqual(record.weightKg, 64.2)
    }
}
