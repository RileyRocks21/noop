#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Jarvis card on Today
//
// The agent's slice of the health app's Today screen: the morning brief, what's due next (school items
// and dated tasks, merged), today's best run window, and anything waiting on an approval. Each part taps
// through into the Jarvis tab, so Today stays a glance and Jarvis stays the place to act.
//
// It deliberately shows NO health or calorie numbers. Today already shows recovery, sleep and burn from
// the strap; the agent's copies come from Whoop's cloud and can differ, and two readouts of one fact
// must not be able to disagree.
//
// Pinned above Today's reorderable block, beside the health-alert banner, on both the liquid and the
// classic Today, and only for the current day. It is not a reorderable section: the section order is a
// byte-identical key shared with Android, which has no agent.

struct JarvisTodayCard: View {
    @ObservedObject private var config = AgentConfig.shared
    @ObservedObject private var hub = AgentSocketHub.shared
    @ObservedObject private var today = AgentTodayStore.shared
    @ObservedObject private var tasks = TasksStore.shared
    @ObservedObject private var approvals = ApprovalsStore.shared

    var body: some View {
        if config.isPaired {
            card
                .onAppear {
                    today.start()
                    tasks.start()
                    approvals.start()
                }
        } else {
            connectRow
        }
    }

    // MARK: Unpaired

    private var connectRow: some View {
        Button {
            AgentNav.openJarvis(.chat)
        } label: {
            NoopCard {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect Jarvis")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Pair with your server to see your brief and reminders here.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Paired

    private var card: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let brief = today.today?.brief { briefBlock(brief) }
                if !upNext.isEmpty { upNextBlock }
                if let window = today.today?.weather?.bestRunWindow { runWindowRow(window) }
                if approvals.pendingCount > 0 { approvalsRow }
                if isEmpty {
                    Text("Nothing on deck. Ask Jarvis anything.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private var isEmpty: Bool {
        today.today?.brief == nil && upNext.isEmpty
            && today.today?.weather?.bestRunWindow == nil && approvals.pendingCount == 0
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
            Text("JARVIS").strandOverline()
            if !hub.isOnline {
                Text("Offline")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            Button {
                AgentNav.openJarvis(.chat)
            } label: {
                Label("Ask", systemImage: "bubble.left.fill")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
            Button {
                VoiceCallStore.shared.start()
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .padding(.leading, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Call Jarvis"))
        }
    }

    // MARK: Brief

    private func briefBlock(_ brief: AgentBrief) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                AgentNav.openChat(about: "Tell me more about today's brief.")
            } label: {
                Text(brief.script)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if brief.audioUrl != nil {
                Button {
                    today.toggleBriefAudio()
                } label: {
                    Image(systemName: today.isPlayingBrief ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                // Text, not a String ternary: a String label bypasses the catalogue.
                .accessibilityLabel(today.isPlayingBrief ? Text("Pause brief") : Text("Play brief"))
            }
        }
    }

    // MARK: Up next

    /// One row of "up next": a school due item or a dated open task.
    private struct UpNextItem: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let due: Date
        let isTask: Bool
    }

    /// Due items and open tasks with a due date, overdue or within the next 7 days, soonest first, top 3.
    /// A task the server made from a due item shares its title, so titles are de-duplicated (the due
    /// item wins, since it carries the course).
    private var upNext: [UpNextItem] {
        let horizon = Date.now.addingTimeInterval(7 * 24 * 3600)
        var seen = Set<String>()
        var items: [UpNextItem] = []
        for item in today.today?.due ?? [] {
            guard let due = item.dueAt, due <= horizon else { continue }
            let key = item.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(key).inserted else { continue }
            items.append(UpNextItem(id: "due-\(item.id)", title: item.title, detail: item.course,
                                    due: due, isTask: false))
        }
        for task in tasks.tasks where task.status == nil || task.status == "open" {
            guard let due = task.dueAt, due <= horizon else { continue }
            let key = task.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(key).inserted else { continue }
            items.append(UpNextItem(id: "task-\(task.id)", title: task.title, detail: nil,
                                    due: due, isTask: true))
        }
        return Array(items.sorted { $0.due < $1.due }.prefix(3))
    }

    private var upNextBlock: some View {
        Button {
            AgentNav.openJarvis(.tasks)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("UP NEXT").strandOverline()
                ForEach(upNext) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.isTask ? "checklist" : "graduationcap")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(item.due < .now ? StrandPalette.metricRose : StrandPalette.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                            if let detail = item.detail {
                                Text(detail)
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(item.due, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .font(StrandFont.footnote)
                            .foregroundStyle(item.due < .now ? StrandPalette.metricRose : StrandPalette.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Run window + approvals

    private func runWindowRow(_ window: String) -> some View {
        Button {
            AgentNav.openChat(about: "When's the best time for a run today?")
        } label: {
            Label("Best run window: \(window)", systemImage: "figure.run")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.accent)
        }
        .buttonStyle(.plain)
    }

    private var approvalsRow: some View {
        Button {
            AgentNav.openJarvis(.approvals)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(StrandPalette.gold)
                Text("Waiting for your approval: \(approvals.pendingCount)")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
#endif
