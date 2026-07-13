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

    /// 同期した Garmin レコード群からキュー用の日付範囲を決定する。
    static func activitiesDateRange(from records: [TrainingLogRecord]) -> Self? {
        guard let range = enqueueDateRange(from: records.map(\.date)) else { return nil }
        return healthKitActivities(dateFrom: range.lowerBound, dateTo: range.upperBound)
    }

    private static func enqueueDateRange(from dates: [String]) -> ClosedRange<String>? {
        let sorted = dates.sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        return first...last
    }
}

enum GarminSyncRequestEnqueuer {
    static func enqueueActivitiesIfNeeded(
        client: SupabaseClient,
        garminRecords: [TrainingLogRecord]
    ) async {
        guard let request = GarminSyncRequestRecord.activitiesDateRange(from: garminRecords) else {
            return
        }

        do {
            try await client.from("garmin_sync_request")
                .insert(request)
                .execute()
            garminSyncLogger.info(
                "Enqueued garmin_sync_request activities \(request.dateFrom)...\(request.dateTo)"
            )
        } catch {
            if Self.isPendingDuplicateError(error) {
                garminSyncLogger.debug(
                    "Garmin sync request already pending for \(request.dateFrom)...\(request.dateTo)"
                )
                return
            }
            garminSyncLogger.error("Failed to enqueue garmin_sync_request: \(error.localizedDescription)")
        }
    }

    /// 部分 UNIQUE（pending dedup）による重複 INSERT。
    static func isPendingDuplicateError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "PostgrestError", nsError.code == 23505 { return true }
        let message = error.localizedDescription.lowercased()
        return message.contains("23505")
            || message.contains("duplicate")
            || message.contains("unique constraint")
    }
}
