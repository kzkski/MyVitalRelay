import HealthKit

struct BodyCompositionFetchResult {
    var samples: [HKQuantitySample]
    var bodyMassAnchor: HKQueryAnchor?
    var bodyFatAnchor: HKQueryAnchor?
}

struct BodyCompositionFetcher {
    let store: HKHealthStore

    func fetchNewSamples(
        after bodyMassAnchor: HKQueryAnchor?,
        bodyFatAnchor: HKQueryAnchor?
    ) async throws -> BodyCompositionFetchResult {
        async let mass = fetch(type: HKQuantityType(.bodyMass), anchor: bodyMassAnchor)
        async let fat = fetch(type: HKQuantityType(.bodyFatPercentage), anchor: bodyFatAnchor)
        let (massResult, fatResult) = try await (mass, fat)
        return BodyCompositionFetchResult(
            samples: massResult.samples + fatResult.samples,
            bodyMassAnchor: massResult.anchor,
            bodyFatAnchor: fatResult.anchor
        )
    }

    private func fetch(type: HKQuantityType, anchor: HKQueryAnchor?) async throws -> (samples: [HKQuantitySample], anchor: HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let quantitySamples = (samples ?? []).compactMap { $0 as? HKQuantitySample }
                continuation.resume(returning: (quantitySamples, newAnchor))
            }
            store.execute(query)
        }
    }
}
