import Foundation
import HealthKit

enum BodyCompositionAnchorStore {
    private static let bodyMassKey = "bodyMassQueryAnchor"
    private static let bodyFatKey = "bodyFatQueryAnchor"

    static func loadBodyMass() -> HKQueryAnchor? { load(key: bodyMassKey) }
    static func loadBodyFat() -> HKQueryAnchor? { load(key: bodyFatKey) }

    static func saveBodyMass(_ anchor: HKQueryAnchor) { save(anchor, key: bodyMassKey) }
    static func saveBodyFat(_ anchor: HKQueryAnchor) { save(anchor, key: bodyFatKey) }

    private static func load(key: String) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private static func save(_ anchor: HKQueryAnchor, key: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
