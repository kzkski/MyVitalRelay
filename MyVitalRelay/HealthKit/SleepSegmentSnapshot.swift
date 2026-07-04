import HealthKit

struct SleepSegmentSnapshot {
    var uuid: UUID
    var startDate: Date
    var endDate: Date
    var stage: HKCategoryValueSleepAnalysis
    var sourceName: String
    var sourceBundleId: String
}

extension SleepSegmentSnapshot {
    init(sample: HKCategorySample) {
        let stage = HKCategoryValueSleepAnalysis(rawValue: sample.value) ?? .asleepUnspecified
        self.init(
            uuid: sample.uuid,
            startDate: sample.startDate,
            endDate: sample.endDate,
            stage: stage,
            sourceName: sample.sourceRevision.source.name,
            sourceBundleId: sample.sourceRevision.source.bundleIdentifier
        )
    }
}
