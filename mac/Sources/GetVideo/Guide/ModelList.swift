import Foundation

/// Asks the AI service which models this key can use, so the Model box can offer them.
enum ModelList {
    /// The request for the list: GET /v1/models (Anthropic) or GET <base>/models (OpenAI and compatible).
    static func request(for options: GuideOptions, apiKey: String) throws -> URLRequest {
        let anthropic = options.provider == "anthropic"
        let base = options.effectiveBaseURL
        guard let url = URL(string: anthropic ? base + "/v1/models?limit=1000" : base + "/models"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw LLMError(message: "\"\(base)\" is not a valid address")
        }
        var r = URLRequest(url: url, timeoutInterval: 20)
        if anthropic {
            r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !apiKey.isEmpty {
            r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    /// One model the service offers. `free` is true only when the reply says so: OpenRouter gives
    /// each model's prices, and some services mark free ones with a ":free" or "-free" ending.
    struct Entry: Equatable {
        let id: String
        let free: Bool
    }

    /// Models from a list reply, in the order the service gave them (Anthropic lists newest first).
    /// Ones that cannot write text (embeddings, speech, images) are left out.
    static func entries(from data: Data) -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return [] }
        let skip = ["embed", "whisper", "tts", "dall-e", "moderation", "transcribe", "image", "audio", "realtime"]
        var seen = Set<String>()
        var out: [Entry] = []
        for item in items {
            guard var id = item["id"] as? String else { continue }
            // Gemini names its models "models/gemini-...", which its chat API also takes without the prefix.
            if id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
            let lower = id.lowercased()
            guard !skip.contains(where: lower.contains), seen.insert(id).inserted else { continue }
            var free = lower.hasSuffix(":free") || lower.hasSuffix("-free")
            if let pricing = item["pricing"] as? [String: Any], let prompt = number(pricing["prompt"]), let completion = number(pricing["completion"]) {
                free = prompt == 0 && completion == 0
            }
            out.append(Entry(id: id, free: free))
        }
        return out
    }

    static func ids(from data: Data) -> [String] { entries(from: data).map(\.id) }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func fetch(_ options: GuideOptions, apiKey: String, session: URLSession = .shared) async throws -> [Entry] {
        let data = try await LLMHTTP.send(try request(for: options, apiKey: apiKey), session: session, provider: "The AI service")
        return entries(from: data)
    }
}
