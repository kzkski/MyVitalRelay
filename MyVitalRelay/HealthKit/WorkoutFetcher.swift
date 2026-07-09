import HealthKit

struct WorkoutFetchResult {
    var workouts: [HKWorkout]
    var deletedUUIDs: [UUID]
    var newAnchor: HKQueryAnchor?
}

struct WorkoutFetcher {
    let store: HKHealthStore

    /// 心拍バックフィル用の遡及日数。アンカー差分に載らない既存ワークアウトを再 enrichment する。
    static let backfillLookbackDays = 14

    /// 前回アンカー以降の新規ワークアウトのみを取得する（全件再取得による重複を避ける）。
    func fetchNewWorkouts(after anchor: HKQueryAnchor?) async throws -> WorkoutFetchResult {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(),
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let workouts = (samples ?? []).compactMap { $0 as? HKWorkout }
                let deletedUUIDs = (deletedObjects ?? []).map(\.uuid)
                continuation.resume(returning: WorkoutFetchResult(
                    workouts: workouts,
                    deletedUUIDs: deletedUUIDs,
                    newAnchor: newAnchor
                ))
            }
            store.execute(query)
        }
    }

    /// 指定期間のワークアウトを取得する（バックフィル用）。
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: []
        )

        return try await withCheckedThrowingContinuation { continuation in
            let sortDescriptor = NSSortDescriptor(
                key: HKSampleSortIdentifierStartDate,
                ascending: true
            )
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let workouts = (samples ?? []).compactMap { $0 as? HKWorkout }
                continuation.resume(returning: workouts)
            }
            store.execute(query)
        }
    }

    func fetchBackfillWorkouts(now: Date = .now) async throws -> [HKWorkout] {
        guard let startDate = Calendar.current.date(
            byAdding: .day,
            value: -Self.backfillLookbackDays,
            to: now
        ) else {
            return []
        }
        return try await fetchWorkouts(from: startDate, to: now)
    }

    /// 同一 UUID は `prioritized` 側を優先してマージする。
    static func merging(_ prioritized: [HKWorkout], with others: [HKWorkout]) -> [HKWorkout] {
        var byUUID: [UUID: HKWorkout] = [:]
        for workout in others {
            byUUID[workout.uuid] = workout
        }
        for workout in prioritized {
            byUUID[workout.uuid] = workout
        }
        return byUUID.values.sorted { $0.startDate < $1.startDate }
    }
}
