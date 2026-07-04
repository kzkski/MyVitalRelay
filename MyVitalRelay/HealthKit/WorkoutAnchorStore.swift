import Foundation
import HealthKit

/// HKAnchoredObjectQueryのアンカーを永続化する。
/// アンカーはSupabaseへの書き込みが全件成功したときにのみ保存する（SyncEngine参照）。
enum WorkoutAnchorStore {
    private static let key = "workoutQueryAnchor"

    static func load() -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    static func save(_ anchor: HKQueryAnchor) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
