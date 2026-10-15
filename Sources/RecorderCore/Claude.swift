import Foundation

public struct ClaudeUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var requestBytes: Int = 0
    public var total: Int { inputTokens + outputTokens }
    public init(inputTokens: Int = 0, outputTokens: Int = 0, requestBytes: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.requestBytes = requestBytes
    }
}
public struct ClaudeRequest {
    public var model: String, system: String, user: String, effort: String
    public var schema: [String: Any]
    public var maxTokens: Int
    public init(model: String, system: String, user: String, schema: [String: Any], maxTokens: Int = 16000, effort: String = "medium") {
        self.model = model; self.system = system; self.user = user; self.schema = schema; self.maxTokens = maxTokens; self.effort = effort
    }
    public func body() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": model, "max_tokens": maxTokens, "fallbacks": "default",
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
            "system": system, "messages": [["role": "user", "content": user]]], options: [.sortedKeys])
    }
}
public enum ClaudeAPI {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static func send(_ request: ClaudeRequest, apiKey: String, session: URLSession = .shared) async throws -> (Data, ClaudeUsage) {
        let body = try request.body(), data = try await send(body, apiKey: apiKey, session: session)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let usage = object?["usage"] as? [String: Any] ?? [:]
        return (data, ClaudeUsage(inputTokens: usage["input_tokens"] as? Int ?? 0, outputTokens: usage["output_tokens"] as? Int ?? 0, requestBytes: body.count))
    }
    public static func send(_ body: Data,apiKey: String,session: URLSession) async throws -> Data {
        guard !apiKey.isEmpty else { throw SummaryError.missingKey }
        var request = URLRequest(url: endpoint,timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json",forHTTPHeaderField: "content-type")
        request.setValue(apiKey,forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01",forHTTPHeaderField: "anthropic-beta")
        request.httpBody = body
        let data: Data, response: URLResponse
        do { (data,response) = try await session.data(for: request) }
        catch let error as URLError where [.networkConnectionLost,.timedOut,.cannotConnectToHost,.notConnectedToInternet].contains(error.code) {
            // One retry: long requests sometimes lose the connection (Wi-Fi change, proxy).
            try await Task.sleep(nanoseconds: 2_000_000_000)
            (data,response) = try await session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw SummaryError.http(status,message ?? String(decoding: data.prefix(300),as: UTF8.self))
        }
        return data
    }
    public static func decode<T: Decodable>(_ type: T.Type,from data: Data) throws -> T {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SummaryError.invalid("kein JSON-Objekt") }
        switch object["stop_reason"] as? String {
        case "refusal": throw SummaryError.refused
        case "max_tokens": throw SummaryError.truncated
        default: break
        }
        let blocks = (object["content"] as? [[String: Any]]) ?? []
        guard let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String, !text.isEmpty else { throw SummaryError.empty }
        do { return try JSONDecoder().decode(T.self,from: Data(text.utf8)) } catch { throw SummaryError.invalid(error.localizedDescription) }
    }
}
