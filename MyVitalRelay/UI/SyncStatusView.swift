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

struct RecentActivityRow: Decodable, Identifiable {
    let id: UUID
    let date: String
    let activeCaloriesKcal: Double?
    let basalCaloriesKcal: Double?

    enum CodingKeys: String, CodingKey {
        case id, date
        case activeCaloriesKcal = "active_calories_kcal"
        case basalCaloriesKcal = "basal_calories_kcal"
    }
}

struct SyncStatusView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SyncEngine.self) private var syncEngine
    @State private var recentWorkouts: [RecentTrainingRow] = []
    @State private var recentBody: [RecentBodyCompositionRow] = []
    @State private var recentSleep: [RecentSleepRow] = []
    @State private var recentActivity: [RecentActivityRow] = []

    var body: some View {
        NavigationStack {
            List {
                statusSection
                workoutSection
                bodySection
                sleepSection
                activitySection
            }
            .navigationTitle("MyVitalRelay")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await auth.signOut() }
                    } label: {
                        Label("サインアウト", systemImage: "rectangle.portrait.and.arrow.right")
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
                            Label("今すぐ同期", systemImage: "arrow.triangle.2.circlepath")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .disabled(syncEngine.isSyncing)
                }
            }
            .task { await loadRecent() }
            .refreshable {
                await syncEngine.sync()
                await loadRecent()
            }
        }
    }

    // MARK: - 同期状況

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                statusBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(lastSyncText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            HStack(spacing: 10) {
                statChip(icon: "figure.run", tint: .orange,
                         label: "ワークアウト", count: syncEngine.lastSyncedWorkoutCount)
                statChip(icon: "scalemass.fill", tint: .purple,
                         label: "体組成", count: syncEngine.lastSyncedBodyCount)
                sleepStatChip
                statChip(icon: "flame.fill", tint: .red,
                         label: "活動量", count: syncEngine.lastSyncedDailyActivityCount)
            }
            .padding(.vertical, 4)

            if let error = syncEngine.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("同期状況")
        } footer: {
            Text("下に引っ張ると再同期します")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.15))
                .frame(width: 44, height: 44)
            if syncEngine.isSyncing {
                ProgressView()
            } else {
                Image(systemName: statusSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
        }
    }

    private var statusTitle: String {
        if syncEngine.isSyncing { return "同期中…" }
        if syncEngine.lastError != nil { return "同期エラー" }
        return syncEngine.lastSyncAt == nil ? "未同期" : "同期済み"
    }

    private var statusSymbol: String {
        if syncEngine.lastError != nil { return "exclamationmark.icloud.fill" }
        return syncEngine.lastSyncAt == nil ? "icloud.slash.fill" : "checkmark.icloud.fill"
    }

    private var statusColor: Color {
        if syncEngine.isSyncing { return .accentColor }
        if syncEngine.lastError != nil { return .red }
        return syncEngine.lastSyncAt == nil ? .secondary : .green
    }

    private var lastSyncText: String {
        guard let at = syncEngine.lastSyncAt else { return "最終同期: 未実行" }
        return "最終同期: \(at.formatted(date: .abbreviated, time: .shortened))"
    }

    private var sleepStatChip: some View {
        VStack(spacing: 4) {
            Image(systemName: "bed.double.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.indigo)
            if syncEngine.lastSyncedSleepDeletedCount > 0 {
                Text("+\(syncEngine.lastSyncedSleepCount) −\(syncEngine.lastSyncedSleepDeletedCount)")
                    .font(.headline.monospacedDigit())
            } else {
                Text("\(syncEngine.lastSyncedSleepCount)")
                    .font(.headline.monospacedDigit())
            }
            Text("睡眠")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.indigo.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statChip(icon: String, tint: Color, label: String, count: Int) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text("\(count)")
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 直近レコード

    private var workoutSection: some View {
        Section {
            recentList(recentWorkouts, empty: "レコードなし") { row in
                recordRow(icon: disciplineSymbol(row.discipline), tint: .orange) {
                    Text("\(row.date)  \(disciplineLabel(row.discipline))")
                } detail: {
                    Text("\(row.dataSource) / \(row.distanceKm.map { String(format: "%.2f km", $0) } ?? "-") / \(row.durationMin.map { String(format: "%.0f 分", $0) } ?? "-")")
                }
            }
        } header: {
            Label("直近のトレーニング", systemImage: "figure.run")
        }
    }

    private var bodySection: some View {
        Section {
            recentList(recentBody, empty: "レコードなし") { row in
                recordRow(icon: "scalemass.fill", tint: .purple) {
                    Text(bodySummary(row))
                } detail: {
                    Text(formatTimestamp(row.measuredAt))
                }
            }
        } header: {
            Label("直近の体組成", systemImage: "scalemass.fill")
        }
    }

    private var sleepSection: some View {
        Section {
            recentList(recentSleep, empty: "レコードなし") { row in
                recordRow(icon: "bed.double.fill", tint: .indigo) {
                    Text("\(stageLabel(row.stage))  \(sleepDuration(row.durationSec))")
                } detail: {
                    Text(formatTimestamp(row.startTime))
                }
            }
        } header: {
            Label("直近の睡眠", systemImage: "bed.double.fill")
        }
    }

    private var activitySection: some View {
        Section {
            recentList(recentActivity, empty: "レコードなし") { row in
                recordRow(icon: "flame.fill", tint: .red) {
                    Text(activitySummary(row))
                } detail: {
                    Text("記録日 \(row.date)")
                }
            }
        } header: {
            Label("直近の活動量", systemImage: "flame.fill")
        } footer: {
            Text("日付は活動日の翌日（前日オフセット）で格納されています")
        }
    }

    private func recordRow(
        icon: String,
        tint: Color,
        @ViewBuilder title: () -> Text,
        @ViewBuilder detail: () -> Text
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                title()
                    .font(.subheadline)
                detail()
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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

    // MARK: - 表示用フォーマット

    private func disciplineSymbol(_ discipline: String) -> String {
        switch discipline {
        case "run": "figure.run"
        case "bike": "bicycle"
        case "swim": "figure.pool.swim"
        case "strength": "dumbbell.fill"
        default: "figure.mixed.cardio"
        }
    }

    private func disciplineLabel(_ discipline: String) -> String {
        switch discipline {
        case "run": "ラン"
        case "bike": "バイク"
        case "swim": "スイム"
        case "strength": "筋トレ"
        default: "その他"
        }
    }

    private func stageLabel(_ stage: String) -> String {
        switch stage {
        case "core": "コア睡眠"
        case "deep": "深い睡眠"
        case "rem": "レム睡眠"
        default: "睡眠"
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
        return hours > 0 ? "\(hours)時間\(minutes)分" : "\(minutes)分"
    }

    private func activitySummary(_ row: RecentActivityRow) -> String {
        let parts = [
            row.activeCaloriesKcal.map { String(format: "アクティブ %.0f kcal", $0) },
            row.basalCaloriesKcal.map { String(format: "基礎 %.0f kcal", $0) },
        ].compactMap { $0 }
        return parts.isEmpty ? "-" : parts.joined(separator: " / ")
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    /// DBのISO8601文字列をそのまま出さず、端末ロケールの短い表記にする（パース不能なら原文のまま）。
    private func formatTimestamp(_ value: String) -> String {
        let date = Self.isoWithFraction.date(from: value) ?? Self.iso.date(from: value)
        guard let date else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
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
        async let activity: [RecentActivityRow] = {
            do {
                return try await client.from("daily_activity_summary")
                    .select("id, date, active_calories_kcal, basal_calories_kcal")
                    .order("date", ascending: false)
                    .limit(10)
                    .execute()
                    .value
            } catch { return [] }
        }()
        recentWorkouts = await workouts
        recentBody = await body
        recentSleep = await sleep
        recentActivity = await activity
    }
}
