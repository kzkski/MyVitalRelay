import Foundation
import HealthKit

enum BodyCompositionMapper {
    /// Garmin Connect Mobile のプロファイル体重は HealthKit に新 UUID / 新 startDate で
    /// 再書き込みされる既知の汚染源。体組成リレーでは取り込まない（Issue #38）。
    /// ワークアウト同期の Garmin 判定とは独立。
    static let deniedSourceBundleIds: Set<String> = [
        "com.garmin.connect.mobile",
    ]

    static func shouldIngest(sourceBundleId: String) -> Bool {
        !deniedSourceBundleIds.contains(sourceBundleId)
    }

    static func record(from snapshot: BodyCompositionSnapshot, userId: UUID) -> BodyCompositionSampleRecord? {
        guard shouldIngest(sourceBundleId: snapshot.sourceBundleId) else { return nil }

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
