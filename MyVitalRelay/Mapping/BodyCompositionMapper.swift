import Foundation
import HealthKit

enum BodyCompositionMapper {
    static func record(from snapshot: BodyCompositionSnapshot, userId: UUID) -> BodyCompositionSampleRecord {
        let (weightKg, bodyFatPct): (Double?, Double?) = {
            switch snapshot.sampleType {
            case .bodyMass:
                return (snapshot.value, nil)
            case .bodyFatPercentage:
                return (nil, snapshot.value)
            default:
                return (nil, nil)
            }
        }()

        return BodyCompositionSampleRecord(
            userId: userId,
            measuredAt: WorkoutMapper.timestampString(snapshot.measuredAt),
            date: WorkoutMapper.dateString(snapshot.measuredAt),
            weightKg: weightKg,
            bodyFatPct: bodyFatPct,
            healthkitUuid: snapshot.uuid,
            sourceName: snapshot.sourceName,
            sourceBundleId: snapshot.sourceBundleId,
            metadata: .init(
                sampleType: snapshot.sampleType.rawValue,
                sourceName: snapshot.sourceName,
                sourceBundleId: snapshot.sourceBundleId
            )
        )
    }
}
