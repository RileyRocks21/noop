#if os(iOS)
import Foundation

// MARK: - Tasks store
//
// GET /tasks?status=open grouped Overdue / Today / This week / Later; add (POST), complete and
// snooze (PATCH). The socket's `task.updated` event patches a single row in place so changes from
// the server appear live without a refetch.

@MainActor
final class TasksStore: ObservableObject {
    static let shared = TasksStore()

    @Published private(set) var tasks: [AgentTask] = []
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
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        struct Response: Decodable { let tasks: [AgentTask] }
        do {
            let r: Response = try await AgentAPI.shared.get("/tasks", query: ["status": "open"])
            tasks = r.tasks
            errorMessage = nil
        } catch {
            errorMessage = NutritionStore.describe(error)
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
        patch(task, body: ["status": "done"])
    }

    /// Snooze presets: +1 hour, tonight (20:00 local), tomorrow morning (08:00 local).
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

enum SnoozePreset: String, CaseIterable, Identifiable {
    case hour, tonight, tomorrow
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hour:     return String(localized: "Snooze 1 h")
        case .tonight:  return String(localized: "Tonight")
        case .tomorrow: return String(localized: "Tomorrow")
        }
    }
    func date(from now: Date) -> Date {
        let cal = Calendar.current
        switch self {
        case .hour:
            return now.addingTimeInterval(3600)
        case .tonight:
            return cal.date(bySettingHour: 20, minute: 0, second: 0, of: now)
                ?? now.addingTimeInterval(3600 * 4)
        case .tomorrow:
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
            return cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
    }
}
#endif
