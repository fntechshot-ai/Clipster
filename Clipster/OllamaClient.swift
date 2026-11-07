import Foundation

/// Abstraction over a local inference provider so another backend could be
/// added later without touching the UI.
protocol AIProvider {
    func listModels() async throws -> [AIModel]
    func chatStream(model: String,
                    messages: [AIChatMessage],
                    imagesPNG: [Data]) -> AsyncThrowingStream<String, Error>
}

struct AIModel: Identifiable, Equatable {
    var name: String
    var capabilities: [String]
    var isCloudBacked: Bool
    var id: String { name }
    var supportsVision: Bool { capabilities.contains("vision") }
}

struct AIChatMessage: Codable, Equatable {
    var role: String   // "system" | "user" | "assistant"
    var content: String
    var images: [String]? // base64 PNG, vision models only

    init(role: String, content: String, images: [String]? = nil) {
        self.role = role
        self.content = content
        self.images = images
    }
}

enum AIError: LocalizedError, Equatable {
    case notConfigured
    case nonLoopbackEndpoint
    case serverUnreachable
    case httpError(Int)
    case invalidResponse(String)
    case modelError(String)
    case inputTooLong(Int)
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Local AI is not configured. Choose a model in Settings → AI."
        case .nonLoopbackEndpoint:
            return "Only loopback endpoints (127.0.0.1 / localhost) are allowed."
        case .serverUnreachable:
            return "Could not reach the local AI server. Is Ollama running? Start it with “ollama serve” or open the Ollama app."
        case .httpError(let code):
            return code == 404
                ? "The selected model is not installed on the local server."
                : "The local AI server returned HTTP \(code)."
        case .invalidResponse(let detail):
            return "Unexpected response from the local AI server\(detail.isEmpty ? "." : ": \(detail)")"
        case .modelError(let message):
            return message
        case .inputTooLong(let count):
            return "The selected content is too long for a single request (\(count) characters, limit \(AILimits.maxInputCharacters)). Copy a smaller selection and retry."
        case .imageTooLarge:
            return "The image is too large to send to the local model. Capture a smaller area and retry."
        }
    }
}

/// Minimal client for Ollama's native HTTP API (`/api/tags`, `/api/chat`).
/// Loopback-only: non-loopback endpoints are rejected up front and redirects
/// away from loopback are refused mid-flight.
final class OllamaClient: NSObject, AIProvider {
    let baseURL: URL
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = AILimits.requestTimeout
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    static let defaultEndpoint = "http://127.0.0.1:11434"

    init?(endpoint: String) {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)),
              OllamaClient.isLoopbackURL(url) else { return nil }
        self.baseURL = url
    }

    static func isLoopbackURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        // Any 127.0.0.0/8 address is loopback.
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 127
    }

    /// Heuristic for models that a local server proxies to a remote/cloud backend.
    /// A localhost URL alone does not prove inference is local.
    static func isCloudBackedName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix("-cloud") || lower.hasSuffix(":cloud") || lower.contains("-cloud:")
    }

    // MARK: - Models

    func listModels() async throws -> [AIModel] {
        struct TagsResponse: Decodable {
            struct Model: Decodable {
                let name: String
                let capabilities: [String]?
            }
            let models: [Model]
        }
        let url = baseURL.appendingPathComponent("api/tags")
        let data: Data
        do {
            let (d, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse("") }
            guard http.statusCode == 200 else { throw AIError.httpError(http.statusCode) }
            data = d
        } catch let e as AIError {
            throw e
        } catch {
            throw AIError.serverUnreachable
        }
        return try Self.parseModels(data)
    }

    static func parseModels(_ data: Data) throws -> [AIModel] {
        struct TagsResponse: Decodable {
            struct Model: Decodable {
                let name: String
                let capabilities: [String]?
            }
            let models: [Model]
        }
        guard let parsed = try? JSONDecoder().decode(TagsResponse.self, from: data) else {
            throw AIError.invalidResponse("could not parse model list")
        }
        return parsed.models.map {
            AIModel(name: $0.name,
                    capabilities: $0.capabilities ?? [],
                    isCloudBacked: isCloudBackedName($0.name))
        }
    }

    func version() async throws -> String {
        let url = baseURL.appendingPathComponent("api/version")
        do {
            let (data, _) = try await session.data(from: url)
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (obj?["version"] as? String) ?? "unknown"
        } catch {
            throw AIError.serverUnreachable
        }
    }

    // MARK: - Chat (streaming)

    func chatStream(model: String,
                    messages: [AIChatMessage],
                    imagesPNG: [Data] = []) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var msgs = messages
                    if !imagesPNG.isEmpty, var last = msgs.popLast() {
                        last.images = imagesPNG.map { $0.base64EncodedString() }
                        msgs.append(last)
                    }
                    let body: [String: Any] = [
                        "model": model,
                        "messages": msgs.map { m -> [String: Any] in
                            var d: [String: Any] = ["role": m.role, "content": m.content]
                            if let images = m.images { d["images"] = images }
                            return d
                        },
                        "stream": true,
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIError.invalidResponse("")
                    }
                    guard http.statusCode == 200 else {
                        // Error bodies are small JSON objects; read them for the message.
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line }
                        if let detail = Self.parseErrorBody(errBody) {
                            throw AIError.modelError(detail)
                        }
                        throw AIError.httpError(http.statusCode)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty else { continue }
                        let chunk = try Self.parseChatLine(line)
                        if !chunk.content.isEmpty {
                            continuation.yield(chunk.content)
                        }
                        if chunk.done { break }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let e as AIError {
                    continuation.finish(throwing: e)
                } catch let e as URLError where e.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let e as URLError where e.code == .cannotConnectToHost || e.code == .cannotFindHost || e.code == .networkConnectionLost {
                    continuation.finish(throwing: AIError.serverUnreachable)
                } catch {
                    continuation.finish(throwing: AIError.invalidResponse(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct ChatChunk: Equatable {
        var content: String
        var done: Bool
    }

    /// Parses one NDJSON line from `/api/chat`.
    static func parseChatLine(_ line: String) throws -> ChatChunk {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse("malformed stream line")
        }
        if let err = obj["error"] as? String {
            throw AIError.modelError(err)
        }
        let message = obj["message"] as? [String: Any]
        let content = (message?["content"] as? String) ?? ""
        let done = (obj["done"] as? Bool) ?? false
        return ChatChunk(content: content, done: done)
    }

    static func parseErrorBody(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? String else { return nil }
        return err
    }
}

/// Refuses HTTP redirects that would leave loopback.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, OllamaClient.isLoopbackURL(url) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
