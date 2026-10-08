#if !APPSTORE
import AppKit
import ApplicationServices

// MARK: - Chat app watcher (Claude Desktop, ChatGPT Desktop)
//
// The chats of the Claude and ChatGPT desktop apps have no hooks. When turned on in
// Settings → Agents, Coucou reads their windows through the Accessibility API: a stop
// button means an answer is being written, a tool prompt (Claude's "Allow once") means
// the app waits for you. Mochi thinks on the app's pill meanwhile and says when the
// answer is ready. Nothing is clicked, typed or sent, and nothing leaves the Mac: only
// button labels and the window title are read.
//
// Cost: the timer runs only while the option is on, Accessibility is granted and one of
// the apps is open. Each tick re-reads the message box found on the first scan (a few
// dozen elements); the whole window is walked only to find that box again, or every few
// seconds while Claude answers, to catch a tool prompt.

/// Walks the apps' accessibility trees on a background queue.
/// Every property is touched on `queue` only.
private final class ChatAppScanner: @unchecked Sendable {
    struct Result: Sendable {
        let signal: ChatAppSignal
        let title: String?
    }

    let queue = DispatchQueue(label: "fr.louisraille.coucou.chat-apps", qos: .utility)

    /// The element around the message box, per process.
    private var boxes: [pid_t: AXUIElement] = [:]
    private var lastFullScan: [pid_t: Date] = [:]
    /// Whole-window walks in a row that found no message box: each one doubles the wait.
    private var boxMisses: [pid_t: Int] = [:]
    private var accessibilityAsked: Set<pid_t> = []

    private static let fullScanBudget = 4_000
    private static let boxScanBudget  = 400
    private static let maxDepth       = 64
    /// Wall-clock cap of one walk: an app that answers slowly must not hold the queue.
    private static let walkDeadline: TimeInterval = 1.0
    /// Without a known message box, walk the whole window at most this often, backing off
    /// up to a minute while the box stays out of sight (no window, a settings page…).
    private static let fullScanInterval: TimeInterval = 5
    private static let maxFullScanInterval: TimeInterval = 60
    /// Roles whose subtree never holds a button worth reading.
    private static let skippedRoles: Set<String> = [
        "AXStaticText", "AXImage", "AXScrollBar", "AXMenuBar", "AXMenu", "AXTextArea",
        "AXTextField", "AXHeading", "AXLink", "AXList", "AXTable", "AXOutline",
    ]
    private static let buttonRoles: Set<String> = ["AXButton", "AXMenuButton"]

    func forget(pid: pid_t) {
        boxes[pid] = nil
        lastFullScan[pid] = nil
        boxMisses[pid] = nil
        accessibilityAsked.remove(pid)
    }

    /// One look at the app. `wantsFullScan` also walks the whole window when the message
    /// box is known, to see prompts that open elsewhere.
    func scan(pid: pid_t, app: ChatApp, wantsFullScan: Bool) -> Result {
        let root = AXUIElementCreateApplication(pid)
        // A hung app must not hold the queue: give up on any call after half a second.
        AXUIElementSetMessagingTimeout(root, 0.5)
        if app.isElectron, !accessibilityAsked.contains(pid) {
            // Chromium builds its tree only for assistive apps that ask for it.
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            accessibilityAsked.insert(pid)
        }
        let title = windowTitle(root)

        var kinds: [ChatButtonKind] = []
        var complete = false
        var boxFound = false

        if let box = boxes[pid] {
            let walk = walk(from: [box], budget: Self.boxScanBudget)
            if walk.kinds.contains(where: { $0 == .stop || $0 == .send || $0 == .composer }) {
                kinds = walk.kinds
                complete = walk.complete
                boxFound = true
            } else {
                boxes[pid] = nil   // the box moved (new window, new chat): find it again
            }
        }

        let now = Date()
        let misses = boxMisses[pid] ?? 0
        let interval = min(Self.fullScanInterval * pow(2, Double(min(misses, 4))), Self.maxFullScanInterval)
        let fullDue = (lastFullScan[pid].map { now.timeIntervalSince($0) >= interval } ?? true)
        if (!boxFound && fullDue) || (boxFound && wantsFullScan) {
            lastFullScan[pid] = now
            let windows = elements(root, kAXWindowsAttribute)
            if windows.isEmpty {
                boxMisses[pid] = misses + 1
            } else {
                let walk = walk(from: windows, budget: Self.fullScanBudget)
                if let box = walk.box {
                    boxes[pid] = box
                    boxMisses[pid] = 0
                } else if !boxFound {
                    boxMisses[pid] = misses + 1
                }
                if boxFound {
                    // The box already answered for the stop button; keep only what is new.
                    kinds += walk.kinds.filter { $0 != .stop && $0 != .send && $0 != .composer }
                } else {
                    kinds = walk.kinds
                    complete = walk.complete
                }
            }
        }

        let signal = ChatAppWatcherLogic.signal(for: kinds, complete: complete, app: app)
        return Result(signal: signal, title: ChatAppWatcherLogic.conversationTitle(title, app: app))
    }

