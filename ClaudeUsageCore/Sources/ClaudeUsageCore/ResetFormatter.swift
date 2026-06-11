import Foundation

public enum ResetFormatter {
    /// "resets in 2h 14m" under 24h, otherwise "resets Tue 09:00" (local time).
    public static func string(for resetsAt: Date,
                              now: Date = Date(),
                              calendar: Calendar = .current) -> String {
        let interval = resetsAt.timeIntervalSince(now)
        if interval <= 0 { return "resets soon" }
        if interval < 24 * 3600 {
            let totalMinutes = max(1, Int((interval / 60).rounded(.up)))
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if hours > 0 { return "resets in \(hours)h \(minutes)m" }
            return "resets in \(minutes)m"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE HH:mm"
        return "resets " + formatter.string(from: resetsAt)
    }
}
