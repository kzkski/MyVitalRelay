import Foundation
import HealthKit

struct DailyActivityFetcher {
    let store: HKHealthStore

    private static let lookbackDays = 14

    /// JST 日次の累積カロリーを取得し、確定済み過去日のみ返す。
    func fetchFinalizedDays(now: Date = .now) async throws -> [DailyActivityDayTotal] {
        let endDate = JSTDateUtilities.startOfTodayJST(now: now)
        guard let startDate = JSTDateUtilities.jstCalendar.date(
            byAdding: .day,
            value: -Self.lookbackDays,
            to: endDate
        ) else {
            return []
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )

        async let activeTotals = fetchDailyTotals(
            type: HKQuantityType(.activeEnergyBurned),
            predicate: predicate,
            startDate: startDate,
            endDate: endDate
        )
        async let basalTotals = fetchDailyTotals(
            type: HKQuantityType(.basalEnergyBurned),
            predicate: predicate,
            startDate: startDate,
            endDate: endDate
        )

        let (active, basal) = try await (activeTotals, basalTotals)
        return merge(active: active, basal: basal, now: now)
    }

    private func fetchDailyTotals(
        type: HKQuantityType,
        predicate: NSPredicate,
        startDate: Date,
        endDate: Date
    ) async throws -> [Date: Double] {
        try await withCheckedThrowingContinuation { continuation in
            let anchorDate = Self.statisticsAnchorDate
            var interval = DateComponents()
            interval.day = 1
            interval.calendar = JSTDateUtilities.jstCalendar
            interval.timeZone = WorkoutMapper.tokyo

            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let results else {
                    continuation.resume(returning: [:])
                    return
                }

                var totals: [Date: Double] = [:]
                results.enumerateStatistics(from: startDate, to: endDate) { statistics, _ in
                    guard let quantity = statistics.sumQuantity() else { return }
                    let activityDay = JSTDateUtilities.startOfDayJST(statistics.startDate)
                    totals[activityDay] = quantity.doubleValue(for: .kilocalorie())
                }
                continuation.resume(returning: totals)
            }

            store.execute(query)
        }
    }

    private func merge(
        active: [Date: Double],
        basal: [Date: Double],
        now: Date
    ) -> [DailyActivityDayTotal] {
        let allDays = Set(active.keys).union(basal.keys)
        return allDays
            .filter { JSTDateUtilities.isFinalizedActivityDay($0, now: now) }
            .sorted()
            .map { day in
                DailyActivityDayTotal(
                    activityDay: day,
                    activeCaloriesKcal: active[day],
                    basalCaloriesKcal: basal[day]
                )
            }
    }

    /// バケット位相を固定するための anchor（JST 0:00）。
    /// HKStatisticsCollectionQuery のバケットは端末 TZ に依存しうるが、
    /// intervalComponents の calendar/timeZone を JST に固定し、個人利用（JST）前提で運用する。
    private static var statisticsAnchorDate: Date {
        var components = DateComponents()
        components.calendar = JSTDateUtilities.jstCalendar
        components.timeZone = WorkoutMapper.tokyo
        components.year = 2020
        components.month = 1
        components.day = 1
        return JSTDateUtilities.jstCalendar.date(from: components)!
    }
}
