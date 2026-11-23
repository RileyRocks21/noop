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
    /// True from the moment a local edit is staged until the server has answered the newest one.
    /// The view only adopts `settings` while this is false, so a slow response never overwrites a
    /// newer edit.
    @Published private(set) var isDirty = false
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

    /// The newest local draft: what the user last edited if a save is still pending or on the
    /// wire, else the server copy. A view that (re)appears mid-save starts from this.
    var currentDraft: AgentSettings { saveQueue.latest ?? settings }

    /// Stage `updated` and save it after a short debounce. Latest wins: edits made while a save is
    /// in flight are held and the newest is sent as soon as that save returns, so rapid taps end
    /// on the last value instead of being dropped.
    func save(_ updated: AgentSettings) {
        saveQueue.enqueue(updated)
        isDirty = true
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.pumpSave()
        }
    }

    private static let saveDebounce: Duration = .milliseconds(600)
    private var saveQueue = AgentSaveQueue<AgentSettings>()
    private var debounceTask: Task<Void, Never>?
    private var savedTickTask: Task<Void, Never>?

    private func pumpSave() {
        guard let next = saveQueue.begin() else { return }
        isSaving = true
        Task {
            var saved: AgentSettings?
            do {
                let response: AgentSettings = try await AgentAPI.shared.put("/settings", body: next)
                saved = response
                errorMessage = nil
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
            let more = saveQueue.finish()
            if more {
                // A newer draft arrived while this one was on the wire. Send it now unless a
                // debounce is still running for it (that one will pump when it fires).
                if debounceTask == nil { pumpSave() } else { isSaving = false }
                return
            }
            isSaving = false
            // Clear the dirty flag BEFORE publishing the server copy so the view accepts it.
            isDirty = debounceTask != nil
            if let saved {
                settings = saved
                flashSaved()
            }
        }
    }

    private func flashSaved() {
        savedTickTask?.cancel()
        savedTick = true
        savedTickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.savedTick = false
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
