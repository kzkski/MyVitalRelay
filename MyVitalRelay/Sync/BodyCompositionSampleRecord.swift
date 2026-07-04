import Foundation

struct BodyCompositionSampleRecord: Codable, Identifiable, Hashable {
    struct Metadata: Codable, Hashable {
        var sampleType: String
        var sourceName: String
        var sourceBundleId: String

        enum CodingKeys: String, CodingKey {
            case sampleType = "sample_type"
            case sourceName = "source_name"
            case sourceBundleId = "source_bundle_id"
        }
    }

    var userId: UUID
    var measuredAt: String
    var date: String
    var weightKg: Double?
    var bodyFatPct: Double?
    var healthkitUuid: UUID
    var sourceName: String
    var sourceBundleId: String
    var metadata: Metadata

    var id: UUID { healthkitUuid }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case measuredAt = "measured_at"
        case date
        case weightKg = "weight_kg"
        case bodyFatPct = "body_fat_pct"
        case healthkitUuid = "healthkit_uuid"
        case sourceName = "source_name"
        case sourceBundleId = "source_bundle_id"
        case metadata
    }
}
