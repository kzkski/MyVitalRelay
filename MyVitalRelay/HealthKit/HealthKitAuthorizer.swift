import HealthKit

enum HealthKitAuthorizer {
    /// MVPで同期するのはワークアウト系のみだが、将来のdaily_log同期移管時に再認可フローを
    /// 踏まなくて済むよう、体組成・睡眠・日次活動量も含めて初回に一括で読み取り許可を要求する。
    static let readTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.basalEnergyBurned),
        HKQuantityType(.heartRate),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.distanceCycling),
        HKQuantityType(.distanceSwimming),
        HKQuantityType(.swimmingStrokeCount),
        HKQuantityType(.stepCount),
        HKQuantityType(.bodyMass),
        HKQuantityType(.bodyFatPercentage),
        HKCategoryType(.sleepAnalysis),
    ]

    static func requestAuthorization(store: HKHealthStore) async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }
}
