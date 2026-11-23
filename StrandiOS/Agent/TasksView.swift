#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Tasks tab
//
// Open tasks grouped Overdue / Today / This week / Later, each with a source badge (Brightspace,
// Email, You, Agent). Add via the top bar. The round check completes a task (with a short Undo);
// long-press offers snooze, priority and edit; tapping a row opens the detail sheet. The rows live in
// a ScrollView, not a List, so nothing here relies on swipe actions. Live updates ride the socket's
// task.updated event.

struct TasksView: View {
    @ObservedObject private var config = AgentConfig.shared
    @ObservedObject private var store = TasksStore.shared
    @State private var showAdd = false
    @State private var newTitle = ""
    @State private var newDueAt: Date? = nil
    @State private var hasDue = false
    @State private var selected: AgentTask?

    private enum Group: String {
        case overdue = "OVERDUE", today = "TODAY", thisWeek = "THIS WEEK", later = "LATER"
    }

    var body: some View {
        if config.isPaired {
            content
                .onAppear { store.start() }
        } else {
            PairingView()
        }
    }

    private var content: some View {
        ScreenScaffold(title: "Tasks",
                       subtitle: "\(store.tasks.count) open",
                       onRefresh: { await store.refresh() },
                       topBackground: liquidScaffoldSky(),
                       trailing: {
                           Button { showAdd = true } label: {
                               Image(systemName: "plus.circle.fill")
                                   .font(.system(size: 20, weight: .semibold))
                                   .foregroundStyle(StrandPalette.accent)
                           }
                           .accessibilityLabel("Add task")
                       }) {
            if let error = store.errorMessage {
                DataPendingNote(title: "Tasks", message: LocalizedStringKey(error),
                                symbol: "exclamationmark.triangle.fill")
            }
            ForEach([Group.overdue, .today, .thisWeek, .later], id: \.rawValue) { group in
                let rows = tasks(in: group)
                if !rows.isEmpty {
                    groupCard(group, rows: rows)
                }
            }
            if store.tasks.isEmpty && !store.isLoading {
                Text("Nothing open. Add a task with + or ask the agent in Chat.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(item: $selected) { task in
            TaskDetailSheet(task: task, store: store)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let done = store.recentlyCompleted {
                undoBar(done)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.recentlyCompleted?.id)
    }

    private func undoBar(_ task: AgentTask) -> some View {
        HStack(spacing: 12) {
            Text("Marked done: \(task.title)")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
            Spacer()
            Button("Undo") { store.undoComplete() }
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
            .fill(StrandPalette.surfaceOverlay))
        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
            .stroke(StrandPalette.hairline, lineWidth: 1))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    // MARK: - Grouping

    private func tasks(in group: Group) -> [AgentTask] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let endOfWeek = cal.date(byAdding: .day, value: 7, to: startOfToday) ?? now
        return store.tasks
            .filter { task in
                guard let due = task.dueAt else { return group == .later }
                switch group {
                case .overdue:  return due < now
                case .today:    return due >= now && due < startOfTomorrow
                case .thisWeek: return due >= startOfTomorrow && due < endOfWeek
                case .later:    return due >= endOfWeek
                }
            }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    private func groupCard(_ group: Group, rows: [AgentTask]) -> some View {
        NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(group.rawValue)
                    .strandOverline()
                    .foregroundStyle(group == .overdue ? StrandPalette.metricRose
                                                       : StrandPalette.textTertiary)
                    .padding(16)
                ForEach(rows) { task in
                    taskRow(task)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                                .padding(.leading, 16)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
    }

    private func taskRow(_ task: AgentTask) -> some View {
        HStack(spacing: 12) {
            Button { store.complete(task) } label: {
                Image(systemName: "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark done")

            Button { selected = task } label: {
                HStack(spacing: 10) {
                    TaskRowLabel(task: task)
                    Spacer()
                    if TaskLinks.firstURL(in: task.notes) != nil {
                        Image(systemName: "link")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button { store.complete(task) } label: {
                Label("Mark done", systemImage: "checkmark.circle")
            }
            Menu {
                ForEach(SnoozePreset.available(at: Date())) { preset in
                    Button(preset.label) { store.snooze(task, preset: preset) }
                }
            } label: {
                Label("Snooze", systemImage: "moon.zzz")
            }
            Menu {
                ForEach(TaskLabels.all, id: \.self) { p in
                    Button(TaskLabels.label(p)) { store.setPriority(task, priority: p) }
                }
            } label: {
                Label("Priority", systemImage: "flag")
            }
            Button { selected = task } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
    }

    // MARK: - Add sheet

    private var addSheet: some View {
        NavigationStack {
            Form {
                TextField("Task title", text: $newTitle)
                Toggle("Has a due date", isOn: $hasDue)
                if hasDue {
                    DatePicker("Due", selection: Binding(
                        get: { newDueAt ?? Date().addingTimeInterval(3600) },
                        set: { newDueAt = $0 }))
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        store.add(title: newTitle, dueAt: hasDue ? (newDueAt ?? Date().addingTimeInterval(3600)) : nil,
                                  priority: nil)
                        newTitle = ""
                        hasDue = false
                        showAdd = false
                    }
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Row label

/// Title plus the source / due / priority line, shared by the list row.
private struct TaskRowLabel: View {
    let task: AgentTask

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.leading)
            HStack(spacing: 8) {
                if let badge = TaskLabels.sourceBadge(task.source) {
                    Text(badge.uppercased())
                        .font(StrandFont.overline)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(StrandPalette.surfaceInset))
                }
                if let due = task.dueAt {
                    Text(due, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if let priority = task.priority, priority != "normal" {
                    Text(TaskLabels.label(priority).uppercased())
                        .font(StrandFont.overline)
                        .foregroundStyle(priority == "critical" || priority == "high"
                                         ? StrandPalette.metricRose : StrandPalette.textTertiary)
                }
            }
        }
    }
}

/// Priority values the server accepts, plus display labels for priorities and task sources.
enum TaskLabels {
    static let all = ["low", "normal", "high", "critical"]

    static func label(_ priority: String) -> String {
        switch priority {
        case "low":      return String(localized: "Low")
        case "high":     return String(localized: "High")
        case "critical": return String(localized: "Critical")
        default:         return String(localized: "Normal")
        }
    }

    static func sourceBadge(_ source: String?) -> String? {
        switch source {
        case "brightspace": return String(localized: "Brightspace")
        case "email":       return String(localized: "Email")
        case "agent":       return String(localized: "Agent")
        case "manual":      return String(localized: "You")
        default:            return nil
        }
    }
}

// MARK: - Detail sheet

/// Everything a task offers in one place: edit title, due date and priority, read the notes, open the
/// link they carry, mark done or snooze.
struct TaskDetailSheet: View {
    let task: AgentTask
    @ObservedObject var store: TasksStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var title: String
    @State private var noDue: Bool
    @State private var due: Date
    @State private var priority: String

    init(task: AgentTask, store: TasksStore) {
        self.task = task
        _store = ObservedObject(wrappedValue: store)
        _title = State(initialValue: task.title)
        _noDue = State(initialValue: task.dueAt == nil)
        _due = State(initialValue: task.dueAt ?? SnoozePreset.tomorrow.date(from: Date()))
        _priority = State(initialValue: task.priority ?? "normal")
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var link: URL? { TaskLinks.firstURL(in: task.notes) }
    private var notesText: String? { TaskLinks.displayText(for: task.notes) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Task title", text: $title, axis: .vertical)
                }
                Section {
                    Toggle("No due date", isOn: $noDue)
                    if !noDue {
                        DatePicker("Due", selection: $due)
                    }
                    Picker("Priority", selection: $priority) {
                        ForEach(TaskLabels.all, id: \.self) { p in
                            Text(TaskLabels.label(p)).tag(p)
                        }
                    }
                }
                if notesText != nil || link != nil {
                    Section("Notes") {
                        if let notesText {
                            Text(notesText)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .textSelection(.enabled)
                        }
                        if let link {
                            Button {
                                openURL(link)
                            } label: {
                                Label(task.source == "brightspace" ? LocalizedStringKey("Open in Brightspace")
                                                                   : LocalizedStringKey("Open link"),
                                      systemImage: "arrow.up.right.square")
                            }
                        }
                    }
                }
                Section {
                    Button {
                        store.complete(task)
                        dismiss()
                    } label: {
                        Label("Mark done", systemImage: "checkmark.circle")
                    }
                    Menu {
                        ForEach(SnoozePreset.available(at: Date())) { preset in
                            Button(preset.label) {
                                store.snooze(task, preset: preset)
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Snooze", systemImage: "moon.zzz")
                    }
                }
            }
            .navigationTitle("Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(trimmedTitle.isEmpty)
                }
            }
        }
    }

    /// Sends only what changed.
    private func save() {
        let newTitle = trimmedTitle != task.title ? trimmedTitle : nil
        let clearDue = noDue && task.dueAt != nil
        let newDue: Date? = (!noDue && due != task.dueAt) ? due : nil
        let newPriority = priority != (task.priority ?? "normal") ? priority : nil
        store.update(task, title: newTitle, dueAt: newDue, clearDue: clearDue, priority: newPriority)
    }
}
#endif
