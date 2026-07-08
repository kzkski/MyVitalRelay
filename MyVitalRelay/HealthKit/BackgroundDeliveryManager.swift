import HealthKit

/// HealthKit 更新時にアプリを起こし、自動同期する。
final class BackgroundDeliveryManager {
    private struct ObservedType {
        let sampleType: HKSampleType
        let frequency: HKUpdateFrequency
    }

    private let store: HKHealthStore
    private let onUpdate: () async -> Void
    private var observerQueries: [HKObserverQuery] = []

    private static let observedTypes: [ObservedType] = [
        .init(sampleType: .workoutType(), frequency: .immediate),
        .init(sampleType: HKQuantityType(.bodyMass), frequency: .immediate),
        .init(sampleType: HKQuantityType(.bodyFatPercentage), frequency: .immediate),
        .init(sampleType: HKCategoryType(.sleepAnalysis), frequency: .daily),
        .init(sampleType: HKQuantityType(.activeEnergyBurned), frequency: .daily),
        .init(sampleType: HKQuantityType(.basalEnergyBurned), frequency: .daily),
    ]

    init(store: HKHealthStore, onUpdate: @escaping () async -> Void) {
        self.store = store
        self.onUpdate = onUpdate
    }

    func enable() async throws {
        for config in Self.observedTypes {
            try await store.enableBackgroundDelivery(for: config.sampleType, frequency: config.frequency)
        }
        guard observerQueries.isEmpty else { return }
        for config in Self.observedTypes {
            let query = HKObserverQuery(sampleType: config.sampleType, predicate: nil) { [weak self] _, completionHandler, error in
                guard error == nil, let self else {
                    completionHandler()
                    return
                }
                Task {
                    await self.onUpdate()
                    completionHandler()
                }
            }
            observerQueries.append(query)
            store.execute(query)
        }
    }
}
