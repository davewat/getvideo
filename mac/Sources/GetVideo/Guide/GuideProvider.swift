import Foundation

/// An AI service the guide can use. Everything but Anthropic speaks the OpenAI chat API, so a
/// provider is a name, an address and a starting model.
struct GuideProvider: Equatable {
    let id: String
    let title: String
    let baseURL: String
    let defaultModel: String

    static let all = [
        GuideProvider(id: "anthropic", title: "Anthropic", baseURL: "https://api.anthropic.com", defaultModel: "claude-sonnet-5-5"),
        GuideProvider(id: "openai", title: "OpenAI", baseURL: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini"),
        GuideProvider(id: "gemini", title: "Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: "gemini-2.5-flash"),
        GuideProvider(id: "openrouter", title: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", defaultModel: "openai/gpt-4o-mini"),
        GuideProvider(id: "nim", title: "Nvidia NIM", baseURL: "https://integrate.api.nvidia.com/v1", defaultModel: "meta/llama-3.3-70b-instruct"),
        GuideProvider(id: "opencode", title: "OpenCode Zen", baseURL: "https://opencode.ai/zen/v1", defaultModel: "kimi-k2"),
        // Earlier versions saved this one; it also serves Ollama, LM Studio and anything else that speaks the OpenAI API.
        GuideProvider(id: "openai-compatible", title: "Other (OpenAI-compatible)", baseURL: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini"),
    ]

    static func named(_ id: String) -> GuideProvider { all.first { $0.id == id } ?? all[0] }
}
