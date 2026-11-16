#if os(iOS)
import Foundation

// MARK: - Inbox store
//
// GET /inbox → the agent's triaged mail, grouped client-side into Action / FYI / Ignored.
// PATCH /inbox/{id} re-categorises ({category}) or promotes a mail to a task ({makeTask: true}).
// Live updates ride the socket's inbox.updated event.

@MainActor
final class InboxStore: ObservableObject {
    static let shared = InboxStore()

    @Published private(set) var items: [AgentEmail] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var subscription: UUID?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        AgentSocketHub.shared.start()
        subscription = AgentSocketHub.shared.subscribe(
            handler: { [weak self] event in
                guard event.type == "inbox.updated" else { return }
                Task { @MainActor in await self?.refresh() }
            },
            onRefetch: { [weak self] in
                Task { @MainActor in await self?.refresh() }
            })
        Task { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        struct Response: Decodable { let items: [AgentEmail] }
        do {
            let r: Response = try await AgentAPI.shared.get("/inbox")
            items = r.items.sorted { ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast) }
            errorMessage = nil
        } catch {
            errorMessage = NutritionStore.describe(error)
        }
    }

    /// Re-file a mail (action / fyi / ignore). Removes it from its current group on success.
    func setCategory(_ mail: AgentEmail, category: String) {
        struct Body: Encodable { let category: String }
        mutate(mail, body: Body(category: category))
    }

    /// Promote a mail to a task — the server creates the task and marks the mail handled.
    func makeTask(_ mail: AgentEmail) {
        struct Body: Encodable { let makeTask: Bool }
        mutate(mail, body: Body(makeTask: true))
    }

    private func mutate<B: Encodable>(_ mail: AgentEmail, body: B) {
        Task {
            do {
                let updated: AgentEmail = try await AgentAPI.shared.patch("/inbox/\(mail.id)", body: body)
                if let i = items.firstIndex(where: { $0.id == updated.id }) {
                    items[i] = updated
                }
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }
}
#endif
