#if os(iOS)
import Foundation

// MARK: - Agent settings store
//
// Backs the Agent Settings screen: GET/PUT /settings (quiet hours, per-category notification
// levels, Brightspace iCal feed, market watchlist), GET /integrations (per-provider status +
// connect URL), and the /memories CRUD. Saving sends the WHOLE settings object (the contract's
// PUT semantics) — the store keeps the latest copy so a one-field edit never drops the rest.

@MainActor
final class AgentSettingsStore: ObservableObject {
    static let shared = AgentSettingsStore()

    @Published private(set) var settings = AgentSettings()
    @Published private(set) var integrations: [AgentIntegration] = []
    @Published private(set) var memories: [AgentMemory] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    /// Set briefly after a successful save so the UI can show a checkmark.
    @Published private(set) var savedTick = false

    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        AgentSocketHub.shared.start()
        Task { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        struct IntegrationsResponse: Decodable { let integrations: [AgentIntegration] }
        struct MemoriesResponse: Decodable { let memories: [AgentMemory] }
        do {
            async let s: AgentSettings = AgentAPI.shared.get("/settings")
            async let i: IntegrationsResponse = AgentAPI.shared.get("/integrations")
            async let m: MemoriesResponse = AgentAPI.shared.get("/memories")
            settings = try await s
            integrations = try await i.integrations
            memories = try await m.memories
            errorMessage = nil
        } catch {
            errorMessage = NutritionStore.describe(error)
        }
    }

    // MARK: Settings

    func save(_ updated: AgentSettings) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let saved: AgentSettings = try await AgentAPI.shared.put("/settings", body: updated)
                settings = saved
                errorMessage = nil
                savedTick = true
                try? await Task.sleep(for: .seconds(1.5))
                savedTick = false
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }

    // MARK: Memories

    func addMemory(_ text: String) {
        struct Body: Encodable { let text: String }
        Task {
            do {
                let memory: AgentMemory = try await AgentAPI.shared.post("/memories",
                                                                         body: Body(text: text))
                memories.insert(memory, at: 0)
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }

    func updateMemory(_ memory: AgentMemory, text: String? = nil, pinned: Bool? = nil) {
        struct Body: Encodable { let text: String?; let pinned: Bool? }
        Task {
            do {
                let updated: AgentMemory = try await AgentAPI.shared.patch(
                    "/memories/\(memory.id)", body: Body(text: text, pinned: pinned))
                if let i = memories.firstIndex(where: { $0.id == updated.id }) {
                    memories[i] = updated
                }
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }

    func deleteMemory(_ memory: AgentMemory) {
        Task {
            do {
                try await AgentAPI.shared.send("/memories/\(memory.id)", method: "DELETE")
                memories.removeAll { $0.id == memory.id }
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }

    // MARK: Auth requests (Live Browser)

    /// Ask the backend to open a login flow for `site`; the response carries the noVNC URL the
    /// Live Browser sheet shows. Full Live Browser polish is Step 4 — this is the minimal wrapper
    /// Settings needs for "let the agent into Brightspace".
    func requestAuth(site: String) async throws -> AgentAuthRequest {
        struct Body: Encodable { let site: String }
        return try await AgentAPI.shared.post("/auth-requests", body: Body(site: site))
    }
}
#endif
