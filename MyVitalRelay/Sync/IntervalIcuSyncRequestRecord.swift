import Foundation
import os
import Supabase

private let intervalIcuSyncLogger = Logger(
    subsystem: "tv.civictech.MyVitalRelay",
    category: "IntervalIcuSync"
)

/// interval_icu_sync_request 行。体組成 upsert 成功後に INSERT される。
struct IntervalIcuSyncRequestRecord: Codable {
    var date: String
    var triggerSource: String

    enum CodingKeys: String, CodingKey {
        case date
        case triggerSource = "trigger_source"
    }

    static func healthKit(date: String) -> Self {
        Self(date: date, triggerSource: "healthkit")
    }

    /// weight / bodyFat のどちらかがある日付を distinct で返す。
    static func syncDates(from records: [BodyCompositionSampleRecord]) -> [String] {
        let dates = records.compactMap { record -> String? in
            guard record.weightKg != nil || record.bodyFatPct != nil else { return nil }
            return record.date
        }
        return Array(Set(dates)).sorted()
    }
}

enum IntervalIcuSyncRequestEnqueuer {
    static func enqueueIfNeeded(
        client: SupabaseClient,
        bodyRecords: [BodyCompositionSampleRecord]
    ) async {
        let dates = IntervalIcuSyncRequestRecord.syncDates(from: bodyRecords)
        guard !dates.isEmpty else { return }

        for date in dates {
            let request = IntervalIcuSyncRequestRecord.healthKit(date: date)
            do {
                try await client.from("interval_icu_sync_request")
                    .insert(request)
                    .execute()
                intervalIcuSyncLogger.info("Enqueued interval_icu_sync_request date=\(date)")
            } catch {
                if Self.isPendingDuplicateError(error) {
                    intervalIcuSyncLogger.debug(
                        "Interval.icu sync request already pending for \(date)"
                    )
                    continue
                }
                intervalIcuSyncLogger.error(
                    "Failed to enqueue interval_icu_sync_request: \(error.localizedDescription)"
                )
            }
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
