import Foundation

@main
enum ChatAppWatcherTests {
    static func main() {
        testApps()
        testClassify()
        testSignal()
        testConversationTitle()
        testTracker()
        print("ChatAppWatcherLogic: all cases passed")
    }

    // MARK: - Apps

    static func testApps() {
        precondition(ChatApp(bundleId: "com.anthropic.claudefordesktop") == .claude, "Claude bundle id")
        precondition(ChatApp(bundleId: "com.openai.chat") == .chatgpt, "ChatGPT bundle id")
        precondition(ChatApp(bundleId: "com.openai.codex") == nil, "Codex is not a chat app")
        // Claude shares the pill of the Code tab sessions; the ID is a contract value.
        precondition(ChatApp.claude.pillId == "agent_claude-desktop", "Claude pill id")
        precondition(ChatApp.chatgpt.pillId == "agent_chatgpt-desktop", "ChatGPT pill id")
        for app in ChatApp.allCases {
            // Same rule as HookServer.validateAgent: [a-z0-9-]{1,24}
            let tag = app.agentTag
            precondition(tag.count <= 24 && tag.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" },
                         "\(tag) must be a valid coucou_agent")
        }
    }

    // MARK: - Labels

    static func testClassify() {
        let stops = ["Stop response", "Stop Response", "Stop generating", "Stop streaming", "Stop",
                     "Arrêter la réponse", "Arrêter la génération", "Arrêter la diffusion en continu",
                     "Arrêter", "Detener respuesta", "Antwort stoppen", "  stop   response "]
        for label in stops {
            precondition(ChatAppWatcherLogic.classify(label) == .stop, "\(label) must read as stop")
        }
        let notStops = ["Stop recording", "Stop dictation", "Stop voice mode", "Arrêter l'enregistrement",
                        "Stop sharing", "Stop reading aloud", "Stopwatch", "Bus stop schedule", ""]
        for label in notStops {
            precondition(ChatAppWatcherLogic.classify(label) != .stop, "\(label) must not read as stop")
        }
        precondition(ChatAppWatcherLogic.classify(String(repeating: "stop response ", count: 5)) == nil,
                     "long text is a message, not a button")

        precondition(ChatAppWatcherLogic.classify("Send message") == .send, "Claude send")
        precondition(ChatAppWatcherLogic.classify("Send prompt") == .send, "ChatGPT send")
        precondition(ChatAppWatcherLogic.classify("Envoyer le message") == .send, "French send")
        precondition(ChatAppWatcherLogic.classify("Dictate") == .composer, "dictate marks the box")
        precondition(ChatAppWatcherLogic.classify("Start voice mode") == .composer, "voice marks the box")
        precondition(ChatAppWatcherLogic.classify("Add photos and files") == .composer, "attach marks the box")

        precondition(ChatAppWatcherLogic.classify("Allow once") == .allowOnce, "allow once")
        precondition(ChatAppWatcherLogic.classify("Autoriser une fois") == .allowOnce, "French allow once")
        precondition(ChatAppWatcherLogic.classify("Always allow") == .allowAlways, "always allow")
        precondition(ChatAppWatcherLogic.classify("Allow for this chat") == .allowAlways, "allow for chat")
        precondition(ChatAppWatcherLogic.classify("Toujours autoriser") == .allowAlways, "French always")
        precondition(ChatAppWatcherLogic.classify("Deny") == .deny, "deny")
        precondition(ChatAppWatcherLogic.classify("Refuser") == .deny, "French deny")
        precondition(ChatAppWatcherLogic.classify("Don't allow notifications") == nil, "other allow buttons")
        precondition(ChatAppWatcherLogic.classify("New chat") == nil, "unrelated button")
    }

    // MARK: - Signal

    static func testSignal() {
        typealias L = ChatAppWatcherLogic
        precondition(L.signal(for: [.stop, .composer], complete: false, app: .claude) == .generating, "stop → generating")
        precondition(L.signal(for: [.send], complete: false, app: .chatgpt) == .idle, "send → idle")
        precondition(L.signal(for: [.composer], complete: true, app: .chatgpt) == .idle, "full scan, no stop → idle")
        precondition(L.signal(for: [.composer], complete: false, app: .chatgpt) == .unknown, "partial scan → unknown")
        precondition(L.signal(for: [], complete: false, app: .claude) == .unknown, "nothing → unknown")
        precondition(L.signal(for: [.stop, .allowOnce, .deny], complete: false, app: .claude) == .needsApproval,
                     "approval wins over the stop button")
        precondition(L.signal(for: [.allowAlways, .deny], complete: true, app: .claude) == .needsApproval,
                     "always allow + deny is a prompt")
        precondition(L.signal(for: [.allowAlways, .send], complete: true, app: .claude) == .idle,
                     "always allow alone is the settings page")
        precondition(L.signal(for: [.allowOnce, .stop], complete: true, app: .chatgpt) == .generating,
                     "ChatGPT has no tool prompt")
    }

