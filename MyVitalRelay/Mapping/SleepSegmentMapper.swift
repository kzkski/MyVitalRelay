import Foundation
import HealthKit

enum SleepSegmentMapper {
    /// asleep 系のみ同期対象。awake / inBed は nil を返す。
    static func record(from snapshot: SleepSegmentSnapshot, userId: UUID) -> SleepSegmentRecord? {
        guard let stage = stageString(for: snapshot.stage) else { return nil }
        let durationSec = Int(snapshot.endDate.timeIntervalSince(snapshot.startDate))
        guard durationSec > 0 else { return nil }

        return SleepSegmentRecord(
            userId: userId,
            startTime: WorkoutMapper.timestampString(snapshot.startDate),
            endTime: WorkoutMapper.timestampString(snapshot.endDate),
            stage: stage,
            durationSec: durationSec,
            healthkitUuid: snapshot.uuid,
            metadata: .init(
                sourceName: snapshot.sourceName,
                sourceBundleId: snapshot.sourceBundleId
            )
        )
    }

    static func stageString(for value: HKCategoryValueSleepAnalysis) -> String? {
        switch value {
        case .asleepCore: "core"
        case .asleepDeep: "deep"
        case .asleepREM: "rem"
        case .asleepUnspecified: "unspecified"
        case .awake, .inBed: nil
        @unknown default: nil
        }
    }
}
