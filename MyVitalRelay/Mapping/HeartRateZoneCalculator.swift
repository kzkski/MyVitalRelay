import Foundation

struct HeartRateAggregation: Equatable {
    var zoneMinutes: HRZoneMinutes?
    var zoneSource: HeartRateZoneBoundaries.Source?
}

enum HeartRateZoneCalculator {
    static func zoneIndex(bpm: Double, thresholds: [Double]) -> Int {
        for (index, threshold) in thresholds.enumerated() where bpm < threshold {
            return index + 1
        }
        return thresholds.count + 1
    }

    static func aggregate(
        samples: [HeartRateSamplePoint],
        workoutStart: Date,
        workoutEnd: Date,
        boundaries: HeartRateZoneBoundaries
    ) -> HeartRateAggregation {
        guard !samples.isEmpty else {
            return HeartRateAggregation(zoneMinutes: nil, zoneSource: nil)
        }

        let segments = segmentDurations(
            samples: samples,
            workoutStart: workoutStart,
            workoutEnd: workoutEnd
        )
        guard !segments.isEmpty else {
            return HeartRateAggregation(zoneMinutes: nil, zoneSource: nil)
        }

        var zoneSeconds: [Int: Double] = [:]

        for segment in segments {
            let zone = zoneIndex(bpm: segment.bpm, thresholds: boundaries.thresholdsBpm)
            zoneSeconds[zone, default: 0] += segment.durationSec
        }

        return HeartRateAggregation(
            zoneMinutes: formatZoneMinutes(zoneSeconds),
            zoneSource: boundaries.source
        )
    }

    private struct SegmentDuration {
        var bpm: Double
        var durationSec: Double
    }

    private static func segmentDurations(
        samples: [HeartRateSamplePoint],
        workoutStart: Date,
        workoutEnd: Date
    ) -> [SegmentDuration] {
        var segments: [SegmentDuration] = []

        for index in samples.indices {
            let sample = samples[index]
            let segmentStart = max(sample.startDate, workoutStart)
            let nextStart = index + 1 < samples.count ? samples[index + 1].startDate : workoutEnd
            let segmentEnd = min(max(sample.endDate, nextStart), workoutEnd)

            guard segmentEnd > segmentStart else { continue }

            segments.append(SegmentDuration(
                bpm: sample.bpm,
                durationSec: segmentEnd.timeIntervalSince(segmentStart)
            ))
        }

        return segments
    }

    private static func formatZoneMinutes(_ zoneSeconds: [Int: Double]) -> HRZoneMinutes {
        Dictionary(uniqueKeysWithValues: (1...5).map { zone in
            let minutes = (zoneSeconds[zone, default: 0] / 60.0 * 10).rounded() / 10
            return ("zone\(zone)", minutes)
        })
    }
}
