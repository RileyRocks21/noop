#if os(iOS)
import Foundation

// MARK: - Agent REST client
//
// Thin async layer over URLSession for the noop-agent contract. Every request carries
// `Authorization: Bearer <token>` (except /health and /auth/pair, which predate pairing); a 401
// clears the token through AgentConfig.handleUnauthorized, which is what returns the app to the
// Pairing screen. Decoding uses the shared ISO-8601 coders (AgentCoders).

enum AgentAPIError: LocalizedError {
    case noServerURL
    case notPaired
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noServerURL:        return "No server URL set — add one under Server settings."
        case .notPaired:          return "Not paired with the backend."
        case .http(let code, let body):
            return body.isEmpty ? "Server returned HTTP \(code)." : "HTTP \(code): \(body)"
        }
    }
}

final class AgentAPI {
    static let shared = AgentAPI()
    private init() {}

    private let session = URLSession(configuration: .default)

    // MARK: - Typed verbs

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send(path, method: "GET", query: query, body: nil as Data?)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await send(path, method: "POST", body: AgentCoders.encoder.encode(body))
    }

    func post<T: Decodable>(_ path: String) async throws -> T {
        try await send(path, method: "POST", body: nil as Data?)
    }

    func patch<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await send(path, method: "PATCH", body: AgentCoders.encoder.encode(body))
    }

    func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await send(path, method: "PUT", body: AgentCoders.encoder.encode(body))
    }

    func delete<T: Decodable>(_ path: String) async throws -> T {
        try await send(path, method: "DELETE", body: nil as Data?)
    }

    /// Untyped variant for endpoints whose `{ ok }` we don't care to decode.
    func send(_ path: String, method: String) async throws {
        let _: AgentHealthResponse = try await send(path, method: method, body: nil as Data?)
    }

    // MARK: - Core

    private func send<T: Decodable>(_ path: String, method: String,
                                    query: [String: String] = [:],
                                    body: Data?) async throws -> T {
        let config = await MainActor.run { AgentConfig.shared }
        let (base, token) = await MainActor.run { (config.baseURL, config.token) }
        guard let base else { throw AgentAPIError.noServerURL }

        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw AgentAPIError.noServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // /health and /auth/pair are pre-pairing endpoints; sending a nil header is a no-op, so this
        // one line serves both authed and unauthed calls.
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        // A 401 normally means the device token is dead — but on /auth/pair it means "bad or
        // expired code", which must reach the user verbatim, not be masked as "not paired"
        // (and must not clear a token that pairing doesn't even use).
        if status == 401 && path != "/auth/pair" {
            await MainActor.run { config.handleUnauthorized() }
            throw AgentAPIError.notPaired
        }
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AgentAPIError.http(status, String(text.prefix(300)))
        }
        return try AgentCoders.decoder.decode(T.self, from: data)
    }
}
#endif
