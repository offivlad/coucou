#if !APPSTORE
import Foundation

// MARK: - ClaudeUsageFetcher
//
// The plan gauge used to follow only Claude Code's status line, so it froze at whatever
// Claude Code last reported (often hours ago) while the user worked in the regular chats,
// which spend the same limits. Every five minutes this asks the account's usage directly,
// the way Claude Code's /usage does: the OAuth token Claude Code keeps in the login keychain
// ("Claude Code-credentials", read with /usr/bin/security: macOS asks once), then
// GET api.anthropic.com/api/oauth/usage. The token never leaves this Mac except to that
// endpoint, and is not stored by Coucou. Without Claude Code signed in, nothing changes.

@MainActor
final class ClaudeUsageFetcher {
    static let shared = ClaudeUsageFetcher()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in ClaudeUsageFetcher.shared.refresh() }
        }
    }

    func refresh() {
        Task.detached(priority: .utility) {
            guard let token = Self.token() else { return }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 15
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let usage = Self.parse(data) else {
                appendAppLog("nb.log", "[Plan] usage request: HTTP \(status)")
                return
            }
            await MainActor.run {
                AppState.shared.claudePlanUsage = usage
            }
        }
    }

    /// {"five_hour":{"utilization":41.0,"resets_at":"2026-10-18T12:00:00Z"},"seven_day":{…}}
    nonisolated static func parse(_ data: Data) -> PlanUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> PlanWindow? {
            guard let d = obj[key] as? [String: Any] else { return nil }
            let pct: Double
            if let v = d["utilization"] as? Double { pct = v }
            else if let v = d["utilization"] as? Int { pct = Double(v) }
            else { return nil }
            guard let s = d["resets_at"] as? String, let date = isoDate(s) else { return nil }
            return PlanWindow(usedPct: min(100, max(0, pct)), resetsAt: date)
        }
        let fh = window("five_hour"), sd = window("seven_day")
        guard fh != nil || sd != nil else { return nil }
        return PlanUsage(fiveHour: fh, sevenDay: sd, updatedAt: Date())
    }

    nonisolated private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Claude Code's access token from the login keychain, or nil.
    nonisolated private static func token() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}
#endif
