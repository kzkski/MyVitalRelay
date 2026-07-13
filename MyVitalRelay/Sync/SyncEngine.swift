import Foundation
import HealthKit
import Observation
import Supabase

@Observable
@MainActor
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncedWorkoutCount = 0
    private(set) var lastSyncedWorkoutDeletedCount = 0
    private(set) var lastSyncedBodyCount = 0
    private(set) var lastSyncedSleepCount = 0
    private(set) var lastSyncedSleepDeletedCount = 0
    private(set) var lastSyncedDailyActivityCount = 0
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
            lastSyncedWorkoutCount = try await syncWorkouts(userId: userId)
            lastSyncedBodyCount = try await syncBodyComposition(userId: userId)
            lastSyncedSleepCount = try await syncSleepSegments(userId: userId)
            lastSyncedDailyActivityCount = try await syncDailyActivitySummary(userId: userId)
            lastSyncAt = .now
            UserDefaults.standard.set(lastSyncAt, forKey: "lastSyncAt")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func syncWorkouts(userId: UUID) async throws -> Int {
        let fetcher = WorkoutFetcher(store: store)
        let result = try await fetcher.fetchNewWorkouts(after: WorkoutAnchorStore.load())
        let backfillWorkouts = try await fetcher.fetchBackfillWorkouts()
        let workouts = WorkoutFetcher.merging(result.workouts, with: backfillWorkouts)

        let hrFetcher = WorkoutHeartRateFetcher(store: store)
        let boundaries = hrFetcher.loadZoneBoundaries(referenceDate: .now)

        var snapshots: [WorkoutSnapshot] = []
        snapshots.reserveCapacity(workouts.count)

        for workout in workouts {
            var snapshot = WorkoutSnapshot(workout: workout)

            do {
                let enrichment = try await hrFetcher.enrich(
                    workout: workout,
                    statisticsAvg: snapshot.avgHeartRate,
                    statisticsMax: snapshot.maxHeartRate,
                    boundaries: boundaries
                )
                snapshot.avgHeartRate = enrichment.avgBpm
                snapshot.maxHeartRate = enrichment.maxBpm
                snapshot.hrZoneMinutes = enrichment.zoneMinutes
                snapshot.hrZoneSource = enrichment.zoneSource
            } catch {
                // 個別ワークアウトのHR取得失敗時はstatisticsベースのまま同期を続行する。
            }

            snapshots.append(snapshot)
        }

        let records = snapshots.map {
            WorkoutMapper.record(from: $0, userId: userId)
        }
        if !records.isEmpty {
            try await client.from("training_log")
                .upsert(records, onConflict: "user_id,start_time,end_time,workout_type")
                .execute()

            let garminRecords = records.filter { $0.dataSource == "garmin" }
            await GarminSyncRequestEnqueuer.enqueueActivitiesIfNeeded(
                client: client,
                garminRecords: garminRecords
            )
        }

        // 削除通知の処理は必ず論理キーupsertの後に行う（Issue #12）。
        // Garmin等のUUID差し替えでは deletedObjects に旧UUIDが載るが、差し替え後の
        // ワークアウトが同一バッチにあれば、upsertが既存行の healthkit_uuid を
        // 新UUIDへ更新済みのため、旧UUIDでのDELETEは何も消さない（追記が保持される）。
        // 差し替えの片割れが後続バッチで届くケースに備え、会話で追記された列を持つ行は
        // 削除対象から外す。残った行は後続の論理キーupsertで新UUIDへ更新されて1行に収まる。
        if !result.deletedUUIDs.isEmpty {
            try await client.from("training_log")
                .delete()
                .in("healthkit_uuid", values: result.deletedUUIDs)
                .is("rpe", value: nil)
                .is("condition_notes", value: nil)
                .is("surface", value: nil)
                .is("notes", value: nil)
                .is("equipment", value: nil)
                .execute()
        }

        if let newAnchor = result.newAnchor {
            WorkoutAnchorStore.save(newAnchor)
        }
        lastSyncedWorkoutDeletedCount = result.deletedUUIDs.count
        return records.count
    }

    private func syncBodyComposition(userId: UUID) async throws -> Int {
        let fetcher = BodyCompositionFetcher(store: store)
        let result = try await fetcher.fetchNewSamples(
            after: BodyCompositionAnchorStore.loadBodyMass(),
            bodyFatAnchor: BodyCompositionAnchorStore.loadBodyFat()
        )
        let records = result.samples.map {
            BodyCompositionMapper.record(from: BodyCompositionSnapshot(sample: $0), userId: userId)
        }
        if !records.isEmpty {
            try await client.from("body_composition_sample")
                .upsert(records, onConflict: "healthkit_uuid")
                .execute()
        }
        if let anchor = result.bodyMassAnchor {
            BodyCompositionAnchorStore.saveBodyMass(anchor)
        }
        if let anchor = result.bodyFatAnchor {
            BodyCompositionAnchorStore.saveBodyFat(anchor)
        }
        return records.count
    }

    private func syncSleepSegments(userId: UUID) async throws -> Int {
        let fetcher = SleepSegmentFetcher(store: store)
        let result = try await fetcher.fetchNewSegments(after: SleepSegmentAnchorStore.load())
        let deletedUUIDs = result.deletedUUIDs

        if !deletedUUIDs.isEmpty {
            try await client.from("sleep_segment")
                .delete()
                .in("healthkit_uuid", values: deletedUUIDs)
                .execute()
        }

        let records = result.samples.compactMap { sample in
            SleepSegmentMapper.record(from: SleepSegmentSnapshot(sample: sample), userId: userId)
        }
        if !records.isEmpty {
            try await client.from("sleep_segment")
                .upsert(records, onConflict: "user_id,start_time,end_time,stage")
                .execute()
        }
        if let newAnchor = result.newAnchor {
            SleepSegmentAnchorStore.save(newAnchor)
        }

        lastSyncedSleepDeletedCount = deletedUUIDs.count
        return records.count
    }

    private func syncDailyActivitySummary(userId: UUID) async throws -> Int {
        let fetcher = DailyActivityFetcher(store: store)
        let days = try await fetcher.fetchFinalizedDays()
        let records = DailyActivityMapper.records(from: days, userId: userId)
        if !records.isEmpty {
            try await client.from("daily_activity_summary")
                .upsert(records, onConflict: "user_id,date")
                .execute()
        }
        return records.count
    }
}
