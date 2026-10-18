import Foundation

@main
struct DayPlanTests {
    static func main() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Minsk")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 13, minute: 0))!
        func at(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: h, minute: m))! }
        let items = [
            DayItem(id: "a", title: "Утро", start: at(9, 0), allDay: false, isReminder: false),
            DayItem(id: "b", title: "Созвон", start: at(13, 50), allDay: false, isReminder: false),
            DayItem(id: "c", title: "Купить шины", start: at(18, 0), allDay: false, isReminder: true),
            DayItem(id: "d", title: "День рождения", start: at(0, 0), allDay: true, isReminder: false),
        ]
        let left = DayPlanLogic.remaining(items, now: now)
        precondition(left.map(\.id) == ["b", "c", "d"], "remaining order \(left.map(\.id))")
        let alerts = DayPlanLogic.dueAlerts(items, now: now, lead: 3600, alerted: [])
        precondition(alerts.map(\.id) == ["b"], "only the 13:50 item is within an hour")
        let again = DayPlanLogic.dueAlerts(items, now: now, lead: 3600, alerted: [DayPlanLogic.alertKey(items[1])])
        precondition(again.isEmpty, "alerted once")
        precondition(DayPlanLogic.dueAlerts(items, now: at(14, 0), lead: 3600, alerted: []).isEmpty, "past start: no alert")
        precondition(DayPlanLogic.minutesLeft(at(13, 50), now: now) == 50, "minutes left")
        precondition(DayPlanLogic.label(items[2]).hasSuffix("☐ Купить шины"), "reminder label")
        let lines = DayPlanLogic.tickerLines(items, now: now, nothingLeft: "nothing", more: "Then: %@")
        precondition(lines.count == 2 && lines[1].contains("Созвон") && lines[0].contains("Купить шины"), "ticker \(lines)")
        precondition(DayPlanLogic.tickerLines([], now: now, nothingLeft: "nothing", more: "%@") == ["nothing"], "empty day")
        print("Day plan tests passed")
    }
}
