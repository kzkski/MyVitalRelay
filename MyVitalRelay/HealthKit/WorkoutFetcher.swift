import HealthKit

struct WorkoutFetchResult {
    var workouts: [HKWorkout]
    var deletedUUIDs: [UUID]
    var newAnchor: HKQueryAnchor?
}

struct WorkoutFetcher {
    let store: HKHealthStore

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
}
