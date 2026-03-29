import Foundation

/// UTC calendar day strings for global daily parity (puzzle, streak, persistence keys).
enum DailyCalendar {
    private static var posixUTC: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static let ymdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = posixUTC
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let ymdCompactFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = posixUTC
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    /// `yyyy-MM-dd` in UTC (e.g. for UserDefaults keys and streaks).
    static func utcYMDString(from date: Date = Date()) -> String {
        ymdFormatter.string(from: date)
    }

    /// `yyyyMMdd` as integer for hashing / seeds.
    static func utcYMDInt(from date: Date = Date()) -> Int {
        Int(ymdCompactFormatter.string(from: date)) ?? 0
    }

    /// Previous UTC calendar date as `yyyy-MM-dd`.
    static func utcYMDStringYesterday(from date: Date = Date()) -> String? {
        guard let y = posixUTC.date(byAdding: .day, value: -1, to: date) else { return nil }
        return ymdFormatter.string(from: y)
    }
}
