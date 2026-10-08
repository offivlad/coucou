import Foundation

// MARK: - Chat app watcher: pure logic
//
// Claude Desktop and ChatGPT Desktop have no hooks for their chats, so Coucou reads
// their windows through the Accessibility API (ChatAppWatcher.swift, GitHub build only).
// This file holds everything that does not touch AppKit, so scripts/test-chat-apps.sh can
// compile it on its own: which apps, which button labels mean "answering" or "waiting for
// you", and the debounce that turns poll results into start / finish events.

/// A desktop chat app Coucou can watch.
enum ChatApp: String, CaseIterable, Sendable {
    case claude
    case chatgpt

    /// Bundle identifiers of the app (first one is the one opened by the pill's ↗ button).
    var bundleIds: [String] {
        switch self {
        case .claude:  return ["com.anthropic.claudefordesktop"]
        case .chatgpt: return ["com.openai.chat"]
        }
    }

    /// `coucou_agent` tag of the events sent for this app.
    /// Claude shares its pill with the Claude Code sessions of the app's Code tab.
    var agentTag: String {
        switch self {
        case .claude:  return "claude-desktop"
        case .chatgpt: return "chatgpt-desktop"
        }
    }

    var pillId: String { "agent_\(agentTag)" }

    var displayName: String {
        switch self {
        case .claude:  return "Claude"
        case .chatgpt: return "ChatGPT"
        }
    }

    /// Electron apps only build their accessibility tree once asked to (AXManualAccessibility).
    var isElectron: Bool { self == .claude }

    /// Claude asks before running a connector (MCP) tool; ChatGPT has no such prompt.
    var hasToolApprovals: Bool { self == .claude }

    /// Window titles that only repeat the app name and say nothing about the conversation.
    var genericTitles: Set<String> {
        switch self {
        case .claude:  return ["claude"]
        case .chatgpt: return ["chatgpt", "new chat", "nouveau chat", "nouvelle conversation"]
        }
    }

    init?(bundleId: String) {
        guard let app = ChatApp.allCases.first(where: { $0.bundleIds.contains(bundleId) }) else { return nil }
        self = app
    }
}

/// What a scan saw in the app's windows.
enum ChatAppSignal: Equatable, Sendable {
    /// A stop button is showing: the app is writing an answer.
    case generating
    /// A tool approval prompt is showing: the app waits for the user.
    case needsApproval
    /// The composer is there and nothing is running.
    case idle
    /// Nothing recognisable was found (window closed, tree not ready, scan skipped).
    case unknown
}

/// Role of a button, from its accessibility label.
enum ChatButtonKind: Equatable, Sendable {
    case stop
    case send
    /// Another button of the message box (attach, dictate, voice): marks where the box is.
    case composer
    case allowOnce
    case allowAlways
    case deny
}

enum ChatAppWatcherLogic {

