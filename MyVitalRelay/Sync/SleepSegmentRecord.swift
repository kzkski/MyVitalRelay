import Foundation

struct SleepSegmentRecord: Codable, Identifiable, Hashable {
    struct Metadata: Codable, Hashable {
        var sourceName: String
        var sourceBundleId: String

        enum CodingKeys: String, CodingKey {
            case sourceName = "source_name"
            case sourceBundleId = "source_bundle_id"
        }
    }

    var userId: UUID
    var startTime: String
    var endTime: String
    var stage: String
    var durationSec: Int
    var healthkitUuid: UUID
    var metadata: Metadata

    var id: UUID { healthkitUuid }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case startTime = "start_time"
        case endTime = "end_time"
        case stage
        case durationSec = "duration_sec"
        case healthkitUuid = "healthkit_uuid"
        case metadata
    }
}
