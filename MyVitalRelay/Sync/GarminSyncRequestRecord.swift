import Foundation
import os
import Supabase

private let garminSyncLogger = Logger(subsystem: "tv.civictech.MyVitalRelay", category: "GarminSync")

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

    static func healthKitActivities(dateFrom: String, dateTo: String) -> Self {
        Self(scope: "activities", dateFrom: dateFrom, dateTo: dateTo, triggerSource: "healthkit")
    }
}

enum GarminSyncRequestEnqueuer {
    /// Garmin 由来 training_log の upsert 成功後に FIT 取得キューを投入する。
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
            garminSyncLogger.info("Enqueued garmin_sync_request activities \(dateFrom)...\(dateTo)")
        } catch {
            if Self.isPendingDuplicateError(error) {
                garminSyncLogger.debug("Garmin sync request already pending for \(dateFrom)...\(dateTo)")
                return
            }
            garminSyncLogger.error("Failed to enqueue garmin_sync_request: \(error.localizedDescription)")
        }
    }

    /// 部分 UNIQUE（pending dedup）による重複 INSERT。
    private static func isPendingDuplicateError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("23505")
            || message.contains("duplicate")
            || message.contains("unique constraint")
    }
}
