import Foundation

// MARK: - Day plan (pure logic, tested by scripts/test-day-plan.sh)
//
// What the "Today" pill shows and when an item deserves its "in an hour" alert. The items
// come from the Mac's Calendar and Reminders (DayPlanner); nothing here touches EventKit.

struct DayItem: Equatable, Sendable {
    let id: String
    let title: String
    /// Start (event) or due time (reminder); nil for a reminder with no time.
    let start: Date?
    let allDay: Bool
    let isReminder: Bool
}

enum DayPlanLogic {
    static func time(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Items still ahead today (or under way less than 15 min ago), soonest first;
    /// all-day events and untimed reminders after them.
    static func remaining(_ items: [DayItem], now: Date) -> [DayItem] {
        let timed = items.filter { !$0.allDay && $0.start != nil && $0.start! > now.addingTimeInterval(-15 * 60) }
            .sorted { $0.start! < $1.start! }
        let untimed = items.filter { $0.allDay || $0.start == nil }
        return timed + untimed
    }

    static func label(_ item: DayItem) -> String {
        let mark = item.isReminder ? "☐ " : ""
        guard let start = item.start, !item.allDay else { return mark + item.title }
        return "\(time(start)) \(mark)\(item.title)"
    }

    /// Two ticker lines: the rest of the day above, the next item below (the ticker's
    /// "current" row). Empty when nothing is left.
    static func tickerLines(_ items: [DayItem], now: Date, nothingLeft: String, more: String) -> [String] {
        let left = remaining(items, now: now)
        guard let next = left.first else { return [nothingLeft] }
        let rest = left.dropFirst().prefix(3).map(label).joined(separator: " · ")
        let above = rest.isEmpty ? more.replacingOccurrences(of: "%@", with: "—") : more.replacingOccurrences(of: "%@", with: rest)
        return [above, label(next)]
    }

    /// Timed items whose start is within `lead` from now and not alerted yet.
    static func dueAlerts(_ items: [DayItem], now: Date, lead: TimeInterval, alerted: Set<String>) -> [DayItem] {
        items.filter { item in
            guard !item.allDay, let start = item.start, !alerted.contains(alertKey(item)) else { return false }
            let left = start.timeIntervalSince(now)
            return left > 0 && left <= lead
        }
    }

    static func alertKey(_ item: DayItem) -> String {
        "\(item.id)@\(item.start.map { Int($0.timeIntervalSince1970) } ?? 0)"
    }

    /// "через 58 мин" / "in 58 min".
    static func minutesLeft(_ start: Date, now: Date) -> Int {
        max(1, Int((start.timeIntervalSince(now) / 60).rounded()))
    }
}
