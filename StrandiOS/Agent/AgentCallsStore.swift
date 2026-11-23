#if os(iOS)
import Foundation

// MARK: - Phone calls store
//
// Backs the "Phone calls" part of Agent Settings: GET/PUT /calls/settings (wake-up call times per
// weekday, urgent calls, task reminders, call quiet hours), POST /calls/test, and GET /calls (recent
// call history). Saving follows AgentSettingsStore: a debounced, latest-wins PUT of the whole draft
// (AgentSaveQueue), and the view only adopts the server copy while no local edit is waiting.

@MainActor
final class AgentCallsStore: ObservableObject {
    static let shared = AgentCallsStore()

    enum TestState: Equatable {
        case idle
        case placing
        /// The server accepted it; the phone should ring within a few seconds.
        case ringing
        case failed(String)
    }

    @Published private(set) var status: AgentCallSettingsResponse?
    @Published private(set) var calls: [AgentCall] = []
    @Published private(set) var isDirty = false
    @Published private(set) var testState: TestState = .idle
    @Published var errorMessage: String?

    private var started = false
    private var subscription: UUID?
    private var saveQueue = AgentSaveQueue<AgentCallSettings>()
    private var debounceTask: Task<Void, Never>?
    private var testResetTask: Task<Void, Never>?
    private static let saveDebounce: Duration = .milliseconds(600)

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        AgentSocketHub.shared.start()
        subscription = AgentSocketHub.shared.subscribe(
            handler: { [weak self] event in
                guard event.type == "calls.updated" else { return }
                Task { @MainActor in await self?.refreshCalls() }
            },
            onRefetch: { [weak self] in
                Task { @MainActor in await self?.refresh() }
            })
        Task { await refresh() }
    }

    func refresh() async {
        do {
            async let s: AgentCallSettingsResponse = AgentAPI.shared.get("/calls/settings")
            async let c: AgentCallsPage = AgentAPI.shared.get("/calls", query: ["limit": "20"])
            let (settings, page) = try await (s, c)
            if !isDirty { status = settings }
            calls = page.calls
            errorMessage = nil
        } catch {
            guard !AgentErrors.isCancellation(error) else { return }
            errorMessage = NutritionStore.describe(error)
        }
    }

    func refreshCalls() async {
        do {
            let page: AgentCallsPage = try await AgentAPI.shared.get("/calls", query: ["limit": "20"])
            calls = page.calls
        } catch {
            guard !AgentErrors.isCancellation(error) else { return }
            errorMessage = NutritionStore.describe(error)
        }
    }

    // MARK: Settings

    /// The newest local draft (a pending or in-flight edit), else the server copy.
    var currentDraft: AgentCallSettings { saveQueue.latest ?? status?.settings ?? AgentCallSettings() }

    func save(_ updated: AgentCallSettings) {
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

    private func pumpSave() {
        guard let next = saveQueue.begin() else { return }
        Task {
            var saved: AgentCallSettingsResponse?
            do {
                let response: AgentCallSettingsResponse = try await AgentAPI.shared.put("/calls/settings", body: next)
                saved = response
                errorMessage = nil
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
            if saveQueue.finish() {
                if debounceTask == nil { pumpSave() }
                return
            }
            isDirty = debounceTask != nil
            if let saved { status = saved }
        }
    }

    // MARK: Test call

    func callMeNow() {
        guard testState != .placing else { return }
        testState = .placing
        Task {
            do {
                let _: AgentHealthResponse = try await AgentAPI.shared.post("/calls/test")
                testState = .ringing
            } catch AgentAPIError.http(let code, _) where code == 429 {
                testState = .failed(String(localized: "Wait a minute before another test call."))
            } catch AgentAPIError.http(let code, _) where code == 503 {
                testState = .failed(String(localized: "Phone calls aren't set up on the server yet."))
            } catch {
                testState = .failed(NutritionStore.describe(error))
            }
            testResetTask?.cancel()
            testResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.testState = .idle
            }
            await refreshCalls()
        }
    }
}
#endif
