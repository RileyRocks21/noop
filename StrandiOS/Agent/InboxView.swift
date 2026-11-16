#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Inbox tab
//
// The agent's triaged mail in three groups: Action (needs you), FYI (worth a glance), Ignored
// (filed away, collapsible). Tap a row to expand the agent's summary; swipe to re-file or promote
// to a task. Live updates ride the socket's inbox.updated event.

struct InboxView: View {
    @ObservedObject private var config = AgentConfig.shared
    @ObservedObject private var store = InboxStore.shared
    /// Which mails are expanded to show their full summary.
    @State private var expanded: Set<String> = []
    @State private var showIgnored = false

    var body: some View {
        if config.isPaired {
            content
                .onAppear { store.start() }
        } else {
            PairingView()
        }
    }

    private var content: some View {
        ScreenScaffold(title: "Inbox",
                       subtitle: subtitle,
                       onRefresh: { await store.refresh() },
                       topBackground: liquidScaffoldSky()) {
            if let error = store.errorMessage {
                DataPendingNote(title: "Inbox", message: LocalizedStringKey(error),
                                symbol: "exclamationmark.triangle.fill")
            }
            groupCard(title: "ACTION", mails: mails(in: "action"),
                      accent: StrandPalette.metricRose)
            groupCard(title: "FYI", mails: mails(in: "fyi"),
                      accent: StrandPalette.textTertiary)
            ignoredDisclosure
            if store.items.isEmpty && !store.isLoading {
                Text("Inbox zero. The agent files new mail here as it arrives.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var subtitle: LocalizedStringKey {
        let n = mails(in: "action").count
        return n == 0 ? "Nothing needs you" : "\(n) need\(n == 1 ? "s" : "") you"
    }

    private func mails(in category: String) -> [AgentEmail] {
        store.items.filter { ($0.category ?? "fyi") == category }
    }

    // MARK: - Groups

    @ViewBuilder
    private func groupCard(title: String, mails: [AgentEmail], accent: Color) -> some View {
        if !mails.isEmpty {
            NoopCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .strandOverline()
                        .foregroundStyle(accent)
                        .padding(16)
                    ForEach(mails) { mail in
                        mailRow(mail)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                                    .padding(.leading, 16)
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
            }
        }
    }

    private var ignoredDisclosure: some View {
        let ignored = mails(in: "ignore")
        return Group {
            if !ignored.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                            showIgnored.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("IGNORED (\(ignored.count))").strandOverline()
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                                .rotationEffect(.degrees(showIgnored ? 0 : -90))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showIgnored {
                        groupCard(title: "FILED AWAY", mails: ignored,
                                  accent: StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: - Row

    private func mailRow(_ mail: AgentEmail) -> some View {
        let isOpen = expanded.contains(mail.id)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                    if isOpen { expanded.remove(mail.id) } else { expanded.insert(mail.id) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(mail.from ?? "Unknown sender")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer()
                        if let at = mail.receivedAt {
                            Text(at, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    Text(mail.subject ?? "(no subject)")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(isOpen ? nil : 1)
                    if let summary = mail.summary {
                        Text(summary)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(isOpen ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                HStack(spacing: 14) {
                    if mail.taskId == nil {
                        Button { store.makeTask(mail) } label: {
                            Label("Make task", systemImage: "checkmark.circle")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.accent)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label("Task created", systemImage: "checkmark.circle.fill")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    Menu("Move to") {
                        Button("Action") { store.setCategory(mail, category: "action") }
                        Button("FYI") { store.setCategory(mail, category: "fyi") }
                        Button("Ignore") { store.setCategory(mail, category: "ignore") }
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
#endif
