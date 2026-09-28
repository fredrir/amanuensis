import Foundation

/// Output choices; extraction instructions live in the backend.
struct Prompt: Identifiable, Equatable {
    let id: UUID
    let name: String
    let format: String

    static let latexPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let markdownPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let latexPrompt = Prompt(id: latexPromptId, name: "LaTeX", format: "latex")
    static let markdownPrompt = Prompt(id: markdownPromptId, name: "Markdown", format: "markdown")
    static let builtInPrompts: [Prompt] = [latexPrompt, markdownPrompt]
}
