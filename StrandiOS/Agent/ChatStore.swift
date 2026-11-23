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
    /// clientIds of local messages whose POST failed. Their bubbles say "Not sent — tap to retry".
    @Published private(set) var failedClientIds: Set<String> = []

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
            messages = Self.merging(page: page.messages, keepingLocalFrom: messages)
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

    /// A fresh page, plus any local copies (still sending, or failed) the server has not saved yet:
    /// a refetch must neither drop an unsent message nor show a sent one twice.
    static func merging(page: [AgentChatMessage], keepingLocalFrom current: [AgentChatMessage]) -> [AgentChatMessage] {
        let saved = Set(page.compactMap(\.clientId))
        let pending = current.filter { m in
            guard m.id.hasPrefix("local-"), let cid = m.clientId else { return false }
            return !saved.contains(cid)
        }
        return chronological(page + pending)
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
        // Optimistic local echo; message.done (same clientId) replaces it with the saved copy.
        messages.append(AgentChatMessage(id: "local-\(clientId)", role: "user", text: trimmed,
                                         channel: "chat", createdAt: Date(), tools: nil, clientId: clientId))
        post(text: trimmed, clientId: clientId)
    }

    /// Resend a failed message with the SAME clientId: if the first POST did reach the server, it
    /// recognises the clientId and does not save or answer it twice.
    func retry(_ message: AgentChatMessage) {
        guard let clientId = message.clientId, failedClientIds.contains(clientId), !isSending else { return }
        isSending = true
        failedClientIds.remove(clientId)
        post(text: message.text, clientId: clientId)
    }

    private func post(text: String, clientId: String) {
        struct Body: Encodable { let text: String; let clientId: String }
        Task {
            defer { isSending = false }
            do {
                let response: AgentSendResponse = try await AgentAPI.shared.post(
                    "/conversations/default/messages", body: Body(text: text, clientId: clientId))
                // A recognised resend gets no message.done, so take the saved id from the response.
                if let savedId = response.userMessageId, let i = localIndex(clientId) {
                    if messages.contains(where: { $0.id == savedId }) {
                        messages.remove(at: i)
                    } else {
                        messages[i].id = savedId
                    }
                }
            } catch {
                // The bubble carries the failure ("Not sent — tap to retry"); no second banner for it.
                if localIndex(clientId) != nil { failedClientIds.insert(clientId) }
            }
        }
    }

    private func localIndex(_ clientId: String) -> Int? {
        messages.firstIndex(where: { $0.id == "local-\(clientId)" })
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
                } else if let cid = message.clientId, let i = localIndex(cid) {
                    // The saved copy of a message this app sent: replace the local echo in place.
                    messages[i] = stored
                    failedClientIds.remove(cid)
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
