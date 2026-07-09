import XCTest
@testable import MyVitalRelay

final class HeartRateZoneCalculatorTests: XCTestCase {
    private let boundaries = HeartRateZoneBoundaries(
        source: .fixedDefault,
        thresholdsBpm: [120, 140, 160, 180]
    )

    private let workoutStart = Date(timeIntervalSince1970: 1_780_000_000)
    private var workoutEnd: Date {
        workoutStart.addingTimeInterval(3_600)
    }

    private func sample(
        offset: TimeInterval,
        bpm: Double,
        duration: TimeInterval = 0
    ) -> HeartRateSamplePoint {
        let start = workoutStart.addingTimeInterval(offset)
        return HeartRateSamplePoint(
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            bpm: bpm
        )
    }

    func testZoneIndex_boundaries() {
        XCTAssertEqual(HeartRateZoneCalculator.zoneIndex(bpm: 119, thresholds: boundaries.thresholdsBpm), 1)
        XCTAssertEqual(HeartRateZoneCalculator.zoneIndex(bpm: 120, thresholds: boundaries.thresholdsBpm), 2)
        XCTAssertEqual(HeartRateZoneCalculator.zoneIndex(bpm: 139, thresholds: boundaries.thresholdsBpm), 2)
        XCTAssertEqual(HeartRateZoneCalculator.zoneIndex(bpm: 180, thresholds: boundaries.thresholdsBpm), 5)
    }

    func testAggregate_singleZone() {
        let samples = [
            sample(offset: 0, bpm: 130),
            sample(offset: 1_800, bpm: 135)
        ]

        let result = HeartRateZoneCalculator.aggregate(
            samples: samples,
            workoutStart: workoutStart,
            workoutEnd: workoutEnd,
            boundaries: boundaries,
            statisticsAvg: nil,
            statisticsMax: nil
        )

        XCTAssertEqual(result.zoneMinutes?["zone2"] ?? 0, 60.0, accuracy: 0.1)
        XCTAssertEqual(result.zoneMinutes?["zone1"] ?? -1, 0.0)
        XCTAssertEqual(result.zoneMinutes?["zone5"] ?? -1, 0.0)
        XCTAssertEqual(result.zoneMinutes?.count, HRZoneKey.all.count)
    }

    func testAggregate_allFiveKeysPresent() {
        let samples = [sample(offset: 0, bpm: 130)]

        let result = HeartRateZoneCalculator.aggregate(
            samples: samples,
            workoutStart: workoutStart,
            workoutEnd: workoutEnd,
            boundaries: boundaries,
            statisticsAvg: nil,
            statisticsMax: nil
        )

        XCTAssertEqual(Set(result.zoneMinutes?.keys.map { $0 } ?? []), Set(HRZoneKey.all))
    }

    func testAggregate_zoneTransition() {
        let samples = [
            sample(offset: 0, bpm: 130),
            sample(offset: 1_800, bpm: 170)
        ]

        let result = HeartRateZoneCalculator.aggregate(
            samples: samples,
            workoutStart: workoutStart,
            workoutEnd: workoutEnd,
            boundaries: boundaries,
            statisticsAvg: nil,
            statisticsMax: nil
        )

        XCTAssertEqual(result.zoneMinutes?["zone2"] ?? 0, 30.0, accuracy: 0.1)
        XCTAssertEqual(result.zoneMinutes?["zone4"] ?? 0, 30.0, accuracy: 0.1)
    }

    func testAggregate_clipsToWorkoutRange() {
        let samples = [
            HeartRateSamplePoint(
                startDate: workoutStart.addingTimeInterval(-600),
                endDate: workoutStart.addingTimeInterval(-300),
                bpm: 200
            ),
            sample(offset: 0, bpm: 130)
        ]

        let result = HeartRateZoneCalculator.aggregate(
            samples: samples,
            workoutStart: workoutStart,
            workoutEnd: workoutEnd,
            boundaries: boundaries,
            statisticsAvg: nil,
            statisticsMax: nil
        )

        XCTAssertEqual(result.zoneMinutes?["zone2"] ?? 0, 60.0, accuracy: 0.1)
        XCTAssertEqual(result.zoneMinutes?["zone5"] ?? -1, 0.0)
    }

    func testAggregate_emptySamples() {
        let result = HeartRateZoneCalculator.aggregate(
            samples: [],
            workoutStart: workoutStart,
            workoutEnd: workoutEnd,
            boundaries: boundaries,
            statisticsAvg: nil,
            statisticsMax: nil
        )

        XCTAssertNil(result.avgBpm)
        XCTAssertNil(result.maxBpm)
        XCTAssertNil(result.zoneMinutes)
        XCTAssertNil(result.zoneSource)
    }

    func testAggregate_statisticsPriority() {
        let samples = [sample(offset: 0, bpm: 130)]

        let result = HeartRateZoneCalculator.aggregate(
            samples: samples,
            workoutStart: workoutStart,
            workoutEnd: workoutEnd,
            boundaries: boundaries,
            statisticsAvg: 145,
            statisticsMax: 165
        )

        XCTAssertEqual(result.avgBpm, 145)
        XCTAssertEqual(result.maxBpm, 165)
        XCTAssertNotNil(result.zoneMinutes)
    }

    func testAggregate_statisticsNil_fallbackToSamples() {
        let samples = [
            sample(offset: 0, bpm: 100),
            sample(offset: 1_800, bpm: 140)
        ]

        let result = HeartRateZoneCalculator.aggregate(
            samples: samples,
            workoutStart: workoutStart,
            workoutEnd: workoutEnd,
            boundaries: boundaries,
            statisticsAvg: nil,
            statisticsMax: nil
        )

        XCTAssertEqual(result.avgBpm ?? 0, 120, accuracy: 0.1)
        XCTAssertEqual(result.maxBpm, 140)
    }

    func testBoundaries_fromAge() {
        let boundaries = HeartRateZoneBoundariesCalculator.fromAge(30)

        XCTAssertEqual(boundaries.source, .ageBased)
        XCTAssertEqual(boundaries.thresholdsBpm, [114, 133, 152, 171])
    }

    func testBoundaries_fixedDefault() {
        let boundaries = HeartRateZoneBoundariesCalculator.fixedDefault()

        XCTAssertEqual(boundaries.source, .fixedDefault)
        XCTAssertEqual(boundaries.thresholdsBpm, [111, 129.5, 148, 166.5])
    }

    func testAgeInYears() {
        var dateOfBirth = DateComponents()
        dateOfBirth.year = 1990
        dateOfBirth.month = 1
        dateOfBirth.day = 1

        let referenceDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let age = HeartRateZoneBoundariesCalculator.ageInYears(
            dateOfBirth: dateOfBirth,
            on: referenceDate
        )

        XCTAssertEqual(age, 36)
    }
}
