import HealthKit

struct SleepSegmentFetchResult {
    var samples: [HKCategorySample]
    var deletedUUIDs: [UUID]
    var newAnchor: HKQueryAnchor?
}

struct SleepSegmentFetcher {
    let store: HKHealthStore

    func fetchNewSegments(after anchor: HKQueryAnchor?) async throws -> SleepSegmentFetchResult {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKCategoryType(.sleepAnalysis),
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let categorySamples = (samples ?? []).compactMap { $0 as? HKCategorySample }
                let deletedUUIDs = (deletedObjects ?? []).map(\.uuid)
                continuation.resume(returning: SleepSegmentFetchResult(
                    samples: categorySamples,
                    deletedUUIDs: deletedUUIDs,
                    newAnchor: newAnchor
                ))
            }
            store.execute(query)
        }
    }
}
