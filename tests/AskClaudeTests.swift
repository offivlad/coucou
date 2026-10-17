import Foundation

@main
enum AskClaudeTests {
    static func main() {
        let q = AskClaudeLogic.question(fromDictation:)
        precondition(q("Спроси Клод, какая погода в Минске?") == "Какая погода в Минске?", "ru basic")
        precondition(q("спроси у Клода что почитать про BMW") == "Что почитать про BMW", "ru у клода")
        precondition(q("Спроси Claude: напиши пост про подбор авто") == "Напиши пост про подбор авто", "latin name")
        precondition(q("Ask Claude what is a VIN") == "What is a VIN", "en")
        precondition(q("спроси клауд сколько стоит растаможка") == "Сколько стоит растаможка", "клауд")
        precondition(q("Спроси Клод") == nil, "no question")
        precondition(q("Привет, как дела") == nil, "normal dictation")
        precondition(q("Спроси Клодетту про встречу") == nil, "other name")
        precondition(q("спроси маму про ужин") == nil, "other person")
        print("AskClaudeLogic: all cases passed")
    }
}
