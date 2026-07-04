import HealthKit

struct SleepSegmentFetcher {
    let store: HKHealthStore

    func fetchNewSegments(after anchor: HKQueryAnchor?) async throws -> (samples: [HKCategorySample], newAnchor: HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKCategoryType(.sleepAnalysis),
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let categorySamples = (samples ?? []).compactMap { $0 as? HKCategorySample }
                continuation.resume(returning: (categorySamples, newAnchor))
            }
            store.execute(query)
        }
    }
}
