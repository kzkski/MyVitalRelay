import Foundation

struct HeartRateZoneBoundaries: Equatable {
    enum Source: String, Codable {
        case ageBased = "age_based"
        case fixedDefault = "fixed_default"
    }

    var source: Source
    /// zone1上端, zone2上端, zone3上端, zone4上端（BPM）
    var thresholdsBpm: [Double]
}

enum HeartRateZoneBoundariesCalculator {
    private static let zoneRatios = [0.60, 0.70, 0.80, 0.90]
    private static let fixedDefaultAge = 35

    static func fromAge(_ age: Int) -> HeartRateZoneBoundaries {
        let maxHr = 220.0 - Double(age)
        let thresholds = zoneRatios.map { (($0 * maxHr) * 10).rounded() / 10 }
        return HeartRateZoneBoundaries(source: .ageBased, thresholdsBpm: thresholds)
    }

    static func fixedDefault() -> HeartRateZoneBoundaries {
        var boundaries = fromAge(fixedDefaultAge)
        boundaries.source = .fixedDefault
        return boundaries
    }

    static func ageInYears(
        dateOfBirth: DateComponents,
        on referenceDate: Date,
        calendar: Calendar = .current
    ) -> Int? {
        guard let birthDate = calendar.date(from: dateOfBirth) else { return nil }
        let components = calendar.dateComponents([.year], from: birthDate, to: referenceDate)
        guard let years = components.year, years >= 0 else { return nil }
        return years
    }
}
