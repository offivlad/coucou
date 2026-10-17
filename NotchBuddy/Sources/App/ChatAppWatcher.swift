#if !APPSTORE
import AppKit
import ApplicationServices

// MARK: - Chat app watcher (Claude Desktop, ChatGPT Desktop)
//
// The chats of the Claude and ChatGPT desktop apps have no hooks. When turned on in
// Settings → Agents, Coucou reads their windows through the Accessibility API: a stop
// button means an answer is being written, a tool prompt (Claude's "Allow once") means
// the app waits for you. Mochi thinks on the app's pill meanwhile and says when the
// answer is ready. Nothing leaves the Mac: only button labels and the window title are
// read. The one thing ever pressed is the tool prompt's Allow / Always / Deny, and only
// after you chose the same on Coucou's approval card.
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
        /// Texts of the tool prompt (its title, the URL…), when one is showing.
        var promptText: String? = nil
    }

    let queue = DispatchQueue(label: "fr.louisraille.coucou.chat-apps", qos: .utility)

    /// The element around the message box, per process.
    private var boxes: [pid_t: AXUIElement] = [:]
    private var lastFullScan: [pid_t: Date] = [:]
    /// Whole-window walks in a row that found no message box: each one doubles the wait.
    private var boxMisses: [pid_t: Int] = [:]
    private var accessibilityAsked: Set<pid_t> = []
    /// Buttons of the tool prompt seen by the last scan, to press them from the notch.
    private var promptButtons: [pid_t: [ChatButtonKind: AXUIElement]] = [:]

    private static let fullScanBudget = 4_000
    private static let boxScanBudget  = 400
    private static let maxDepth       = 64
    /// Wall-clock cap of one walk: an app that answers slowly must not hold the queue.
    private static let walkDeadline: TimeInterval = 1.0
    /// Without a known message box, walk the whole window at most this often, backing off
    /// up to a minute while the box stays out of sight (no window, a settings page…).
    private static let fullScanInterval: TimeInterval = 5
    private static let maxFullScanInterval: TimeInterval = 15
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
        promptButtons[pid] = nil
    }

    /// Presses a button of the tool prompt the last scan saw. Only ever called after the
    /// user clicked the same choice in the notch. False when the prompt is gone.
    func press(pid: pid_t, kind: ChatButtonKind) -> Bool {
        guard let button = promptButtons[pid]?[kind] else { return false }
        AXUIElementSetMessagingTimeout(button, 0.5)
        let ok = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        if ok { promptButtons[pid] = nil }
        return ok
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
        var promptText: String? = nil
        var complete = false
        var boxFound = false

        if let box = boxes[pid] {
            let walk = walk(from: [box], budget: Self.boxScanBudget)
            if let promptBox = walk.promptBox { promptText = texts(in: promptBox) }
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
                promptButtons[pid] = walk.prompt.isEmpty ? nil : walk.prompt
                if let box = walk.promptBox { promptText = texts(in: box) }
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
        return Result(signal: signal, title: ChatAppWatcherLogic.conversationTitle(title, app: app),
                      promptText: signal == .needsApproval ? promptText : nil)
    }

    // MARK: - Diagnostic map

    /// A text map of the app's windows: roles, labels, DOM ids and classes, and the first
    /// characters of texts. Written to a file only when the user asks for it in Settings.
    func dumpTree(pid: pid_t) -> String {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 1.0)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var lines: [String] = []
        var stack: [(AXUIElement, Int)] = elements(root, kAXWindowsAttribute).reversed().map { ($0, 0) }
        var count = 0
        while let item = stack.popLast(), count < 30_000 {
            let (element, depth) = item
            count += 1
            AXUIElementSetMessagingTimeout(element, 0.5)
            func str(_ attr: String) -> String? {
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
                if let s = ref as? String { return s.isEmpty ? nil : s }
                if let a = ref as? [String] { return a.isEmpty ? nil : a.joined(separator: ".") }
                if let n = ref as? NSNumber { return n.stringValue }
                return nil
            }
            var parts: [String] = [str(kAXRoleAttribute) ?? "?"]
            if let v = str(kAXSubroleAttribute) { parts.append("sub=\(v)") }
            if let v = str("AXDOMIdentifier") { parts.append("#\(v)") }
            if let v = str("AXDOMClassList") { parts.append(".\(v.prefix(80))") }
            for (key, attr) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute),
                                ("help", kAXHelpAttribute), ("value", kAXValueAttribute)] {
                if let v = str(attr) {
                    let flat = v.replacingOccurrences(of: "\n", with: " ")
                    parts.append("\(key)=\"\(flat.prefix(60))\(flat.count > 60 ? "…" : "")\"")
                }
            }
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
            guard depth < 90 else { continue }
            for child in elements(element, kAXChildrenAttribute).reversed() {
                stack.append((child, depth + 1))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tree walk

    private struct Walk {
        var kinds: [ChatButtonKind] = []
        /// Grandparent of the first message box button met: holds the stop / send spot.
        var box: AXUIElement? = nil
        /// The walk ran out of elements before running out of budget.
        var complete = false
        /// Allow once / Allow always / Deny buttons, first of each.
        var prompt: [ChatButtonKind: AXUIElement] = [:]
        /// The element around the prompt, to read its title.
        var promptBox: AXUIElement? = nil
    }

    private struct Visit {
        let element: AXUIElement
        let parent: AXUIElement?
        let grandparent: AXUIElement?
        var ancestors: [AXUIElement] = []
        let depth: Int
    }

    /// Depth-first, last child first: both apps put the message box and their dialogs at
    /// the end of the window, after the conversation, so they come up early.
    private func walk(from roots: [AXUIElement], budget: Int) -> Walk {
        var result = Walk()
        var stack = roots.map { Visit(element: $0, parent: nil, grandparent: nil, ancestors: [], depth: 0) }
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
                    if kind == .allowOnce || kind == .allowAlways || kind == .deny, result.prompt[kind] == nil {
                        result.prompt[kind] = visit.element
                        // The prompt card: a few levels above its buttons, holding its title.
                        if result.promptBox == nil {
                            result.promptBox = visit.ancestors.dropLast(3).last ?? visit.ancestors.first
                        }
                    }
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
                                   grandparent: visit.parent,
                                   ancestors: Array((visit.ancestors + [visit.element]).suffix(6)),
                                   depth: visit.depth + 1))
            }
        }
        result.complete = true
        return result
    }

    /// Static texts and headings under `root` (the prompt card), joined: "Claude wants to
    /// load a web page URL https://…". A small budget: the card is a few dozen elements.
    private func texts(in root: AXUIElement) -> String {
        var out: [String] = []
        var stack = [root]
        var visited = 0
        while let el = stack.popLast(), visited < 250 {
            visited += 1
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref) == .success,
               let role = ref as? String, role == "AXStaticText" || role == "AXHeading" || role == "AXLink" {
                for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    var v: CFTypeRef?
                    if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
                       let text = v as? String, !text.isEmpty { out.append(text); break }
                }
            }
            stack.append(contentsOf: elements(el, kAXChildrenAttribute).reversed())
        }
        return out.joined(separator: " ")
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
        HookServer.shared.closeChatApprovalCard(agent: app.agentTag)
        if trackers[app]?.isActive == true {
            // Leave the pill as an idle one rather than thinking forever.
            HookServer.shared.ingestLocalEvent(name: "SessionEnd", payload: basePayload(app))
        }
        trackers[app] = nil
    }

    // MARK: - Diagnostic

    /// Saves a map of the app's window to the Desktop (Settings button). Nil if not running.
    func saveDiagnostic(_ app: ChatApp, done: @escaping @MainActor (URL?) -> Void) {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            app.bundleIds.contains($0.bundleIdentifier ?? "")
        }) else { done(nil); return }
        let pid = running.processIdentifier
        let scanner = self.scanner
        scanner.queue.async {
            let text = scanner.dumpTree(pid: pid)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/coucou-\(app.rawValue)-map-\(stamp).txt")
            let ok = (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok ? url : nil) } }
        }
    }

    // MARK: - Answering a tool prompt from the notch

    /// Answers the app's tool prompt with the choice the user made on the approval card.
    /// First presses the button through Accessibility; the Claude app may ignore that, so
    /// if the prompt is still there a moment later, sends the prompt's own shortcut
    /// (⌘↩ allow once, ⇧⌘↩ always, Esc deny) to the app, and as a last resort brings the
    /// app forward and sends it again. Calls back with whether the prompt went away.
    func answerApproval(_ app: ChatApp, kind: ChatButtonKind, done: @escaping @MainActor (Bool) -> Void) {
        guard let pid = pids[app] else { done(false); return }
        let scanner = self.scanner
        let inFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let previous = NSWorkspace.shared.frontmostApplication?.processIdentifier
        scanner.queue.async {
            if inFront {
                // The app is in front: its own shortcut is the surest way.
                Self.sendShortcut(kind, to: nil)
                Thread.sleep(forTimeInterval: 0.8)
                let gone = scanner.scan(pid: pid, app: app, wantsFullScan: true).signal != .needsApproval
                appendAppLog("nb.log", "Chat app prompt answered by shortcut (app in front): \(gone ? "done" : "prompt still there")")
                DispatchQueue.main.async { MainActor.assumeIsolated { done(gone) } }
                return
            }
            var pressed = scanner.press(pid: pid, kind: kind)
            if !pressed, kind == .allowOnce { pressed = scanner.press(pid: pid, kind: .allowAlways) }
            Thread.sleep(forTimeInterval: 0.8)
            if scanner.scan(pid: pid, app: app, wantsFullScan: true).signal != .needsApproval {
                appendAppLog("nb.log", "Chat app prompt answered by Accessibility press")
                DispatchQueue.main.async { MainActor.assumeIsolated { done(true) } }
                return
            }
            // Accessibility press had no effect: the prompt's keyboard shortcut, to the app.
            Self.sendShortcut(kind, to: pid)
            Thread.sleep(forTimeInterval: 0.8)
            if scanner.scan(pid: pid, app: app, wantsFullScan: true).signal != .needsApproval {
                appendAppLog("nb.log", "Chat app prompt answered by shortcut sent to the app")
                DispatchQueue.main.async { MainActor.assumeIsolated { done(true) } }
                return
            }
            // Last try: the app in front, the shortcut through the system.
            DispatchQueue.main.sync {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            }
            Thread.sleep(forTimeInterval: 0.35)
            Self.sendShortcut(kind, to: nil)
            Thread.sleep(forTimeInterval: 0.8)
            let gone = scanner.scan(pid: pid, app: app, wantsFullScan: true).signal != .needsApproval
            appendAppLog("nb.log", "Chat app prompt answered after bringing the app forward: \(gone ? "done" : "prompt still there")")
            // Give the front back to the app the user was in.
            if let previous, previous != pid {
                DispatchQueue.main.sync { NSRunningApplication(processIdentifier: previous)?.activate(options: []) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(gone) } }
        }
    }

    /// ⌘↩ (allow once), ⇧⌘↩ (always), Esc (deny): to one process, or to the frontmost app.
    nonisolated private static func sendShortcut(_ kind: ChatButtonKind, to pid: pid_t?) {
        let key: CGKeyCode = kind == .deny ? 53 : 36   // Esc, Return
        var flags: CGEventFlags = []
        if kind == .allowOnce { flags = [.maskCommand] }
        if kind == .allowAlways { flags = [.maskCommand, .maskShift] }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
            usleep(30_000)
        }
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
                // Auto-approve → "Web search and pages" also covers the app's web page prompts.
                if app == .claude, ChatAppWatcherLogic.isWebPrompt(result.promptText),
                   AutoApproveGroup.enabled().contains(.web) {
                    HookServer.shared.chatAppAutoApproved(agent: app.agentTag, what: result.promptText ?? "")
                    answerApproval(app, kind: .allowOnce) { [weak self] ok in
                        appendAppLog("nb.log", "Chat app web prompt auto-approved: \(ok ? "done" : "prompt still there")")
                        // Ready for the next page Claude asks for. On a failure the prompt stays
                        // with the user: never send the shortcut again and again.
                        if ok { self?.trackers[app]?.clearApproval() }
                    }
                    break
                }
                HookServer.shared.chatAppNeedsApproval(agent: app.agentTag, appName: app.displayName, quiet: quiet)
            case .approvalCleared:
                HookServer.shared.chatAppApprovalCleared(agent: app.agentTag)
            case .finished:
                payload["last_assistant_message"] = title.map { String(localized: "Answer ready · \($0)") }
                    ?? String(localized: "Answer ready")
                HookServer.shared.closeChatApprovalCard(agent: app.agentTag)
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
