import Foundation
import HealthKit
import Observation
import Supabase

@Observable
@MainActor
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncedCount = 0
    private(set) var lastError: String?

    private let store = HKHealthStore()
    private let client = SupabaseClientProvider.shared
    private var backgroundDelivery: BackgroundDeliveryManager?
    private var started = false

    init() {
        lastSyncAt = UserDefaults.standard.object(forKey: "lastSyncAt") as? Date
    }

    /// サインイン後に呼ばれる。認可要求→バックグラウンド配信有効化→初回同期。
    func start() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "この端末ではHealthKitを利用できません"
            return
        }
        do {
            try await HealthKitAuthorizer.requestAuthorization(store: store)
            if !started {
                let manager = BackgroundDeliveryManager(store: store) { [weak self] in
                    await self?.sync()
                }
                try await manager.enable()
                backgroundDelivery = manager
                started = true
            }
        } catch {
            lastError = error.localizedDescription
        }
        await sync()
    }

    func sync() async {
        guard !isSyncing else { return }
        guard let userId = (try? await client.auth.session)?.user.id else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let fetcher = WorkoutFetcher(store: store)
            let (workouts, newAnchor) = try await fetcher.fetchNewWorkouts(after: WorkoutAnchorStore.load())
            let records = workouts.map {
                WorkoutMapper.record(from: WorkoutSnapshot(workout: $0), userId: userId)
            }
            if !records.isEmpty {
                try await client.from("training_log")
                    .upsert(records, onConflict: "healthkit_uuid")
                    .execute()
            }
            // アンカーは書き込み成功後にのみ前進。失敗時は次回同じ範囲を再取得する（アップサートなので重複しない）。
            if let newAnchor {
                WorkoutAnchorStore.save(newAnchor)
            }
            lastSyncedCount = records.count
            lastSyncAt = .now
            UserDefaults.standard.set(lastSyncAt, forKey: "lastSyncAt")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
