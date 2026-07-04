import HealthKit

/// HKQuantitySample から必要値だけを抜き出した純粋データ（単体テスト用）。
struct BodyCompositionSnapshot {
    var uuid: UUID
    var sampleType: HKQuantityTypeIdentifier
    var measuredAt: Date
    var value: Double
    var sourceName: String
    var sourceBundleId: String
}

extension BodyCompositionSnapshot {
    init(sample: HKQuantitySample) {
        let value: Double = {
            switch sample.quantityType.identifier {
            case HKQuantityTypeIdentifier.bodyMass.rawValue:
                return sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
            case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:
                // HealthKit は 0〜1 の小数で保持するため % 換算する
                return sample.quantity.doubleValue(for: .percent()) * 100.0
            default:
                return sample.quantity.doubleValue(for: .count())
            }
        }()
        self.init(
            uuid: sample.uuid,
            sampleType: HKQuantityTypeIdentifier(rawValue: sample.quantityType.identifier),
            measuredAt: sample.startDate,
            value: value,
            sourceName: sample.sourceRevision.source.name,
            sourceBundleId: sample.sourceRevision.source.bundleIdentifier
        )
    }
}
