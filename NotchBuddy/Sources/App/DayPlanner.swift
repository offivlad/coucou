#if !APPSTORE
import Foundation
import EventKit

// MARK: - DayPlanner
//
// The day from the Mac's Calendar and Reminders: a "Today" pill shows the next item and
// the rest of the day, and an hour before each timed item Mochi says so (card, sound,
// voice). Read only: Coucou never creates, changes or deletes an event or reminder.
// macOS asks once for access to Calendars and to Reminders.

@MainActor
final class DayPlanner {
    static let shared = DayPlanner()

    static let enabledKey = "dayPlanInNotch"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static let leadMinutesKey = "dayPlanLeadMinutes"
    static var lead: TimeInterval { Double(UserDefaults.standard.object(forKey: leadMinutesKey) as? Int ?? 60) * 60 }

    static let agentTag = "today"
    private let store = EKEventStore()
    private var timer: Timer?
    private var items: [DayItem] = []
    private var alerted: Set<String> = []
    private var eventsGranted = false
    private var remindersGranted = false

    func start() {
        guard Self.isEnabled, timer == nil else { return }
        Task {
            eventsGranted = (try? await store.requestFullAccessToEvents()) ?? false
            remindersGranted = (try? await store.requestFullAccessToReminders()) ?? false
            appendAppLog("nb.log", "[Day] calendars: \(eventsGranted), reminders: \(remindersGranted)")
            await reload()
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in await DayPlanner.shared.reload() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in DayPlanner.shared.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        HookServer.shared.dayPlanRemove()
    }

    /// Re-reads today (also at midnight: the next tick after the date changes).
    func reload() async {
        guard Self.isEnabled else { return }
        var list: [DayItem] = []
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        if eventsGranted {
            let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
            for e in store.events(matching: predicate) where e.status != .canceled {
                list.append(DayItem(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "",
                                    start: e.isAllDay ? nil : e.startDate, allDay: e.isAllDay, isReminder: false))
            }
        }
        if remindersGranted {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dayEnd, calendars: nil)
            let reminders: [DayItem] = await withCheckedContinuation { c in
                store.fetchReminders(matching: predicate) { found in
                    let items = (found ?? []).compactMap { r -> DayItem? in
                        guard let comps = r.dueDateComponents else { return nil }
                        let hasTime = comps.hour != nil
                        let due = Calendar.current.date(from: comps)
                        return DayItem(id: r.calendarItemIdentifier, title: r.title ?? "",
                                       start: hasTime ? due : nil, allDay: !hasTime, isReminder: true)
                    }
                    c.resume(returning: items)
                }
            }
            list += reminders
        }
        items = list.filter { !$0.title.isEmpty }
        loadedDay = dayStart
        tick()
    }

    private var loadedDay: Date?

    func tick() {
        guard Self.isEnabled else { return }
        let now = Date()
        if let day = loadedDay, !Calendar.current.isDate(day, inSameDayAs: now) {
            alerted.removeAll()
            Task { await reload() }
            return
        }
        let lines = DayPlanLogic.tickerLines(items, now: now,
                                             nothingLeft: String(localized: "Nothing else today"),
                                             more: String(localized: "Then: %@"))
        HookServer.shared.dayPlanShow(lines: lines)
        for item in DayPlanLogic.dueAlerts(items, now: now, lead: Self.lead, alerted: alerted) {
            alerted.insert(DayPlanLogic.alertKey(item))
            guard let start = item.start else { continue }
            let minutes = DayPlanLogic.minutesLeft(start, now: now)
            let line = String(localized: "In \(minutes) min: \(item.title) · \(DayPlanLogic.time(start))")
            appendAppLog("nb.log", "[Day] alert, \(minutes) min ahead")
            HookServer.shared.dayPlanAlert(line: line)
            let ru = line.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil
            VoiceSpeaker.shared.enqueue(String(localized: "In \(minutes) minutes: \(item.title)"),
                                        locale: Locale(identifier: ru ? "ru-RU" : "en-GB"))
        }
    }
}
#endif