    // MARK: - Titles

    static func testConversationTitle() {
        typealias L = ChatAppWatcherLogic
        precondition(L.conversationTitle("Claude", app: .claude) == nil, "app name only")
        precondition(L.conversationTitle("ChatGPT", app: .chatgpt) == nil, "app name only")
        precondition(L.conversationTitle("New chat", app: .chatgpt) == nil, "empty conversation")
        precondition(L.conversationTitle(nil, app: .claude) == nil, "no title")
        precondition(L.conversationTitle("  Trip to Lyon  ", app: .chatgpt) == "Trip to Lyon", "trimmed")
        precondition(L.conversationTitle("Trip to Lyon - Claude", app: .claude) == "Trip to Lyon", "suffix dropped")
        precondition(L.conversationTitle("ChatGPT — Trip to Lyon", app: .chatgpt) == "Trip to Lyon", "prefix dropped")
        precondition(L.conversationTitle("Rock - Paper - Scissors", app: .chatgpt) == "Rock - Paper - Scissors",
                     "dashes inside a title stay")
        let long = String(repeating: "a", count: 80)
        precondition(L.conversationTitle(long, app: .chatgpt)?.count == 60, "long titles cut at 60")
    }

    // MARK: - Tracker

    static func testTracker() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var tracker = ChatAppTracker()

        precondition(tracker.update(.idle, at: t0).isEmpty, "idle before anything → nothing")
        precondition(tracker.update(.unknown, at: t0).isEmpty, "unknown → nothing")

        precondition(tracker.update(.generating, at: t0) == [.started], "start is immediate")
        precondition(tracker.update(.generating, at: t0 + 1).isEmpty, "still running → nothing")
        precondition(tracker.update(.idle, at: t0 + 2).isEmpty, "one idle scan is not the end")
        precondition(tracker.update(.generating, at: t0 + 3).isEmpty, "back to running → no second start")
        precondition(tracker.update(.idle, at: t0 + 4).isEmpty, "first idle")
        precondition(tracker.update(.unknown, at: t0 + 5).isEmpty, "unknown keeps the streak")
        precondition(tracker.update(.idle, at: t0 + 6) == [.finished(duration: 6)], "two idle scans → finished")
        precondition(!tracker.isActive, "reset after finish")
        precondition(tracker.update(.idle, at: t0 + 7).isEmpty, "no second finish")

        // Approval while answering
        precondition(tracker.update(.needsApproval, at: t0 + 10) == [.started, .needsApproval],
                     "a prompt first thing also starts the session")
        precondition(tracker.update(.needsApproval, at: t0 + 11).isEmpty, "prompt reported once")
        precondition(tracker.update(.generating, at: t0 + 12) == [.approvalCleared], "answered → back to work")
        precondition(tracker.update(.needsApproval, at: t0 + 13) == [.needsApproval], "a second prompt")
        _ = tracker.update(.idle, at: t0 + 14)
        precondition(tracker.update(.idle, at: t0 + 15) == [.finished(duration: 5)], "finish after a prompt")

        // Too many unknown scans in a row end the answer
        var lost = ChatAppTracker(idleConfirmations: 2, unknownLimit: 3)
        precondition(lost.update(.generating, at: t0) == [.started], "start")
        precondition(lost.update(.unknown, at: t0 + 1).isEmpty, "1 unknown")
        precondition(lost.update(.unknown, at: t0 + 2).isEmpty, "2 unknown")
        precondition(lost.update(.generating, at: t0 + 3).isEmpty, "seen again → streak reset")
        precondition(lost.update(.unknown, at: t0 + 4).isEmpty, "1 unknown")
        precondition(lost.update(.unknown, at: t0 + 5).isEmpty, "2 unknown")
        precondition(lost.update(.unknown, at: t0 + 6) == [.finished(duration: 6)], "3 unknown → finished")
        precondition(lost.update(.unknown, at: t0 + 7).isEmpty, "unknown while idle → nothing")

        // Reset forgets a running answer
        _ = tracker.update(.generating, at: t0 + 20)
        tracker.reset()
        precondition(tracker.update(.idle, at: t0 + 21).isEmpty, "reset → no finish")
        precondition(tracker.update(.idle, at: t0 + 22).isEmpty, "reset → no finish")
    }
}
