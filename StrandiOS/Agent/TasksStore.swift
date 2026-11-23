#if os(iOS)
import Foundation

// MARK: - Tasks store
//
// GET /tasks?status=open grouped Overdue / Today / This week / Later; add (POST), complete, snooze
// and edit (PATCH). A completion stays undoable for a few seconds. The socket's `task.updated` event patches a single row in place so changes from
// the server appear live without a refetch.

@MainActor
final class TasksStore: ObservableObject {
    static let shared = TasksStore()

    @Published private(set) var tasks: [AgentTask] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// The task just marked done, while its Undo bar is showing.
    @Published private(set) var recentlyCompleted: AgentTask?

    /// How long the Undo bar stays up after a completion.
    static let undoWindow: TimeInterval = 5
    private var undoExpiry: Task<Void, Never>?

    private var subscription: UUID?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        AgentSocketHub.shared.start()
        subscription = AgentSocketHub.shared.subscribe(
            handler: { [weak self] event in
                guard event.type == "task.updated",
                      let task = event.decode(AgentTask.self) else { return }
                Task { @MainActor in self?.apply(task) }
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
        struct Response: Decodable { let tasks: [AgentTask] }
        do {
            let r: Response = try await AgentAPI.shared.get("/tasks", query: ["status": "open"])
            tasks = r.tasks
            errorMessage = nil
        } catch {
            if !AgentErrors.isCancellation(error) { errorMessage = NutritionStore.describe(error) }
        }
    }

    private func apply(_ task: AgentTask) {
        if task.status == "open", let i = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[i] = task
        } else if task.status == "open" {
            tasks.append(task)
        } else {
            tasks.removeAll { $0.id == task.id }
        }
    }

    // MARK: Mutations

    func add(title: String, dueAt: Date?, priority: String?) {
        struct Body: Encodable { let title: String; let dueAt: Date?; let priority: String? }
        Task {
            do {
                let task: AgentTask = try await AgentAPI.shared.post("/tasks",
                    body: Body(title: title, dueAt: dueAt, priority: priority))
                apply(task)
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }

    func complete(_ task: AgentTask) {
        Task {
            do {
                let updated: AgentTask = try await AgentAPI.shared.patch(
                    "/tasks/\(task.id)", body: StatusBody(status: "done"))
                apply(updated)
                showUndo(for: updated)
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }

    /// Reopens the task behind the Undo bar.
    func undoComplete() {
        guard let task = recentlyCompleted else { return }
        dismissUndo()
        patch(task, body: ["status": "open"])
    }

    func dismissUndo() {
        undoExpiry?.cancel()
        undoExpiry = nil
        recentlyCompleted = nil
    }

    private func showUndo(for task: AgentTask) {
        undoExpiry?.cancel()
        recentlyCompleted = task
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.undoWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.recentlyCompleted = nil
        }
    }

    private struct StatusBody: Encodable { let status: String }

    /// Edits title, due date and priority in one PATCH. Only changed fields are sent; `clearDue`
    /// sends an explicit `"dueAt": null`, which the server treats as "no due date" (an omitted key
    /// leaves the date untouched).
    func update(_ task: AgentTask, title: String?, dueAt: Date?, clearDue: Bool, priority: String? = nil) {
        let body = EditBody(title: title, dueAt: dueAt, clearDue: clearDue, priority: priority)
        guard !body.isEmpty else { return }
        Task {
            do {
                let updated: AgentTask = try await AgentAPI.shared.patch("/tasks/\(task.id)", body: body)
                apply(updated)
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }

    private struct EditBody: Encodable {
        let title: String?
        let dueAt: Date?
        let clearDue: Bool
        let priority: String?

        var isEmpty: Bool { title == nil && dueAt == nil && !clearDue && priority == nil }

        enum CodingKeys: String, CodingKey { case title, dueAt, priority }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(title, forKey: .title)
            if clearDue {
                try c.encodeNil(forKey: .dueAt)
            } else {
                try c.encodeIfPresent(dueAt, forKey: .dueAt)
            }
            try c.encodeIfPresent(priority, forKey: .priority)
        }
    }

    /// Snooze presets live in `SnoozePreset` (TaskActions.swift); each resolves after now.
    func snooze(_ task: AgentTask, preset: SnoozePreset) {
        let until = preset.date(from: Date())
        struct Body: Encodable { let status: String; let snoozeUntil: Date }
        Task {
            do {
                let updated: AgentTask = try await AgentAPI.shared.patch(
                    "/tasks/\(task.id)", body: Body(status: "snoozed", snoozeUntil: until))
                apply(updated)
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }

    func setPriority(_ task: AgentTask, priority: String) {
        patch(task, body: ["priority": priority])
    }

    private func patch(_ task: AgentTask, body: [String: String]) {
        struct AnyBody: Encodable { let fields: [String: String]
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: DynamicKey.self)
                for (k, v) in fields { try c.encode(v, forKey: .init(k)) }
            }
        }
        struct DynamicKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        Task {
            do {
                let updated: AgentTask = try await AgentAPI.shared.patch(
                    "/tasks/\(task.id)", body: AnyBody(fields: body))
                apply(updated)
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }
}
#endif
