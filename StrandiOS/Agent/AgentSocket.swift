#if os(iOS)
import Foundation

// MARK: - Agent WebSocket
//
// One URLSessionWebSocketTask to GET /ws?token=<token>. Every frame is { type, data }; frames are
// surfaced as a small value type so feature stores switch on `type` without re-parsing JSON.
// Reconnects with the contract's 1, 2, 5, 10 s backoff (held at 10 s thereafter) until told to
// stop; after a successful reconnect the owner is told to refetch whatever screen is open (the
// contract's rule for missed events).

struct AgentSocketEvent {
    let type: String
    /// The raw `data` payload as JSONSerialization saw it (dictionary/array/scalars).
    let data: Any?
    /// Convenience: decode `data` into a Codable model. Returns nil on shape mismatch.
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data,
              JSONSerialization.isValidJSONObject(data),
              let raw = try? JSONSerialization.data(withJSONObject: data) else { return nil }
        return try? AgentCoders.decoder.decode(T.self, from: raw)
    }
}

final class AgentSocket: NSObject, URLSessionWebSocketDelegate {
    /// Called on the main queue for every received frame.
    var onEvent: (AgentSocketEvent) -> Void = { _ in }
    /// Called after a drop + successful reconnect — the signal to refetch the open screen.
    var onReconnected: () -> Void = {}
    /// Called whenever the live/trying/dead state flips (drives the "offline" banner).
    var onStateChange: (Bool) -> Void = { _ in }

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var shouldRun = false
    private var attempt = 0
    /// Whether the socket has EVER connected this run — distinguishes the first connect from a
    /// reconnect (only the latter triggers a refetch).
    private var everConnected = false

    private static let backoff: [TimeInterval] = [1, 2, 5, 10]

    func connect() {
        shouldRun = true
        open()
    }

    func disconnect() {
        shouldRun = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func open() {
        guard shouldRun else { return }
        Task { @MainActor in
            guard let base = AgentConfig.shared.baseURL, let token = AgentConfig.shared.token else {
                // Not paired / no URL yet. The hub's `started` guard means nobody calls connect()
                // a second time after pairing, so bailing here left the socket dead until the app
                // was relaunched ("Offline" banner forever). Poll gently until config appears.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.open()
                }
                return
            }
            var components = URLComponents(url: base.appendingPathComponent("/ws"),
                                           resolvingAgainstBaseURL: false)
            components?.scheme = base.scheme == "https" ? "wss" : "ws"
            components?.queryItems = [URLQueryItem(name: "token", value: token)]
            guard let url = components?.url else { return }
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.webSocketTask(with: url)
            self.task = task
            task.resume()
            receive()
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive()
            case .failure:
                self.handleDrop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = frame["type"] as? String else { return }
        let event = AgentSocketEvent(type: type, data: frame["data"])
        DispatchQueue.main.async { self.onEvent(event) }
    }

    private func handleDrop() {
        DispatchQueue.main.async { self.onStateChange(false) }
        session?.invalidateAndCancel()
        session = nil
        task = nil
        guard shouldRun else { return }
        let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
        attempt += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.open()
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        let wasReconnect = everConnected
        everConnected = true
        attempt = 0
        DispatchQueue.main.async {
            self.onStateChange(true)
            if wasReconnect { self.onReconnected() }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handleDrop()
    }
}
#endif
