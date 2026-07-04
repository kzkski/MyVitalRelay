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

struct SyncStatusView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SyncEngine.self) private var syncEngine
    @State private var recentRows: [RecentTrainingRow] = []

    var body: some View {
        NavigationStack {
            List {
                Section("同期状況") {
                    LabeledContent("最終同期", value: syncEngine.lastSyncAt.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "未実行")
                    LabeledContent("直近の同期件数", value: "\(syncEngine.lastSyncedCount)件")
                    if let error = syncEngine.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section("直近のトレーニング（training_log）") {
                    if recentRows.isEmpty {
                        Text("レコードなし").foregroundStyle(.secondary)
                    }
                    ForEach(recentRows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.date)  \(row.discipline)")
                            Text("\(row.dataSource) / \(row.distanceKm.map { String(format: "%.2f km", $0) } ?? "-") / \(row.durationMin.map { String(format: "%.0f 分", $0) } ?? "-")")
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

    private func loadRecent() async {
        do {
            recentRows = try await SupabaseClientProvider.shared
                .from("training_log")
                .select("id, date, discipline, data_source, distance_km, duration_min")
                .order("date", ascending: false)
                .order("start_time", ascending: false)
                .limit(20)
                .execute()
                .value
        } catch {
            // 一覧の取得失敗は同期自体の障害ではないため、直前の表示を維持する
        }
    }
}
