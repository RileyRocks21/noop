#if os(iOS)
import Foundation

// MARK: - Approvals store
//
// GET /approvals?status=pending → actions the agent wants permission for (send an email, make a
// purchase, post somewhere). POST /approvals/{id}/decision with {decision: approve|reject|edit,
// payload?}. `pendingCount` is published for the More-tab badge, and `approval.created` socket
// events both insert the row and bump the badge live.

@MainActor
final class ApprovalsStore: ObservableObject {
    static let shared = ApprovalsStore()

    @Published private(set) var pending: [AgentApproval] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    /// Drives the badge on the More tab.
    var pendingCount: Int { pending.count }

    private var subscription: UUID?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        AgentSocketHub.shared.start()
        subscription = AgentSocketHub.shared.subscribe(
            handler: { [weak self] event in
                guard event.type == "approval.created",
                      let approval = event.decode(AgentApproval.self) else { return }
                Task { @MainActor in
                    guard let self else { return }
                    if !self.pending.contains(where: { $0.id == approval.id }) {
                        self.pending.insert(approval, at: 0)
                    }
                }
            },
            onRefetch: { [weak self] in
                Task { @MainActor in await self?.refresh() }
            })
        Task { await refresh() }
    }

    func refresh() async {
        // Runs outside the caller's task: SwiftUI cancels a pull-to-refresh task when the list re-renders
        // mid-request, which showed up as URLError -999 instead of fresh data.
        await Task { await self.load() }.value
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        struct Response: Decodable { let approvals: [AgentApproval] }
        do {
            let r: Response = try await AgentAPI.shared.get("/approvals",
                                                            query: ["status": "pending"])
            pending = r.approvals
            errorMessage = nil
        } catch {
            if !AgentErrors.isCancellation(error) { errorMessage = NutritionStore.describe(error) }
        }
    }

    enum Decision: String {
        case approve, reject, edit
    }

    /// Approve / reject / edit-and-approve. The decided row leaves the pending list on success.
    func decide(_ approval: AgentApproval, decision: Decision, editedPayload: String? = nil) {
        struct Body: Encodable { let decision: String; let payload: String? }
        Task {
            do {
                let _: AgentApproval = try await AgentAPI.shared.post(
                    "/approvals/\(approval.id)/decision",
                    body: Body(decision: decision.rawValue,
                               payload: decision == .edit ? editedPayload : nil))
                pending.removeAll { $0.id == approval.id }
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }
}
#endif
