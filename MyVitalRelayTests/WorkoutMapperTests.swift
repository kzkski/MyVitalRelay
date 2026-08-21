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
        hrZoneMinutes: HRZoneMinutes? = nil,
        hrZoneSource: HeartRateZoneBoundaries.Source? = nil,
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
            hrZoneMinutes: hrZoneMinutes,
            hrZoneSource: hrZoneSource,
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
        XCTAssertEqual(record.elevationGainM, 42)
        XCTAssertEqual(record.userId, userId)
    }

    func testLifeFitnessTreadmillWalkingCountsAsRun() {
        // Life Fitness由来：標高なし、walkingでもdisciplineはrun（認識された運動距離は全て走行距離扱い）
        let snapshot = makeSnapshot(
            activityType: .walking,
            sourceName: "Life Fitness",
            sourceBundleId: "com.lifefitness.halo",
            distanceMeters: 5_200,
            elevationAscendedMeters: nil,
            isIndoorWorkout: true
        )
        let record = WorkoutMapper.record(from: snapshot, userId: userId)

        XCTAssertEqual(record.dataSource, "life_fitness")
        XCTAssertEqual(record.discipline, "run")
        XCTAssertNil(record.elevationGainM)
        XCTAssertEqual(record.metadata.indoorWorkout, true)
    }

    func testUnknownSourceFallsBackToManualAndKeepsRawSource() {
        let snapshot = makeSnapshot(
            activityType: .traditionalStrengthTraining,
            sourceName: "Mystery Gym App",
            sourceBundleId: "com.example.gym",
            distanceMeters: nil,
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

    func testHrZoneMinutesAndSourcePassthrough() {
        let zones: HRZoneMinutes = [
            "zone1": 5.0,
            "zone2": 20.0,
            "zone3": 15.0,
            "zone4": 8.0,
            "zone5": 2.0
        ]
        let record = WorkoutMapper.record(
            from: makeSnapshot(hrZoneMinutes: zones, hrZoneSource: .fixedDefault),
            userId: userId
        )

        XCTAssertEqual(record.hrZoneMinutes, zones)
        XCTAssertEqual(record.metadata.hrZoneSource, "fixed_default")
    }

    func testHrZoneSourceOmittedWhenNoZones() {
        let record = WorkoutMapper.record(
            from: makeSnapshot(),
            userId: userId
        )

        XCTAssertNil(record.hrZoneMinutes)
        XCTAssertNil(record.metadata.hrZoneSource)
    }

    func testEncodeExcludesManualAnnotationColumns() throws {
        // rpe / condition_notes / surface / notes / equipment は会話で記入される列。
        // ペイロードに含めると論理キーupsertのUPDATE経路で上書き消去されるため、
        // エンコード結果に絶対に含まれないことを固定する（Issue #12）。
        let record = WorkoutMapper.record(from: makeSnapshot(), userId: userId)

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"healthkit_uuid\""))
        XCTAssertFalse(json.contains("\"rpe\""))
        XCTAssertFalse(json.contains("\"condition_notes\""))
        XCTAssertFalse(json.contains("\"surface\""))
        XCTAssertFalse(json.contains("\"notes\""))
        XCTAssertFalse(json.contains("\"equipment\""))
        XCTAssertFalse(json.contains("\"id\""))
    }

    /// Issue #28: garmin 行は calories_burned キーを送らない（Garmin sync が合計を埋める）。
    func testGarminOmitsCaloriesBurnedFromEncode() throws {
        let record = WorkoutMapper.record(from: makeSnapshot(activeEnergyKcal: 600), userId: userId)
        XCTAssertEqual(record.dataSource, "garmin")
        XCTAssertNil(record.caloriesBurned)

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"calories_burned\""))
    }

    func testNonGarminIncludesCaloriesBurnedInEncode() throws {
        let snapshot = makeSnapshot(
            sourceName: "Life Fitness",
            sourceBundleId: "com.lifefitness.halo",
            activeEnergyKcal: 450
        )
        let record = WorkoutMapper.record(from: snapshot, userId: userId)
        XCTAssertEqual(record.dataSource, "life_fitness")
        XCTAssertEqual(record.caloriesBurned, 450)

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"calories_burned\""))
    }

    func testPartitionTrainingLogRecordsForCaloriesUpsert() throws {
        let garmin = WorkoutMapper.record(from: makeSnapshot(), userId: userId)
        let lifeFitness = WorkoutMapper.record(
            from: makeSnapshot(
                sourceName: "Life Fitness",
                sourceBundleId: "com.lifefitness.halo",
                activeEnergyKcal: 300
            ),
            userId: userId
        )
        let manual = WorkoutMapper.record(
            from: makeSnapshot(
                sourceName: "Mystery Gym",
                sourceBundleId: "com.example.gym",
                activeEnergyKcal: 200
            ),
            userId: userId
        )

        let partitioned = WorkoutMapper.partitionTrainingLogRecordsForCaloriesUpsert([
            garmin, lifeFitness, manual,
        ])
        XCTAssertEqual(partitioned.omitCalories.map(\.dataSource), ["garmin"])
        XCTAssertEqual(
            Set(partitioned.includeCalories.map(\.dataSource)),
            Set(["life_fitness", "manual"])
        )

        let omitData = try JSONEncoder().encode(partitioned.omitCalories)
        let omitJSON = try XCTUnwrap(String(data: omitData, encoding: .utf8))
        XCTAssertFalse(omitJSON.contains("\"calories_burned\""))

        let includeData = try JSONEncoder().encode(partitioned.includeCalories)
        let includeJSON = try XCTUnwrap(String(data: includeData, encoding: .utf8))
        XCTAssertTrue(includeJSON.contains("\"calories_burned\""))
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
