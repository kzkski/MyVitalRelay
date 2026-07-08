import Foundation

enum DailyActivityMapper {
    static func records(
        from days: [DailyActivityDayTotal],
        userId: UUID,
        now: Date = .now
    ) -> [DailyActivitySummaryRecord] {
        days.compactMap { record(from: $0, userId: userId, now: now) }
    }

    static func record(
        from day: DailyActivityDayTotal,
        userId: UUID,
        now: Date = .now
    ) -> DailyActivitySummaryRecord? {
        guard JSTDateUtilities.isFinalizedActivityDay(day.activityDay, now: now) else { return nil }
        guard day.activeCaloriesKcal != nil || day.basalCaloriesKcal != nil else { return nil }

        return DailyActivitySummaryRecord(
            userId: userId,
            date: JSTDateUtilities.storageDateString(forActivityDay: day.activityDay),
            activeCaloriesKcal: day.activeCaloriesKcal,
            basalCaloriesKcal: day.basalCaloriesKcal,
            syncedAt: WorkoutMapper.timestampString(now)
        )
    }
}
