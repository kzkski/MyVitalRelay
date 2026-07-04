import HealthKit

/// 新規ワークアウトがHealthKitに書き込まれたタイミングでアプリを起こし、自動同期する。
final class BackgroundDeliveryManager {
    private let store: HKHealthStore
    private let onUpdate: () async -> Void
    private var observerQuery: HKObserverQuery?

    init(store: HKHealthStore, onUpdate: @escaping () async -> Void) {
        self.store = store
        self.onUpdate = onUpdate
    }

    func enable() async throws {
        try await store.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate)
        guard observerQuery == nil else { return }
        let query = HKObserverQuery(sampleType: .workoutType(), predicate: nil) { [weak self] _, completionHandler, error in
            guard error == nil, let self else {
                completionHandler()
                return
            }
            Task {
                await self.onUpdate()
                // 同期完了後に呼ぶことで、OSに処理完了を伝える（呼び忘れは配信停止の原因になる）
                completionHandler()
            }
        }
        observerQuery = query
        store.execute(query)
    }
}
