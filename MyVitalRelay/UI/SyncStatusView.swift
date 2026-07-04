import SwiftUI

struct RecentTrainingRow: Decodable, Identifiable {
    let id: UUID
    let date: String
    let discipline: String
    let dataSource: String
    let distanceKm: Double?
    let durationMin: Double?

    enum CodingKeys: String, CodingKey {
        case id, date, discipline
        case dataSource = "data_source"
        case distanceKm = "distance_km"
        case durationMin = "duration_min"
    }
}

struct RecentBodyCompositionRow: Decodable, Identifiable {
    let id: UUID
    let date: String
    let measuredAt: String
    let weightKg: Double?
    let bodyFatPct: Double?

    enum CodingKeys: String, CodingKey {
        case id, date
        case measuredAt = "measured_at"
        case weightKg = "weight_kg"
        case bodyFatPct = "body_fat_pct"
    }
}

struct RecentSleepRow: Decodable, Identifiable {
    let id: UUID
    let startTime: String
    let stage: String
    let durationSec: Int

    enum CodingKeys: String, CodingKey {
        case id, stage
        case startTime = "start_time"
        case durationSec = "duration_sec"
    }
}

struct SyncStatusView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SyncEngine.self) private var syncEngine
    @State private var recentWorkouts: [RecentTrainingRow] = []
    @State private var recentBody: [RecentBodyCompositionRow] = []
    @State private var recentSleep: [RecentSleepRow] = []

    var body: some View {
        NavigationStack {
            List {
                Section("同期状況") {
                    LabeledContent("最終同期", value: syncEngine.lastSyncAt.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "未実行")
                    LabeledContent("直近の同期", value: syncSummary)
                    if let error = syncEngine.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section("直近のトレーニング（training_log）") {
                    recentList(recentWorkouts, empty: "レコードなし") { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.date)  \(row.discipline)")
                            Text("\(row.dataSource) / \(row.distanceKm.map { String(format: "%.2f km", $0) } ?? "-") / \(row.durationMin.map { String(format: "%.0f 分", $0) } ?? "-")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("直近の体組成（body_composition_sample）") {
                    recentList(recentBody, empty: "レコードなし") { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.date)
                            Text(bodySummary(row))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("直近の睡眠（sleep_segment）") {
                    recentList(recentSleep, empty: "レコードなし") { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.stage)  \(sleepDuration(row.durationSec))")
                            Text(row.startTime)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("MyVitalRelay")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("サインアウト") {
                        Task { await auth.signOut() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await syncEngine.sync()
                            await loadRecent()
                        }
                    } label: {
                        if syncEngine.isSyncing {
                            ProgressView()
                        } else {
                            Text("今すぐ同期")
                        }
                    }
                }
            }
            .task { await loadRecent() }
            .refreshable {
                await syncEngine.sync()
                await loadRecent()
            }
        }
    }

    private var syncSummary: String {
        "ワークアウト \(syncEngine.lastSyncedWorkoutCount) / 体組成 \(syncEngine.lastSyncedBodyCount) / 睡眠 \(syncEngine.lastSyncedSleepCount)"
    }

    @ViewBuilder
    private func recentList<Row: Identifiable, Content: View>(
        _ rows: [Row],
        empty: String,
        @ViewBuilder content: @escaping (Row) -> Content
    ) -> some View {
        if rows.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        } else {
            ForEach(rows) { row in
                content(row)
            }
        }
    }

    private func bodySummary(_ row: RecentBodyCompositionRow) -> String {
        let parts = [
            row.weightKg.map { String(format: "%.1f kg", $0) },
            row.bodyFatPct.map { String(format: "%.1f %%", $0) },
        ].compactMap { $0 }
        return parts.isEmpty ? "-" : parts.joined(separator: " / ")
    }

    private func sleepDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return "\(hours)時間\(minutes)分"
    }

    private func loadRecent() async {
        let client = SupabaseClientProvider.shared
        async let workouts: [RecentTrainingRow] = {
            do {
                return try await client.from("training_log")
                    .select("id, date, discipline, data_source, distance_km, duration_min")
                    .order("date", ascending: false)
                    .order("start_time", ascending: false)
                    .limit(10)
                    .execute()
                    .value
            } catch { return [] }
        }()
        async let body: [RecentBodyCompositionRow] = {
            do {
                return try await client.from("body_composition_sample")
                    .select("id, date, measured_at, weight_kg, body_fat_pct")
                    .order("measured_at", ascending: false)
                    .limit(10)
                    .execute()
                    .value
            } catch { return [] }
        }()
        async let sleep: [RecentSleepRow] = {
            do {
                return try await client.from("sleep_segment")
                    .select("id, start_time, stage, duration_sec")
                    .order("start_time", ascending: false)
                    .limit(10)
                    .execute()
                    .value
            } catch { return [] }
        }()
        recentWorkouts = await workouts
        recentBody = await body
        recentSleep = await sleep
    }
}
