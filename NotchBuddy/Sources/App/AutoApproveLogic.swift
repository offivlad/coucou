import Foundation

// MARK: - Auto-approve rules (pure logic, tested by scripts/test-auto-approve.sh)
//
// Settings → Agents → Auto-approve: groups of Claude Code tools that Coucou allows on its
// own, without a card. Everything else still asks. Off for every group by default.

enum AutoApproveGroup: String, CaseIterable, Sendable {
    case web      // search the web, open pages
    case read     // read files, list and search the project
    case edit     // change files in the project
    case terminal // run terminal commands
    case mcp      // tools of connected MCP servers

    /// Claude Code tool names in the group. `mcp` matches by prefix instead.
    var tools: Set<String> {
        switch self {
        case .web:      return ["WebSearch", "WebFetch"]
        case .read:     return ["Read", "Glob", "Grep", "LS", "NotebookRead", "TodoRead", "TodoWrite"]
        case .edit:     return ["Edit", "MultiEdit", "Write", "NotebookEdit"]
        case .terminal: return ["Bash", "BashOutput", "KillShell", "KillBash"]
        case .mcp:      return []
        }
    }

    /// The group a tool belongs to, nil for tools no group covers (they always ask).
    static func group(forTool tool: String) -> AutoApproveGroup? {
        if tool.hasPrefix("mcp__") { return .mcp }
        return allCases.first { $0.tools.contains(tool) }
    }

    /// UserDefaults key holding the raw values of the groups that are on.
    static let defaultsKey = "autoApproveGroups"

    static func enabled(in defaults: UserDefaults = .standard) -> Set<AutoApproveGroup> {
        Set((defaults.stringArray(forKey: defaultsKey) ?? []).compactMap(AutoApproveGroup.init(rawValue:)))
    }

    static func setEnabled(_ groups: Set<AutoApproveGroup>, in defaults: UserDefaults = .standard) {
        defaults.set(groups.map(\.rawValue).sorted(), forKey: defaultsKey)
    }
}

enum AutoApprove {
    /// Commands that are never allowed on their own, even with the terminal group on:
    /// deleting, privileges, disks, pushing code, piping a download into a shell.
    private static let dangerousPatterns: [String] = [
        #"(^|[\s;&|(])rm\s"#, #"(^|[\s;&|(])sudo\b"#, #"(^|[\s;&|(])su\s"#,
        #"\bmkfs\b"#, #"\bdd\s+if="#, #"\bdiskutil\s+(erase|partition|zero)"#,
        #"\bgit\s+push\b"#, #"\bgit\s+reset\s+--hard"#, #"\bgit\s+clean\b"#,
        #"\bchmod\s+(-R\s+)?777\b"#, #"\bchown\s+-R\b"#,
        #"(curl|wget)[^|]*\|\s*(sudo\s+)?(ba|z)?sh\b"#,
        #"\blaunchctl\b"#, #"\bkillall\b"#, #"\bshutdown\b"#, #"\breboot\b"#,
        #">\s*/(etc|System|Library|usr)/"#, #"\bsecurity\s+(find|dump|delete)"#,
    ]

    /// True when a Bash command looks destructive or privileged.
    static func isDangerous(command: String) -> Bool {
        dangerousPatterns.contains { command.range(of: $0, options: .regularExpression) != nil }
    }

    /// The group that allows this request, or nil when the request must ask.
    static func allowingGroup(tool: String, input: [String: Any],
                              enabled: Set<AutoApproveGroup>) -> AutoApproveGroup? {
        guard let group = AutoApproveGroup.group(forTool: tool), enabled.contains(group) else { return nil }
        if group == .terminal, isDangerous(command: input["command"] as? String ?? "") { return nil }
        return group
    }
}
