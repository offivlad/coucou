import Foundation

// MARK: - "Ask Claude" by voice (pure logic, tested by scripts/test-ask-claude.sh)
//
// Flow dictation that starts with "спроси Клод…" / "ask Claude…" is not pasted: the rest
// becomes a new chat in the Claude desktop app (AskClaude.swift does the app part).

enum AskClaudeLogic {
    /// Spoken openers, lowercased. Speech recognition spells Claude many ways.
    private static let verbs = ["спроси у", "спроси", "спросить у", "спросить", "задай вопрос", "ask", "hey"]
    private static let names = ["клода", "клоду", "клод", "клауда", "клауд", "claude", "cloud", "клоде",
                                "кладу", "клаву"]

    /// The question after the opener, or nil when the dictation is not an "ask Claude".
    static func question(fromDictation text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for verb in verbs {
            guard lower.hasPrefix(verb) else { continue }
            var rest = lower.dropFirst(verb.count).drop(while: { $0 == " " || $0 == "," })
            guard let name = names.first(where: { rest.hasPrefix($0) }) else { continue }
            rest = rest.dropFirst(name.count)
            // The opener must end there ("клод", not "клодетта").
            if let next = rest.first, next.isLetter { continue }
            let offset = trimmed.count - rest.count
            let question = String(trimmed.dropFirst(offset))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!—–-").union(.whitespacesAndNewlines))
            guard !question.isEmpty else { return nil }
            return question.prefix(1).uppercased() + question.dropFirst()
        }
        return nil
    }
}
