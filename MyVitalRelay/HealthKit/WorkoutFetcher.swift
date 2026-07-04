import HealthKit

struct WorkoutFetcher {
    let store: HKHealthStore

    /// 前回アンカー以降の新規ワークアウトのみを取得する（全件再取得による重複を避ける）。
    func fetchNewWorkouts(after anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], newAnchor: HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(),
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let workouts = (samples ?? []).compactMap { $0 as? HKWorkout }
                continuation.resume(returning: (workouts, newAnchor))
            }
            store.execute(query)
        }
    }
}
