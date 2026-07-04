import HealthKit

/// HKWorkoutから必要値だけを抜き出した純粋データ。
/// HKWorkoutはテストで構築できないため、マッピングロジック（WorkoutMapper）はこの型だけを受け取る。
struct WorkoutSnapshot {
    var uuid: UUID
    var activityType: HKWorkoutActivityType
    var startDate: Date
    var endDate: Date
    var durationSec: Double
    var sourceName: String
    var sourceBundleId: String
    var distanceMeters: Double?
    var activeEnergyKcal: Double?
    var avgHeartRate: Double?
    var maxHeartRate: Double?
    var elevationAscendedMeters: Double?
    var strokeCount: Double?
    var isIndoorWorkout: Bool?
}

extension WorkoutSnapshot {
    init(workout: HKWorkout) {
        func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit) -> Double? {
            workout.statistics(for: HKQuantityType(id))?.sumQuantity()?.doubleValue(for: unit)
        }

        let hrUnit = HKUnit.count().unitDivided(by: .minute())
        let hrStats = workout.statistics(for: HKQuantityType(.heartRate))

        self.init(
            uuid: workout.uuid,
            activityType: workout.workoutActivityType,
            startDate: workout.startDate,
            endDate: workout.endDate,
            durationSec: workout.duration,
            sourceName: workout.sourceRevision.source.name,
            sourceBundleId: workout.sourceRevision.source.bundleIdentifier,
            distanceMeters: sum(.distanceWalkingRunning, unit: .meter())
                ?? sum(.distanceCycling, unit: .meter())
                ?? sum(.distanceSwimming, unit: .meter()),
            activeEnergyKcal: sum(.activeEnergyBurned, unit: .kilocalorie()),
            avgHeartRate: hrStats?.averageQuantity()?.doubleValue(for: hrUnit),
            maxHeartRate: hrStats?.maximumQuantity()?.doubleValue(for: hrUnit),
            elevationAscendedMeters: (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()),
            strokeCount: sum(.swimmingStrokeCount, unit: .count()),
            isIndoorWorkout: workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool
        )
    }
}

extension HKWorkoutActivityType {
    /// training_log.workout_typeに格納する生値相当の文字列。
    var displayName: String {
        switch self {
        case .running: "Running"
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .traditionalStrengthTraining: "TraditionalStrengthTraining"
        case .functionalStrengthTraining: "FunctionalStrengthTraining"
        case .hiking: "Hiking"
        case .elliptical: "Elliptical"
        case .rowing: "Rowing"
        case .stairClimbing: "StairClimbing"
        case .highIntensityIntervalTraining: "HIIT"
        case .crossTraining: "CrossTraining"
        case .yoga: "Yoga"
        case .coreTraining: "CoreTraining"
        default: "Other(\(rawValue))"
        }
    }
}
