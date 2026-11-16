#if os(iOS)
import Foundation

// MARK: - Agent socket hub
//
// ONE WebSocket to /ws for the whole app. Feature stores (Chat, Today, Tasks, Approvals) each
// subscribe with a handler instead of opening their own connection. Reconnects with the contract's
// 1/2/5/10 s backoff; after a reconnect every subscriber is told to refetch its open screen (the
// contract's rule for events missed while disconnected).

@MainActor
final class AgentSocketHub: ObservableObject {
    static let shared = AgentSocketHub()

    /// Drives the "offline" banner on agent screens.
    @Published private(set) var isOnline = false

    private let socket = AgentSocket()
    private var handlers: [UUID: (AgentSocketEvent) -> Void] = [:]
    private var refetchHandlers: [UUID: () -> Void] = [:]
    private var started = false

    private init() {}

    /// Idempotent. Called from agent screens' onAppear; safe to call from several.
    func start() {
        guard !started else { return }
        started = true
        socket.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handlers.values.forEach { $0(event) }
            }
        }
        socket.onStateChange = { [weak self] online in
            Task { @MainActor in self?.isOnline = online }
        }
        socket.onReconnected = { [weak self] in
            Task { @MainActor in
                self?.refetchHandlers.values.forEach { $0() }
            }
        }
        socket.connect()
    }

    /// Subscribe to every socket event. Returns a token for `unsubscribe`.
    @discardableResult
    func subscribe(handler: @escaping (AgentSocketEvent) -> Void,
                   onRefetch: (() -> Void)? = nil) -> UUID {
        let id = UUID()
        handlers[id] = handler
        if let onRefetch { refetchHandlers[id] = onRefetch }
        return id
    }

    func unsubscribe(_ id: UUID) {
        handlers.removeValue(forKey: id)
        refetchHandlers.removeValue(forKey: id)
    }
}
#endif
