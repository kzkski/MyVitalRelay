import Foundation

/// JST カレンダー日のユーティリティ。`WorkoutMapper` と TZ 定義を共有する。
enum JSTDateUtilities {
    static var jstCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WorkoutMapper.tokyo
        return calendar
    }

    static func startOfDayJST(_ date: Date) -> Date {
        jstCalendar.startOfDay(for: date)
    }

    static func dayStringJST(_ date: Date) -> String {
        WorkoutMapper.dateString(date)
    }

    /// 活動日 D（JST カレンダー日）→ 格納日 D+1。`sleep_hours` / `daily_log` の日次帰属規約に合わせる。
    static func storageDateString(forActivityDay activityDay: Date) -> String {
        let nextDay = jstCalendar.date(byAdding: .day, value: 1, to: startOfDayJST(activityDay))!
        return dayStringJST(nextDay)
    }

    static func startOfTodayJST(now: Date = .now) -> Date {
        startOfDayJST(now)
    }

    /// 活動日が完全に終了した過去日か（当日 JST は未確定のため除外）。
    static func isFinalizedActivityDay(_ activityDay: Date, now: Date = .now) -> Bool {
        startOfDayJST(activityDay) < startOfTodayJST(now: now)
    }
}
