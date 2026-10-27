import Foundation
import FoundationModels

/// On-device Apple Intelligence. Message text never leaves the iPhone.
enum Intelligence {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func summarize(chat: String, lines: [String]) async -> String? {
        guard isAvailable, !lines.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: """
            You summarize group chat messages for someone catching up. Be brief: 2-4 short sentences or bullet points. \
            Mention who said what when it matters. Never invent facts.
            """)
        let transcript = lines.suffix(120).joined(separator: "\n")
        return try? await session.respond(to: "Summarize the recent messages in \"\(chat)\":\n\n\(transcript)").content
    }

    @Generable
    struct Replies {
        @Guide(description: "Three short, natural reply suggestions in the user's voice", .count(3))
        var suggestions: [String]
    }

    static func replies(lines: [String]) async -> [String] {
        guard isAvailable, !lines.isEmpty else { return [] }
        let session = LanguageModelSession(instructions: "Suggest brief replies (under 8 words) that 'Me' could send next. Match the tone of the chat.")
        let r = try? await session.respond(to: lines.joined(separator: "\n"), generating: Replies.self)
        return r?.content.suggestions ?? []
    }
}
