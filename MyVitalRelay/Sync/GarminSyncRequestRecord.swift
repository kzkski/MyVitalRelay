import Foundation

/// garmin_sync_request 行。HealthKit 検知 or Claude 会話から INSERT される。
struct GarminSyncRequestRecord: Codable {
    var scope: String
    var dateFrom: String
    var dateTo: String
    var triggerSource: String

    enum CodingKeys: String, CodingKey {
        case scope
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case triggerSource = "trigger_source"
    }

    /// MyVitalRelay が Garmin 由来ワークアウト同期後に発行。
    static func healthKitActivities(dateFrom: String, dateTo: String) -> Self {
        Self(scope: "activities", dateFrom: dateFrom, dateTo: dateTo, triggerSource: "healthkit")
    }
}

enum GarminSyncRequestEnqueuer {
    /// Garmin 由来 training_log の upsert 成功後に FIT 取得キューを投入する。
    /// 失敗してもワークアウト同期は成功扱いのまま（テーブル未作成・重複等）。
    static func enqueueActivitiesIfNeeded(
        client: SupabaseClient,
        garminRecords: [TrainingLogRecord]
    ) async {
        guard !garminRecords.isEmpty else { return }

        let dates = garminRecords.map(\.date).sorted()
        guard let dateFrom = dates.first, let dateTo = dates.last else { return }

        let request = GarminSyncRequestRecord.healthKitActivities(
            dateFrom: dateFrom,
            dateTo: dateTo
        )

        do {
            try await client.from("garmin_sync_request")
                .insert(request)
                .execute()
        } catch {
            // pending 重複（部分 UNIQUE）・マイグレーション未適用等は無視
        }
    }
}