    /// Lowercased, diacritics folded, curly apostrophes made straight, spaces collapsed.
    static func normalize(_ label: String) -> String {
        let folded = label
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'")
        return folded
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // Labels seen in English and French builds of both apps, plus the usual words in the
    // other languages Coucou speaks. Kept loose on purpose: the apps reword them often.
    private static let stopVerbs = ["stop", "arreter", "interrompre", "detener", "parar",
                                    "stoppen", "anhalten", "остановить", "停止"]
    private static let stopObjects = ["respon", "reponse", "generat", "generation", "generier",
                                      "stream", "diffusion", "antwort", "resposta", "gerar",
                                      "respuesta", "ответ", "生成", "回答"]
    /// A stop button for something else than the answer (voice, dictation, read aloud…).
    private static let stopExclusions = ["record", "dictat", "voice", "vocal", "listen", "enregistr",
                                         "audio", "read aloud", "lecture", "share", "partag",
                                         "upload", "televers", "download", "telecharg", "screen",
                                         "ecran", "video", "timer", "minuteur"]
    private static let sendLabels = ["send", "send message", "send prompt", "envoyer",
                                     "envoyer le message", "envoyer l'invite", "enviar",
                                     "enviar mensaje", "enviar mensagem", "senden",
                                     "nachricht senden", "отправить", "发送"]

    private static let composerWords = ["dictat", "dicter", "voice mode", "mode vocal", "use voice",
                                        "attach", "add files", "add photos", "upload a file", "joindre",
                                        "ajouter des fichiers", "ajouter des photos", "importer un fichier"]

    /// Classifies a button label. Returns nil for any other button.
    static func classify(_ rawLabel: String) -> ChatButtonKind? {
        let label = normalize(rawLabel)
        guard !label.isEmpty, label.count <= 48 else { return nil }

        if !stopExclusions.contains(where: { label.contains($0) }) {
            if stopVerbs.contains(label) { return .stop }
            if stopVerbs.contains(where: { label.hasPrefix($0) || label.hasSuffix($0) }),
               stopObjects.contains(where: { label.contains($0) }) {
                return .stop
            }
        }

        if sendLabels.contains(label) { return .send }
        if composerWords.contains(where: { label.contains($0) }) { return .composer }

        let allows = ["allow", "autoriser", "permitir", "erlauben", "zulassen"]
        if allows.contains(where: { label.contains($0) }) {
            let once = ["once", "une fois", "una vez", "uma vez", "einmal"]
            let always = ["always", "toujours", "siempre", "sempre", "immer", "this chat",
                          "cette conversation", "ce chat", "cette discussion"]
            if once.contains(where: { label.contains($0) }) { return .allowOnce }
            if always.contains(where: { label.contains($0) }) { return .allowAlways }
            return nil
        }
        let denies = ["deny", "refuser", "decline", "denegar", "negar", "ablehnen", "rechazar"]
        if denies.contains(label) { return .deny }
        return nil
    }

    /// Reads one scan's buttons. A tool prompt wins over a running answer: Claude keeps its
    /// stop button while it waits for the approval. `complete` says the scan went through the
    /// whole window (or the whole message box) without running out of budget: only then does
    /// a missing stop button mean the answer is over.
    static func signal(for kinds: [ChatButtonKind], complete: Bool, app: ChatApp) -> ChatAppSignal {
        if app.hasToolApprovals {
            let hasOnce   = kinds.contains(.allowOnce)
            let hasAlways = kinds.contains(.allowAlways)
            let hasDeny   = kinds.contains(.deny)
            // "Always allow" alone also shows on the connector settings page: ask for a deny next to it.
            if hasOnce || (hasAlways && hasDeny) { return .needsApproval }
        }
        if kinds.contains(.stop) { return .generating }
        if complete || kinds.contains(.send) { return .idle }
        return .unknown
    }

    /// The conversation title worth showing, or nil when the window title is only the app name.
    static func conversationTitle(_ rawTitle: String?, app: ChatApp) -> String? {
        guard let rawTitle else { return nil }
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // "My chat - Claude", "ChatGPT — My chat": drop the app name around the dash.
        for sep in [" - ", " — ", " – ", " | "] {
            let parts = title.components(separatedBy: sep)
            if parts.count > 1 {
                let kept = parts.filter { !app.genericTitles.contains(normalize($0)) }
                if !kept.isEmpty { title = kept.joined(separator: sep) }
            }
        }
        guard !title.isEmpty, !app.genericTitles.contains(normalize(title)) else { return nil }
        return title.count > 60 ? String(title.prefix(59)) + "…" : title
    }
}

// MARK: - Debounce

/// Turns raw scan signals into session events.
/// Start is immediate; finish waits for `idleConfirmations` scans in a row without a stop
/// button, so the button swap Claude does between two blocks of an answer is not read
/// as the end. A few `unknown` scans change nothing; `unknownLimit` of them in a row while
/// an answer runs (window closed, message box gone) end it, so the pill never thinks forever.
struct ChatAppTracker: Sendable {
    enum Event: Equatable, Sendable {
        case started
        case needsApproval
        case approvalCleared
        case finished(duration: TimeInterval)
    }

    var idleConfirmations = 2
    var unknownLimit = 8

    private(set) var isActive = false
    private(set) var waitingApproval = false
    private(set) var startedAt: Date? = nil
    private var idleStreak = 0
    private var unknownStreak = 0

    init(idleConfirmations: Int = 2, unknownLimit: Int = 8) {
        self.idleConfirmations = idleConfirmations
        self.unknownLimit = unknownLimit
    }

    mutating func update(_ signal: ChatAppSignal, at now: Date) -> [Event] {
        var events: [Event] = []
        switch signal {
        case .unknown:
            guard isActive else { return [] }
            unknownStreak += 1
            guard unknownStreak >= unknownLimit else { return [] }
            let duration = startedAt.map { now.timeIntervalSince($0) } ?? 0
            reset()
            events.append(.finished(duration: duration))
        case .generating, .needsApproval:
            idleStreak = 0
            unknownStreak = 0
            if !isActive {
                isActive = true
                startedAt = now
                events.append(.started)
            }
            if signal == .needsApproval, !waitingApproval {
                waitingApproval = true
                events.append(.needsApproval)
            } else if signal == .generating, waitingApproval {
                waitingApproval = false
                events.append(.approvalCleared)
            }
        case .idle:
            guard isActive else { return [] }
            unknownStreak = 0
            idleStreak += 1
            guard idleStreak >= idleConfirmations else { return [] }
            let duration = startedAt.map { now.timeIntervalSince($0) } ?? 0
            reset()
            events.append(.finished(duration: duration))
        }
        return events
    }

    /// The app quit or watching stopped: forget the running answer without reporting it.
    mutating func reset() {
        isActive = false
        waitingApproval = false
        startedAt = nil
        idleStreak = 0
        unknownStreak = 0
    }
}
