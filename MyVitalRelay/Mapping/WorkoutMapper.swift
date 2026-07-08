import Foundation
import HealthKit

/// WorkoutSnapshot → training_log行への変換。全て純粋関数（単体テスト対象）。
enum WorkoutMapper {
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// training_log 論理キーのうち Mapper が決定する部分（user_id は同期時に付与）。
    struct LogicalKey: Equatable, Hashable {
        var startTime: String
        var endTime: String
        var workoutType: String
    }

    static func logicalKey(from snapshot: WorkoutSnapshot) -> LogicalKey {
        LogicalKey(
            startTime: timestampString(snapshot.startDate),
            endTime: timestampString(snapshot.endDate),
            workoutType: snapshot.activityType.displayName
        )
    }

    static func record(from snapshot: WorkoutSnapshot, userId: UUID, now: Date = .now) -> TrainingLogRecord {
        let durationMin = snapshot.durationSec / 60.0
        let distanceKm = snapshot.distanceMeters.map { $0 / 1000.0 }
        let avgSpeedKmh: Double? = {
            guard let km = distanceKm, durationMin > 0 else { return nil }
            return km / (durationMin / 60.0)
        }()

        return TrainingLogRecord(
            userId: userId,
            date: dateString(snapshot.startDate),
            dataSource: dataSource(sourceName: snapshot.sourceName, bundleId: snapshot.sourceBundleId),
            healthkitUuid: snapshot.uuid,
            discipline: discipline(for: snapshot.activityType),
            workoutType: snapshot.activityType.displayName,
            startTime: timestampString(snapshot.startDate),
            endTime: timestampString(snapshot.endDate),
            durationMin: durationMin,
            distanceKm: distanceKm,
            avgSpeedKmh: avgSpeedKmh,
            caloriesBurned: snapshot.activeEnergyKcal,
            avgHr: snapshot.avgHeartRate,
            maxHr: snapshot.maxHeartRate,
            elevationGainM: snapshot.elevationAscendedMeters,
            strokeCount: snapshot.strokeCount,
            metadata: .init(
                sourceName: snapshot.sourceName,
                sourceBundleId: snapshot.sourceBundleId,
                indoorWorkout: snapshot.isIndoorWorkout
            ),
            updatedAt: timestampString(now)
        )
    }

    /// indoor/outdoor判定は行わず、ソースアプリのみで判定する（引き継ぎ資料2.2節）。
    /// 判定不能なソースは'manual'に落とし、生値はmetadata側に残す（実機確認後に条件を追加修正する）。
    static func dataSource(sourceName: String, bundleId: String) -> String {
        let name = sourceName.lowercased()
        let bundle = bundleId.lowercased()
        if bundle.contains("garmin") || name.contains("garmin") {
            return "garmin"
        }
        if bundle.contains("lifefitness") || bundle.contains("lfconnect")
            || name.contains("life fitness") || name.contains("lf connect") {
            return "life_fitness"
        }
        return "manual"
    }

    /// walkingもrun扱い：エクササイズとして認識された距離は全て走行距離として扱う方針（引き継ぎ資料4.1節）。
    static func discipline(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running, .walking: "run"
        case .cycling: "bike"
        case .swimming: "swim"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "strength"
        default: "other"
        }
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tokyo
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func timestampString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
