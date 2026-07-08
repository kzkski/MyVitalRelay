import Foundation

/// daily_activity_summary 行の書き込み用表現。
/// `notes` は Claude が会話で記入する列のため、ペイロードに含めない（上書き防止）。
struct DailyActivitySummaryRecord: Codable, Hashable {
    var userId: UUID
    var date: String
    var activeCaloriesKcal: Double?
    var basalCaloriesKcal: Double?
    var syncedAt: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case date
        case activeCaloriesKcal = "active_calories_kcal"
        case basalCaloriesKcal = "basal_calories_kcal"
        case syncedAt = "synced_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        try container.encode(date, forKey: .date)
        // nil はキーを省略せず JSON null として出力（PostgREST バルク upsert の列整合 + 明示上書き）
        try container.encode(activeCaloriesKcal, forKey: .activeCaloriesKcal)
        try container.encode(basalCaloriesKcal, forKey: .basalCaloriesKcal)
        try container.encode(syncedAt, forKey: .syncedAt)
    }
}
