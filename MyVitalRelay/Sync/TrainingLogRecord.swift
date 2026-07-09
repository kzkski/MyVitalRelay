import Foundation

/// training_log行の書き込み用表現。
/// ここに含まない列（rpe / condition_notes / equipment等）はチャット運用で記入される領域のため、
    /// アップサート時にも上書きされない（PostgRESTはペイロードにある列だけを更新する）。
struct TrainingLogRecord: Codable, Identifiable, Hashable {
    struct Metadata: Codable, Hashable {
        var sourceName: String
        var sourceBundleId: String
        var indoorWorkout: Bool?
        var hrZoneSource: String?

        enum CodingKeys: String, CodingKey {
            case sourceName = "source_name"
            case sourceBundleId = "source_bundle_id"
            case indoorWorkout = "indoor_workout"
            case hrZoneSource = "hr_zone_source"
        }
    }

    var userId: UUID
    var date: String
    var dataSource: String
    var healthkitUuid: UUID
    var discipline: String
    var workoutType: String
    var startTime: String
    var endTime: String
    var durationMin: Double
    var distanceKm: Double?
    var avgSpeedKmh: Double?
    var caloriesBurned: Double?
    var avgHr: Double?
    var maxHr: Double?
    var hrZoneMinutes: HRZoneMinutes?
    var elevationGainM: Double?
    var strokeCount: Double?
    var metadata: Metadata
    var updatedAt: String

    var id: UUID { healthkitUuid }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case date
        case dataSource = "data_source"
        case healthkitUuid = "healthkit_uuid"
        case discipline
        case workoutType = "workout_type"
        case startTime = "start_time"
        case endTime = "end_time"
        case durationMin = "duration_min"
        case distanceKm = "distance_km"
        case avgSpeedKmh = "avg_speed_kmh"
        case caloriesBurned = "calories_burned"
        case avgHr = "avg_hr"
        case maxHr = "max_hr"
        case hrZoneMinutes = "hr_zone_minutes"
        case elevationGainM = "elevation_gain_m"
        case strokeCount = "stroke_count"
        case metadata
        case updatedAt = "updated_at"
    }
}
