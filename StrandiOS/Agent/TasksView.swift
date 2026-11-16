#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Tasks tab
//
// Open tasks grouped Overdue / Today / This week / Later, each with a source badge (Brightspace,
// Email, You, Agent). Add via the top bar; swipe right to complete, swipe left for snooze presets
// and priority. Live updates ride the socket's task.updated event.

struct TasksView: View {
    @ObservedObject private var config = AgentConfig.shared
    @ObservedObject private var store = TasksStore.shared
    @State private var showAdd = false
    @State private var newTitle = ""
    @State private var newDueAt: Date? = nil
    @State private var hasDue = false

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
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                HStack(spacing: 8) {
                    if let badge = sourceBadge(task.source) {
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
                        Text(priority.uppercased())
                            .font(StrandFont.overline)
                            .foregroundStyle(priority == "critical" || priority == "high"
                                             ? StrandPalette.metricRose : StrandPalette.textTertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .swipeActions(edge: .leading) {
            Button { store.complete(task) } label: {
                Label("Done", systemImage: "checkmark")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Menu("Snooze") {
                ForEach(SnoozePreset.allCases) { preset in
                    Button(preset.label) { store.snooze(task, preset: preset) }
                }
            }
            Menu("Priority") {
                ForEach(["low", "normal", "high", "critical"], id: \.self) { p in
                    Button(p.capitalized) { store.setPriority(task, priority: p) }
                }
            }
        }
    }

    private func sourceBadge(_ source: String?) -> String? {
        switch source {
        case "brightspace": return "Brightspace"
        case "email":       return "Email"
        case "agent":       return "Agent"
        case "manual":      return "You"
        default:            return nil
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
#endif
