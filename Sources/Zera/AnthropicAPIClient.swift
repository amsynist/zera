import Foundation

// MARK: - Anthropic Messages API (optional fallback)
//
// Only used when the user chose "Anthropic API" in Settings → Claude and pasted a key. The key
// lives in the Keychain and is only ever sent to api.anthropic.com. Requests stream (SSE) so
// the result panel fills in as Claude writes.

struct APIContentBlock {
    enum Kind { case text(String), imageBase64(media: String, data: String), pdfBase64(data: String) }
    var kind: Kind

    var json: [String: Any] {
        switch kind {
        case .text(let t): return ["type": "text", "text": t]
        case .imageBase64(let media, let data):
            return ["type": "image", "source": ["type": "base64", "media_type": media, "data": data]]
        case .pdfBase64(let data):
            return ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": data]]
        }
    }
}

struct APIMessage {
    var role: String          // "user" | "assistant"
    var content: [APIContentBlock]
    var json: [String: Any] { ["role": role, "content": content.map { $0.json }] }
}

enum AnthropicAPIError: LocalizedError {
    case noKey
    case http(Int, String)
    case network(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .noKey: return "No API key configured."
        case .http(let code, let msg): return code == 401 || code == 403 ? "Claude API authentication failed." : "Claude API error \(code): \(msg)"
        case .network(let m): return "Claude couldn't be reached. \(m)"
        case .malformed: return "Claude returned something I couldn't read."
        }
    }

    var kind: ClaudeFailureKind {
        switch self {
        case .noKey: return .authentication
        case .http(let code, _): return (code == 401 || code == 403) ? .authentication : (code == 429 || code >= 500 ? .network : .other)
        case .network: return .network
        case .malformed: return .malformed
        }
    }
}

final class AnthropicAPIClient {
    static let shared = AnthropicAPIClient()
    static let defaultModel = "claude-sonnet-4-5"
    private static let modelKey = "zera.api.model"
    private static let modelsCacheKey = "zera.api.models"

    private let base = URL(string: "https://api.anthropic.com")!
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 600
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private init() {}

    var isConfigured: Bool { KeychainStore.has(.apiKey) }

    var model: String {
        get { UserDefaults.standard.string(forKey: Self.modelKey) ?? Self.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: Self.modelKey) }
    }

    /// Models the last successful "Test connection" returned (ids only).
    var knownModels: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.modelsCacheKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.modelsCacheKey) }
    }

    private func request(_ path: String, key: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue("Zera", forHTTPHeaderField: "user-agent")
        return r
    }

    /// Cheap check: lists models (no tokens spent). Returns the model ids.
    func testConnection(key: String? = nil) async throws -> [String] {
        guard let k = key ?? KeychainStore.read(.apiKey), !k.isEmpty else { throw AnthropicAPIError.noKey }
        var r = request("v1/models", key: k)
        r.httpMethod = "GET"
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: r) } catch { throw AnthropicAPIError.network(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AnthropicAPIError.http(code, Self.errorMessage(data)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { throw AnthropicAPIError.malformed }
        let ids = list.compactMap { $0["id"] as? String }
        knownModels = ids
        return ids
    }

    private static func errorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any], let m = err["message"] as? String { return m }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    /// Streams a reply. Cancel by cancelling the surrounding Task.
    func stream(system: String, messages: [APIMessage], maxTokens: Int) -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = KeychainStore.read(.apiKey), !key.isEmpty else { throw AnthropicAPIError.noKey }
                    var r = request("v1/messages", key: key)
                    r.httpMethod = "POST"
                    let body: [String: Any] = ["model": model, "max_tokens": maxTokens, "stream": true,
                                               "system": system, "messages": messages.map { $0.json }]
                    r.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
                    do { (bytes, resp) = try await session.bytes(for: r) } catch { throw AnthropicAPIError.network(error.localizedDescription) }
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code != 200 {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        throw AnthropicAPIError.http(code, Self.errorMessage(data))
                    }
                    var full = ""
                    var dataLine = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.hasPrefix("data:") {
                            dataLine = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        } else if line.isEmpty, !dataLine.isEmpty {
                            defer { dataLine = "" }
                            guard let d = dataLine.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                                  let type = obj["type"] as? String else { continue }
                            switch type {
                            case "content_block_delta":
                                if let delta = obj["delta"] as? [String: Any], (delta["type"] as? String) == "text_delta",
                                   let t = delta["text"] as? String {
                                    full += t
                                    continuation.yield(.textDelta(t))
                                }
                            case "error":
                                let err = obj["error"] as? [String: Any]
                                let msg = err?["message"] as? String ?? "unknown error"
                                let etype = err?["type"] as? String ?? ""
                                throw etype.contains("authentication") ? AnthropicAPIError.http(401, msg)
                                    : (etype.contains("overloaded") ? AnthropicAPIError.http(529, msg) : AnthropicAPIError.http(500, msg))
                            default: break   // message_start, ping, content_block_start/stop, message_delta/stop
                            }
                        }
                    }
                    continuation.yield(.completed(result: full, sessionID: nil, costUSD: nil, turns: 1))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
