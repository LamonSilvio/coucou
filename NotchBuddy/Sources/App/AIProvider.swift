import Foundation

enum AIProviderID: String, CaseIterable, Codable, Sendable {
    case anthropic, openai, auto

    static func resolve(_ selected: Self, anthropic: Bool, openai: Bool) -> Self {
        selected == .auto ? (anthropic ? .anthropic : (openai ? .openai : .anthropic)) : selected
    }
}

@MainActor
protocol AIProvider: AnyObject {
    func chat(query: String, context: PromptContext?, state: AppState) async
    func clearConversation()
}

// Preserve the existing Claude implementation and its tool/history format.
extension ClaudeService: AIProvider {}

@MainActor
final class AIChatRouter {
    static let shared = AIChatRouter()
    private let providers: [AIProviderID: any AIProvider]
    private let selection: () -> AIProviderID
    init(providers: [AIProviderID: any AIProvider]? = nil, selection: (() -> AIProviderID)? = nil) {
        self.providers = providers ?? [.anthropic: ClaudeService.shared, .openai: OpenAIService.shared]
        self.selection = selection ?? {
            AIProviderID.resolve(AIProviderID(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "anthropic") ?? .anthropic,
                anthropic: !(KeychainStore.shared.get("anthropic-api-key") ?? "").isEmpty,
                openai: !(KeychainStore.shared.get("openai-api-key") ?? "").isEmpty)
        }
    }
    private var active: AIProviderID?
    private var busy = false

    var selected: AIProviderID {
        selection()
    }
    var label: String { selected == .openai ? "OpenAI" : "Claude" }

    func chat(query: String, context: PromptContext?, state: AppState) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let id = selected
        if active != id {
            providers.values.forEach { $0.clearConversation() }
            state.chatHistory = [ChatMessage(role: .user, content: query)]
            active = id
        }
        await providers[id]?.chat(query: query, context: context, state: state)
    }

    func reset() {
        guard !busy else { return }
        providers.values.forEach { $0.clearConversation() }
        AppState.shared.chatHistory = []
    }
}
