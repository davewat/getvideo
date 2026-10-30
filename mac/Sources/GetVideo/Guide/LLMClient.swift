import Foundation

/// Why the model could not be used; the message is shown to the user.
struct LLMError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Something that turns a prompt into text. Tests use a fake.
protocol LLMClient: Sendable {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}

/// Sends a request and retries while the service says "too many requests" (429).
enum LLMHTTP {
    static let attempts = 4

    /// Seconds to wait before the next try: what the service asks for, else 2, 4, 8, at most 30.
    @Sendable static func defaultWait(attempt: Int, response: HTTPURLResponse) -> TimeInterval {
        if let asked = response.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) { return min(max(asked, 0), 30) }
        return min(Double(1 << attempt) * 2, 30)
    }

    static func send(_ request: URLRequest, session: URLSession, provider: String,
                     wait: @Sendable (Int, HTTPURLResponse) -> TimeInterval = defaultWait) async throws -> Data {
        var attempt = 1
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch {
                throw LLMError(message: "Could not reach \(request.url?.host ?? provider): \(error.localizedDescription)")
            }
            guard let http = response as? HTTPURLResponse else { throw LLMError(message: "\(provider) gave no answer") }
            switch http.statusCode {
            case 200..<300:
                return data
            case 429 where attempt < attempts:
                try await Task.sleep(nanoseconds: UInt64(wait(attempt, http) * 1_000_000_000))
                attempt += 1
            case 401, 403:
                throw LLMError(message: "\(provider) rejected the API key (error \(http.statusCode)). Check the key in Advanced > Guide. \(detail(data))")
            case 429:
                throw LLMError(message: "\(provider) is rate limiting requests (error 429). Try again in a minute. \(detail(data))")
            default:
                throw LLMError(message: "\(provider) returned error \(http.statusCode). \(detail(data))")
            }
        }
    }

    /// The service's own explanation, from `{"error": {"message": ...}}` or `{"error": "..."}`.
    static func detail(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let e = root["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let e = root["error"] as? String { return e }
        return ""
    }
}

/// Anthropic's Messages API: POST /v1/messages.
struct AnthropicClient: LLMClient {
    var apiKey: String
    var model: String
    var baseURL = "https://api.anthropic.com"
    var session = URLSession.shared
    var wait: @Sendable (Int, HTTPURLResponse) -> TimeInterval = LLMHTTP.defaultWait

    func request(system: String, user: String, maxTokens: Int) throws -> URLRequest {
        guard let url = URL(string: baseURL + "/v1/messages") else { throw LLMError(message: "\"\(baseURL)\" is not a valid address") }
        var r = URLRequest(url: url, timeoutInterval: 300)
        r.httpMethod = "POST"
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = ["model": model, "max_tokens": maxTokens, "system": system,
                                   "messages": [["role": "user", "content": user]]]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// The reply's text blocks, joined.
    static func text(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["content"] as? [[String: Any]] else {
            throw LLMError(message: "Anthropic's reply could not be understood")
        }
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw LLMError(message: "Anthropic returned an empty reply") }
        return text
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let data = try await LLMHTTP.send(try request(system: system, user: user, maxTokens: maxTokens),
                                          session: session, provider: "Anthropic", wait: wait)
        return try Self.text(from: data)
    }
}

/// OpenAI's chat API and the many services that copy it (OpenRouter, Ollama, LM Studio, NIM):
/// POST <base URL>/chat/completions.
struct OpenAICompatClient: LLMClient {
    var apiKey: String
    var model: String
    var baseURL = "https://api.openai.com/v1"
    var session = URLSession.shared
    var wait: @Sendable (Int, HTTPURLResponse) -> TimeInterval = LLMHTTP.defaultWait

    /// Newer OpenAI models take `max_completion_tokens` and refuse `max_tokens`.
    func request(system: String, user: String, maxTokens: Int, newTokenField: Bool = false) throws -> URLRequest {
        guard let url = URL(string: baseURL + "/chat/completions") else { throw LLMError(message: "\"\(baseURL)\" is not a valid address") }
        var r = URLRequest(url: url, timeoutInterval: 300)
        r.httpMethod = "POST"
        if !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = ["model": model, newTokenField ? "max_completion_tokens" : "max_tokens": maxTokens,
                                   "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    static func text(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first,
              let text = (choice["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else {
            throw LLMError(message: "The AI service's reply could not be understood")
        }
        return text
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        do {
            let data = try await LLMHTTP.send(try request(system: system, user: user, maxTokens: maxTokens),
                                              session: session, provider: "The AI service", wait: wait)
            return try Self.text(from: data)
        } catch let e as LLMError where e.message.contains("max_completion_tokens") {
            let data = try await LLMHTTP.send(try request(system: system, user: user, maxTokens: maxTokens, newTokenField: true),
                                              session: session, provider: "The AI service", wait: wait)
            return try Self.text(from: data)
        }
    }
}

extension GuideOptions {
    /// The client for these options and this API key.
    func makeClient(apiKey: String) -> LLMClient {
        provider == "anthropic"
            ? AnthropicClient(apiKey: apiKey, model: effectiveModel, baseURL: effectiveBaseURL)
            : OpenAICompatClient(apiKey: apiKey, model: effectiveModel, baseURL: effectiveBaseURL)
    }
}
