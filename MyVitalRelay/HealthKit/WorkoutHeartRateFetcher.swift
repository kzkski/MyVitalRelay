import HealthKit

struct WorkoutHeartRateFetcher {
    let store: HKHealthStore

    func loadZoneBoundaries(referenceDate: Date = .now) -> HeartRateZoneBoundaries {
        if let dateOfBirth = try? store.dateOfBirthComponents(),
           let age = HeartRateZoneBoundariesCalculator.ageInYears(
               dateOfBirth: dateOfBirth,
               on: referenceDate
           ) {
            return HeartRateZoneBoundariesCalculator.fromAge(age)
        }
        return HeartRateZoneBoundariesCalculator.fixedDefault()
    }

    func fetchSamples(for workout: HKWorkout) async throws -> [HeartRateSamplePoint] {
        let timeRangeSamples = try await fetchSamples(matching: HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: []
        ))
        if !timeRangeSamples.isEmpty {
            return timeRangeSamples
        }

        return try await fetchSamples(matching: HKQuery.predicateForObjects(from: workout))
    }

    private func fetchSamples(matching predicate: NSPredicate) async throws -> [HeartRateSamplePoint] {
        try await withCheckedThrowingContinuation { continuation in
            let sortDescriptor = NSSortDescriptor(
                key: HKSampleSortIdentifierStartDate,
                ascending: true
            )
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let bpmUnit = HKUnit.count().unitDivided(by: .minute())
                let points = (samples ?? []).compactMap { sample -> HeartRateSamplePoint? in
                    guard let quantitySample = sample as? HKQuantitySample else { return nil }
                    let bpm = quantitySample.quantity.doubleValue(for: bpmUnit)
                    return HeartRateSamplePoint(
                        startDate: quantitySample.startDate,
                        endDate: quantitySample.endDate,
                        bpm: bpm
                    )
                }
                continuation.resume(returning: points)
            }
            store.execute(query)
        }
    }

    func enrich(
        workout: HKWorkout,
        statisticsAvg: Double?,
        statisticsMax: Double?,
        boundaries: HeartRateZoneBoundaries
    ) async throws -> HeartRateAggregation {
        let samples = try await fetchSamples(for: workout)
        return HeartRateZoneCalculator.aggregate(
            samples: samples,
            workoutStart: workout.startDate,
            workoutEnd: workout.endDate,
            boundaries: boundaries,
            statisticsAvg: statisticsAvg,
            statisticsMax: statisticsMax
        )
    }
}
