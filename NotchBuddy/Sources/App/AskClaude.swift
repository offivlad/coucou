#if !APPSTORE
import AppKit

// MARK: - "Ask Claude" by voice
//
// A Flow dictation that starts with "спроси Клод…" / "ask Claude…" opens a new chat in the
// Claude desktop app with the rest as the message, and sends it (or only types it, per
// Settings → Agents → Ask Claude by voice). Uses the Claude app, so your plan, not an API key.

@MainActor
enum AskClaude {
    static let enabledKey = "askClaudeByVoice"
    static let autoSendKey = "askClaudeAutoSend"

    /// On by default; the setting only turns it off.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var autoSend: Bool { UserDefaults.standard.object(forKey: autoSendKey) as? Bool ?? true }

    private static let bundleId = "com.anthropic.claudefordesktop"

    /// The question in a dictation, when the feature is on and the Claude app is installed.
    static func question(in dictation: String) -> String? {
        guard isEnabled,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil else { return nil }
        return AskClaudeLogic.question(fromDictation: dictation)
    }

    /// Opens a new Claude chat with `question`: the app comes forward, ⌘N, the text is pasted
    /// (the clipboard gets back what it held), then ↩ when auto-send is on.
    static func ask(_ question: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        appendAppLog("nb.log", "Ask Claude by voice: \(question.count) characters")
        let wasRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty == false
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
        Task { @MainActor in
            // A cold start needs a few seconds before the window takes keys.
            try? await Task.sleep(for: .milliseconds(wasRunning ? 600 : 4_000))
            for _ in 0..<10 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleId {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId else {
                appendAppLog("nb.log", "Ask Claude: the app did not come forward")
                return
            }
            key(45, [.maskCommand])                 // ⌘N: new chat
            try? await Task.sleep(for: .milliseconds(700))

            let board = NSPasteboard.general
            let saved = board.pasteboardItems?.map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                return copy
            } ?? []
            board.clearContents()
            board.setString(question, forType: .string)
            key(9, [.maskCommand])                  // ⌘V
            try? await Task.sleep(for: .milliseconds(350))
            if autoSend { key(36, []) }             // ↩ sends
            try? await Task.sleep(for: .milliseconds(400))
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }

    private static func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}
#endif