    // MARK: - Tree walk

    private struct Walk {
        var kinds: [ChatButtonKind] = []
        /// Grandparent of the first message box button met: holds the stop / send spot.
        var box: AXUIElement? = nil
        /// The walk ran out of elements before running out of budget.
        var complete = false
    }

    private struct Visit {
        let element: AXUIElement
        let parent: AXUIElement?
        let grandparent: AXUIElement?
        let depth: Int
    }

    /// Depth-first, last child first: both apps put the message box and their dialogs at
    /// the end of the window, after the conversation, so they come up early.
    private func walk(from roots: [AXUIElement], budget: Int) -> Walk {
        var result = Walk()
        var stack = roots.map { Visit(element: $0, parent: nil, grandparent: nil, depth: 0) }
        var visited = 0
        let deadline = Date().addingTimeInterval(Self.walkDeadline)
        let attributes = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute,
                          kAXHelpAttribute, kAXChildrenAttribute] as CFArray

        while let visit = stack.popLast() {
            visited += 1
            if visited > budget || Date() > deadline { return result }

            // Local setting, no round trip: a hung app answers no call in more than 0.5 s.
            AXUIElementSetMessagingTimeout(visit.element, 0.5)
            var valuesRef: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(visit.element, attributes,
                                                         AXCopyMultipleAttributeOptions(rawValue: 0),
                                                         &valuesRef) == .success,
                  let values = valuesRef as? [AnyObject], values.count == 5 else { continue }

            let role = values[0] as? String ?? ""
            if Self.buttonRoles.contains(role) {
                for case let label as String in [values[1], values[2], values[3]] {
                    guard let kind = ChatAppWatcherLogic.classify(label) else { continue }
                    result.kinds.append(kind)
                    if result.box == nil, kind == .stop || kind == .send || kind == .composer {
                        result.box = visit.grandparent ?? visit.parent
                    }
                    break
                }
                continue   // a button's children are its icon and its text
            }
            if Self.skippedRoles.contains(role) || visit.depth >= Self.maxDepth { continue }

            for child in Self.axElements(values[4]) {
                stack.append(Visit(element: child, parent: visit.element,
                                   grandparent: visit.parent, depth: visit.depth + 1))
            }
        }
        result.complete = true
        return result
    }

    // MARK: - AX helpers

    private func windowTitle(_ root: AXUIElement) -> String? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &windowRef) == .success
               || AXUIElementCopyAttributeValue(root, kAXMainWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(windowRef, to: AXUIElement.self)
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success else { return nil }
        return titleRef as? String
    }

    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return [] }
        return Self.axElements(ref)
    }

    private static func axElements(_ value: AnyObject?) -> [AXUIElement] {
        guard let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeBitCast(item, to: AXUIElement.self) : nil
        }
    }
}

// MARK: - Watcher

@MainActor
final class ChatAppWatcher {
    static let shared = ChatAppWatcher()

    /// UserDefaults key of the Settings toggle (off by default).
    static let enabledKey = "chatAppsWatchEnabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static let tickInterval: TimeInterval = 1.5
    /// While Claude answers, walk the whole window every this many ticks to catch a tool prompt.
    private static let approvalScanEvery = 4

