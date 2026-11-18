#if os(iOS)
import Foundation

// MARK: - Chat store
//
// State for the Chat tab: history paging (GET /conversations/default/messages?before=), sending
// (POST → { messageId }), and the streamed reply arriving over the WebSocket as message.delta
// (append text) → message.done (swap in the final Message). Tool activity rides tool.started /
// tool.finished and renders as small chips under the assistant bubble.
//
// A SINGLETON: Today cards ("open chat about it") need to hand the chat a prompt, which only works
// if the Chat tab and the card share one store. Socket events come from AgentSocketHub — one
// connection for the whole app.

@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published private(set) var messages: [AgentChatMessage] = []
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var nextBefore: String?
    @Published private(set) var isSending = false
    @Published var errorMessage: String?

    /// The in-flight assistant reply: its server messageId and the text accumulated so far.
    @Published private(set) var streamingId: String?
    @Published private(set) var streamingText = ""
    /// Tool chips keyed by the messageId they belong to.
    @Published private(set) var toolChips: [String: [AgentChatMessage.ToolRef]] = [:]

    /// A prompt handed over by another screen ("open chat about it"). ChatView consumes it into
    /// the draft field rather than auto-sending, so the user can review first.
    @Published var pendingPrompt: String?

    private var subscription: UUID?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        AgentSocketHub.shared.start()
        subscription = AgentSocketHub.shared.subscribe(
            handler: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            },
            onRefetch: { [weak self] in
                Task { @MainActor in await self?.loadInitial() }
            })
        Task { await loadInitial() }
    }

    // MARK: History

    func loadInitial() async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let page: AgentMessagesPage = try await AgentAPI.shared.get("/conversations/default/messages")
            messages = Self.chronological(page.messages)
            nextBefore = page.nextBefore
            errorMessage = nil
        } catch {
            errorMessage = NutritionStore.describe(error)
        }
    }

    func loadOlder() async {
        guard let before = nextBefore, !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let page: AgentMessagesPage = try await AgentAPI.shared.get(
                "/conversations/default/messages", query: ["before": before])
            let known = Set(messages.map(\.id))
            messages = Self.chronological(page.messages.filter { !known.contains($0.id) } + messages)
            nextBefore = page.nextBefore
        } catch {
            errorMessage = NutritionStore.describe(error)
        }
    }

    /// Oldest first, the order a chat reads in, whatever order the server or the socket delivered.
    /// Stable, so same-second messages keep their arrival order; undated ones stay where they are.
    static func chronological(_ list: [AgentChatMessage]) -> [AgentChatMessage] {
        list.enumerated().sorted { a, b in
            switch (a.element.createdAt, b.element.createdAt) {
            case let (x?, y?) where x != y: return x < y
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    // MARK: Sending

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        let clientId = UUID().uuidString
        // Optimistic local echo; the server's streamed reply follows over the socket.
        messages.append(AgentChatMessage(id: "local-\(clientId)", role: "user", text: trimmed,
                                         channel: "chat", createdAt: Date(), tools: nil))
        struct Body: Encodable { let text: String; let clientId: String }
        Task {
            defer { isSending = false }
            do {
                let _: AgentSendResponse = try await AgentAPI.shared.post(
                    "/conversations/default/messages", body: Body(text: trimmed, clientId: clientId))
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }

    // MARK: Socket events

    private func handle(_ event: AgentSocketEvent) {
        struct Delta: Decodable { let messageId: String; let text: String }
        struct ToolEvent: Decodable { let messageId: String; let name: String; let label: String? }

        switch event.type {
        case "message.delta":
            if let d = event.decode(Delta.self) {
                if streamingId != d.messageId {
                    streamingId = d.messageId
                    streamingText = ""
                }
                streamingText += d.text
            }
        case "message.done":
            if let message = event.decode(AgentChatMessage.self) {
                if streamingId == message.id { streamingId = nil; streamingText = "" }
                // Replace a same-id optimistic/placeholder copy, else append in order.
                var stored = message
                if let chips = toolChips[message.id], !chips.isEmpty, stored.tools == nil {
                    stored.tools = chips
                }
                if let i = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[i] = stored
                } else {
                    messages = Self.chronological(messages + [stored])
                }
            }
        case "tool.started":
            if let t = event.decode(ToolEvent.self) {
                toolChips[t.messageId, default: []].append(.init(name: t.name, label: t.label))
            }
        case "tool.finished":
            // Chips stay visible after finishing — they record what the agent DID, not just what
            // it's doing. Nothing to update.
            break
        default:
            break
        }
    }
}
#endif
