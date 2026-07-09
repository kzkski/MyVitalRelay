import Foundation

struct HeartRateSamplePoint: Equatable {
    var startDate: Date
    var endDate: Date
    var bpm: Double
}

typealias HRZoneMinutes = [String: Double]

enum HRZoneKey {
    static let all = ["zone1", "zone2", "zone3", "zone4", "zone5"]
}