    private let scanner = ChatAppScanner()
    private var trackers: [ChatApp: ChatAppTracker] = [:]
    private var pids: [ChatApp: pid_t] = [:]
    private var titles: [ChatApp: String] = [:]
    private var timer: Timer?
    private var tick = 0
    private var scanning = false
    private var observers: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    /// Called once at launch. Cheap when the option is off: no timer, only app launch observers.
    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] notif in
                let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard let bundleId, ChatApp(bundleId: bundleId) != nil else { return }
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        // Posted when any app's Accessibility permission changes.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The new trust value lands a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { self?.evaluate() }
            }
        })
        evaluate()
    }

    /// The Settings toggle. Turning it on asks macOS for Accessibility when it is missing.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on, !Self.isTrusted {
            // kAXTrustedCheckOptionPrompt, spelled out: the global is not concurrency-safe in Swift 6.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        evaluate()
    }

    /// Starts or stops the timer from the toggle, the permission and the running apps.
    func evaluate() {
        var running: [ChatApp: pid_t] = [:]
        for app in ChatApp.allCases {
            if let hit = NSWorkspace.shared.runningApplications.first(where: {
                guard let id = $0.bundleIdentifier else { return false }
                return app.bundleIds.contains(id) && !$0.isTerminated
            }) {
                running[app] = hit.processIdentifier
            }
        }
        let active = Self.isEnabled && Self.isTrusted
        for app in ChatApp.allCases where pids[app] != nil && (!active || running[app] != pids[app]) {
            stopWatching(app)
        }
        guard active else { stopTimer(); return }
        for (app, pid) in running where pids[app] == nil { pids[app] = pid }
        if pids.isEmpty { stopTimer() } else { startTimer() }
    }

    // MARK: - Timer

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// The app quit or watching stopped: drop its answer in progress.
    private func stopWatching(_ app: ChatApp) {
        if let pid = pids[app] {
            let scanner = self.scanner
            scanner.queue.async { scanner.forget(pid: pid) }
        }
        pids[app] = nil
        titles[app] = nil
        if trackers[app]?.isActive == true {
            // Leave the pill as an idle one rather than thinking forever.
            HookServer.shared.ingestLocalEvent(name: "SessionEnd", payload: basePayload(app))
        }
        trackers[app] = nil
    }

    // MARK: - Poll

    private func poll() {
        guard !scanning else { return }   // the previous scan is still walking a big window
        tick += 1
        let jobs: [(ChatApp, pid_t, Bool)] = pids.map { app, pid in
            let active = trackers[app]?.isActive == true
            return (app, pid, app.hasToolApprovals && active && tick % Self.approvalScanEvery == 0)
        }
        guard !jobs.isEmpty else { return }
        scanning = true
        let scanner = self.scanner
        scanner.queue.async { [weak self] in
            let results = jobs.map { app, pid, full in
                (app, pid, scanner.scan(pid: pid, app: app, wantsFullScan: full))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanning = false
                    for (app, pid, result) in results where self.pids[app] == pid {
                        self.apply(result, for: app)
                    }
                }
            }
        }
    }

    private func apply(_ result: ChatAppScanner.Result, for app: ChatApp) {
        // A Claude Code session from the app's Code tab already drives this pill through
        // its hooks: let them speak, and do not report the same answer twice.
        if HookServer.shared.hasLiveHookSession(agent: app.agentTag) {
            trackers[app]?.reset()
            return
        }
        if let title = result.title { titles[app] = title }
        var tracker = trackers[app] ?? ChatAppTracker()
        let events = tracker.update(result.signal, at: Date())
        trackers[app] = tracker
        guard !events.isEmpty else { return }

        // The answer is right under the user's eyes: update Mochi, keep the island quiet.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let quiet = frontmost.map { app.bundleIds.contains($0) } ?? false
        let title = titles[app]

        for event in events {
            var payload = basePayload(app)
            payload["coucou_quiet"] = quiet
            switch event {
            case .started:
                payload["prompt"] = title ?? String(localized: "Writing an answer…")
                HookServer.shared.ingestLocalEvent(name: "UserPromptSubmit", payload: payload)
            case .needsApproval:
                HookServer.shared.chatAppNeedsApproval(agent: app.agentTag, appName: app.displayName, quiet: quiet)
            case .approvalCleared:
                HookServer.shared.chatAppApprovalCleared(agent: app.agentTag)
            case .finished:
                payload["last_assistant_message"] = title.map { String(localized: "Answer ready · \($0)") }
                    ?? String(localized: "Answer ready")
                AppState.shared.chatAnswerPillId = app.pillId
                HookServer.shared.ingestLocalEvent(name: "Stop", payload: payload)
            }
        }
    }

    private func basePayload(_ app: ChatApp) -> [String: Any] {
        ["session_id": "chat-\(app.agentTag)", "coucou_agent": app.agentTag]
    }
}
#endif
