#if !APPSTORE
import AppKit

// MARK: - Mac assistant ("Джарвис, …" / "Мочи, …" in Flow dictation)
//
// The command goes to Claude Code on this Mac (`claude -p`, the user's plan, no API key),
// told to act on the Mac with shell commands and osascript. Mochi shows each step on a
// "Jarvis" pill and says the answer out loud. Destructive commands are denied up front
// (--disallowedTools), the user's hooks are off for these runs (Coucou shows the steps
// itself), and a run is stopped after three minutes.

@MainActor
final class MacAssistant {
    static let shared = MacAssistant()

    static let enabledKey = "macAssistantByVoice"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static let agentTag = "jarvis"
    private var process: Process?
    private var timeout: Task<Void, Never>?
    private var runId = 0

    private static let systemPrompt = """
    You are J.A.R.V.I.S., the user's personal assistant on his Mac (macOS, Apple silicon), \
    in the manner of Tony Stark's AI: calm, precise, quietly witty, unfailingly polite. \
    Address the user as "сэр" in Russian ("sir" in English). The user spoke a command; do it \
    now with shell commands (Bash): osascript for apps, windows, volume, brightness keys, \
    notifications and System Events; `open` for apps, files and URLs; `pmset -g`, `defaults`, \
    `shortcuts run`, `system_profiler` when useful; web search for questions about the world. \
    Never ask questions back: pick the most reasonable reading. Something that must keep \
    running after you finish (keeping the screen awake with caffeinate) must be started \
    detached: `nohup caffeinate -dimsu -t <seconds> >/dev/null 2>&1 &` (no -t: until \
    `pkill caffeinate`). Never mute or lower the microphone (input volume): the user speaks \
    to you through it; politely refuse. Do not delete files, use sudo, change passwords, or \
    send messages and emails on the user's behalf. Reply in the user's language with one or \
    two short sentences meant to be spoken aloud: what you did or the answer, no markdown, \
    no lists, no URLs. Example: "Готово, сэр. Экран не погаснет ближайшие два часа."
    """

    private static let denied = [
        "Bash(rm:*)", "Bash(sudo:*)", "Bash(su:*)", "Bash(diskutil:*)", "Bash(mkfs:*)", "Bash(dd:*)",
        "Bash(shutdown:*)", "Bash(reboot:*)", "Bash(halt:*)", "Bash(launchctl:*)", "Bash(git push:*)",
        "Bash(chmod:*)", "Bash(chown:*)", "Bash(security:*)", "Bash(srm:*)", "Bash(trash:*)",
        "Write", "Edit", "MultiEdit",
    ]

    /// Where the Claude Code binary is: the native installer, Homebrew, npm.
    private static var claudeBinary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { claudeBinary != nil }

    /// The command in a dictation, when the assistant is on and Claude Code is installed.
    static func command(in dictation: String) -> String? {
        guard isEnabled, isAvailable else { return nil }
        return AskClaudeLogic.assistantCommand(fromDictation: dictation)
    }

    func run(_ command: String) {
        guard let binary = Self.claudeBinary else { return }
        process?.terminate()
        timeout?.cancel()
        runId += 1
        let id = runId
        let home = FileManager.default.homeDirectoryForCurrentUser
        let work = home.appendingPathComponent("claude-work")
        let cwd = FileManager.default.fileExists(atPath: work.path) ? work : home

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.currentDirectoryURL = cwd
        p.arguments = ["-p", command,
                       "--output-format", "stream-json", "--verbose",
                       "--model", "sonnet",
                       "--append-system-prompt", Self.systemPrompt,
                       "--allowedTools", "Bash", "Read", "Glob", "Grep", "WebSearch", "WebFetch",
                       "--disallowedTools"] + Self.denied + [
                       "--settings", #"{"disableAllHooks":true}"#]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        var basePayload: [String: Any] = ["session_id": "jarvis", "coucou_agent": Self.agentTag]
        basePayload["prompt"] = command
        HookServer.shared.ingestLocalEvent(name: "UserPromptSubmit", payload: basePayload)
        AppState.shared.focusId = "agent_\(Self.agentTag)"
        appendAppLog("nb.log", "Jarvis: \(command.count) characters")
        // A word right away, as in the films, while Claude Code starts.
        let ru = command.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil
        let acks = ru ? ["Слушаю, сэр.", "Секунду, сэр.", "Уже занимаюсь.", "Сию минуту, сэр."]
                      : ["Right away, sir.", "One moment, sir.", "On it, sir."]
        VoiceSpeaker.shared.speak(acks.randomElement()!, locale: Locale(identifier: ru ? "ru-RU" : "en-GB"))

        // Stream-json: one JSON object per line. Tool calls become steps, "result" ends it.
        let reader = LineReader { [weak self] line in
            Task { @MainActor in if self?.runId == id { self?.handle(line: line) } }
        }
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            reader.feed(data)
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in if self?.runId == id { self?.finished(status: status) } }
        }
        do { try p.run() } catch {
            finish(text: String(localized: "Claude Code could not start."), spoken: true)
            return
        }
        process = p
        gotResult = false
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard let self, !Task.isCancelled, self.runId == id, let running = self.process, running.isRunning else { return }
            running.terminate()
            self.gotResult = true
            self.finish(text: String(localized: "It took too long, I stopped."), spoken: true)
        }
    }

    private var gotResult = false

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch obj["type"] as? String {
        case "assistant":
            let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in content where block["type"] as? String == "tool_use" {
                var payload: [String: Any] = ["session_id": "jarvis", "coucou_agent": Self.agentTag]
                payload["tool_name"] = block["name"] as? String ?? "Tool"
                payload["tool_input"] = block["input"] as? [String: Any] ?? [:]
                HookServer.shared.ingestLocalEvent(name: "PreToolUse", payload: payload)
            }
        case "result":
            gotResult = true
            let text = (obj["result"] as? String) ?? ""
            let failed = obj["is_error"] as? Bool ?? false
            finish(text: text.isEmpty ? (failed ? String(localized: "Something went wrong.") : String(localized: "Done."))
                                      : text,
                   spoken: true)
        default:
            break
        }
    }

    private func finished(status: Int32) {
        timeout?.cancel()
        process = nil
        let id = runId
        // The last output lines can arrive just after the process ends.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.runId == id else { return }
            self.reportEnd(status: status)
        }
    }

    private func reportEnd(status: Int32) {
        if !gotResult {
            finish(text: status == 0 ? String(localized: "Done.")
                                     : String(localized: "Claude Code stopped. Is it signed in? Run claude in Terminal once."),
                   spoken: true)
        }
    }

    private func finish(text: String, spoken: Bool) {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        var payload: [String: Any] = ["session_id": "jarvis", "coucou_agent": Self.agentTag]
        payload["last_assistant_message"] = line
        AppState.shared.chatAnswerPillId = "agent_\(Self.agentTag)"
        AppState.shared.focusId = "agent_\(Self.agentTag)"
        HookServer.shared.ingestLocalEvent(name: "Stop", payload: payload)
        if spoken {
            let ru = line.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil
            // enqueue: after the acknowledgement if it is still being said.
            VoiceSpeaker.shared.enqueue(String(line.prefix(400)), locale: Locale(identifier: ru ? "ru-RU" : "en-GB"))
        }
    }
}

/// Splits a byte stream into lines (stream-json can cut a line across reads).
private final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { lines.append(s) }
        }
        lock.unlock()
        lines.forEach(onLine)
    }
}
#endif
