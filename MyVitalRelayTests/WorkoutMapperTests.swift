import XCTest
import HealthKit
@testable import MyVitalRelay

final class WorkoutMapperTests: XCTestCase {
    private let userId = UUID()

    private func makeSnapshot(
        uuid: UUID = UUID(),
        activityType: HKWorkoutActivityType = .running,
        startDate: Date = Date(timeIntervalSince1970: 1_780_000_000),
        durationSec: Double = 3000,
        sourceName: String = "Garmin Connect",
        sourceBundleId: String = "com.garmin.connect.mobile",
        distanceMeters: Double? = 10_000,
        activeEnergyKcal: Double? = 600,
        avgHeartRate: Double? = 145,
        maxHeartRate: Double? = 165,
        elevationAscendedMeters: Double? = 42,
        strokeCount: Double? = nil,
        isIndoorWorkout: Bool? = nil
    ) -> WorkoutSnapshot {
        WorkoutSnapshot(
            uuid: uuid,
            activityType: activityType,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(durationSec),
            durationSec: durationSec,
            sourceName: sourceName,
            sourceBundleId: sourceBundleId,
            distanceMeters: distanceMeters,
            activeEnergyKcal: activeEnergyKcal,
            avgHeartRate: avgHeartRate,
            maxHeartRate: maxHeartRate,
            elevationAscendedMeters: elevationAscendedMeters,
            strokeCount: strokeCount,
            isIndoorWorkout: isIndoorWorkout
        )
    }

    func testGarminOutdoorRun() {
        let record = WorkoutMapper.record(from: makeSnapshot(), userId: userId)

        XCTAssertEqual(record.dataSource, "garmin")
        XCTAssertEqual(record.discipline, "run")
        XCTAssertEqual(record.workoutType, "Running")
        XCTAssertEqual(record.durationMin, 50.0, accuracy: 0.001)
        XCTAssertEqual(record.distanceKm ?? 0, 10.0, accuracy: 0.001)
        XCTAssertEqual(record.avgSpeedKmh ?? 0, 12.0, accuracy: 0.001)
        XCTAssertEqual(record.avgHr, 145)
        XCTAssertEqual(record.maxHr, 165)
        XCTAssertEqual(record.elevationGainM, 42)
        XCTAssertEqual(record.userId, userId)
    }

    func testLifeFitnessTreadmillWalkingCountsAsRun() {
        // Life Fitness由来：心拍・標高なし、walkingでもdisciplineはrun（認識された運動距離は全て走行距離扱い）
        let snapshot = makeSnapshot(
            activityType: .walking,
            sourceName: "Life Fitness",
            sourceBundleId: "com.lifefitness.halo",
            distanceMeters: 5_200,
            avgHeartRate: nil,
            maxHeartRate: nil,
            elevationAscendedMeters: nil,
            isIndoorWorkout: true
        )
        let record = WorkoutMapper.record(from: snapshot, userId: userId)

        XCTAssertEqual(record.dataSource, "life_fitness")
        XCTAssertEqual(record.discipline, "run")
        XCTAssertNil(record.avgHr)
        XCTAssertNil(record.elevationGainM)
        XCTAssertEqual(record.metadata.indoorWorkout, true)
    }

    func testUnknownSourceFallsBackToManualAndKeepsRawSource() {
        let snapshot = makeSnapshot(
            activityType: .traditionalStrengthTraining,
            sourceName: "Mystery Gym App",
            sourceBundleId: "com.example.gym",
            distanceMeters: nil,
            avgHeartRate: nil,
            maxHeartRate: nil,
            elevationAscendedMeters: nil
        )
        let record = WorkoutMapper.record(from: snapshot, userId: userId)

        XCTAssertEqual(record.dataSource, "manual")
        XCTAssertEqual(record.discipline, "strength")
        XCTAssertNil(record.distanceKm)
        XCTAssertNil(record.avgSpeedKmh)
        XCTAssertEqual(record.metadata.sourceName, "Mystery Gym App")
        XCTAssertEqual(record.metadata.sourceBundleId, "com.example.gym")
    }

    func testDateUsesTokyoTimeZone() {
        // 2026-07-03 16:00 UTC = 2026-07-04 01:00 JST → dateは日本時間で2026-07-04になる
        let formatter = ISO8601DateFormatter()
        let startDate = formatter.date(from: "2026-07-03T16:00:00Z")!
        let record = WorkoutMapper.record(from: makeSnapshot(startDate: startDate), userId: userId)

        XCTAssertEqual(record.date, "2026-07-04")
    }

    func testCyclingAndSwimmingDisciplines() {
        XCTAssertEqual(WorkoutMapper.discipline(for: .cycling), "bike")
        XCTAssertEqual(WorkoutMapper.discipline(for: .swimming), "swim")
        XCTAssertEqual(WorkoutMapper.discipline(for: .yoga), "other")
    }

    func testLogicalKeyIsStableAcrossDifferentUUIDs() {
        let base = makeSnapshot(uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let other = makeSnapshot(uuid: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

        XCTAssertEqual(
            WorkoutMapper.logicalKey(from: base),
            WorkoutMapper.logicalKey(from: other)
        )
    }

    func testLogicalKeyDiffersForDifferentWorkoutTypes() {
        let run = makeSnapshot(activityType: .running)
        let walk = makeSnapshot(activityType: .walking)

        XCTAssertNotEqual(
            WorkoutMapper.logicalKey(from: run),
            WorkoutMapper.logicalKey(from: walk)
        )
    }

    func testLogicalKeyDiffersForDifferentTimeRange() {
        let a = makeSnapshot(startDate: Date(timeIntervalSince1970: 1_780_000_000))
        let b = makeSnapshot(startDate: Date(timeIntervalSince1970: 1_780_100_000))

        XCTAssertNotEqual(
            WorkoutMapper.logicalKey(from: a),
            WorkoutMapper.logicalKey(from: b)
        )
    }
}
