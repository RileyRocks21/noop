#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Alerts (notification history)
//
// Every notification the agent produced, newest first and grouped by day, with a category filter.
// Unread rows carry a dot until the wearer leaves the screen or taps "Mark all read". Rows that never
// reached the phone say why (held for quiet hours, saved for the brief, category switched off), which
// is the point of the screen while push isn't set up.

struct NotificationsView: View {
    @ObservedObject private var config = AgentConfig.shared
    @ObservedObject private var store = NotificationsStore.shared
    @State private var filter: String?

    var body: some View {
        if config.isPaired {
            content
                .onAppear { store.start() }
                .onDisappear { store.markAllRead() }
        } else {
            PairingView()
        }
    }

    private var content: some View {
        ScreenScaffold(title: "Alerts",
                       subtitle: subtitle,
                       onRefresh: { await store.refresh() },
                       topBackground: liquidScaffoldSky(),
                       trailing: { markReadButton }) {
            filterChips
            if let error = store.errorMessage {
                DataPendingNote(title: "Alerts", message: LocalizedStringKey(error),
                                symbol: "exclamationmark.triangle.fill")
            }
            ForEach(dayGroups, id: \.day) { group in
                dayCard(group.day, group.items)
            }
            if visible.isEmpty && !store.isLoading {
                Text("Nothing yet. Every alert Jarvis sends lands here, even ones that never reached your phone.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if !store.reachedEnd && !store.items.isEmpty {
                Button {
                    Task { await store.loadMore() }
                } label: {
                    Text("Load older alerts")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var subtitle: LocalizedStringKey {
        store.unread == 0 ? "All caught up" : "\(store.unread) unread"
    }

    @ViewBuilder
    private var markReadButton: some View {
        if store.unread > 0 {
            Button { store.markAllRead() } label: {
                Text("Mark all read")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Filter

    private static var categories: [(key: String, label: LocalizedStringKey)] { [
        ("school", "School"), ("email", "Email"), ("health", "Health"),
        ("markets", "Markets"), ("reminders", "Reminders"),
    ] }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", selected: filter == nil) { filter = nil }
                ForEach(Self.categories, id: \.key) { c in
                    chip(c.label, selected: filter == c.key) { filter = c.key }
                }
            }
        }
    }

    private func chip(_ label: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? StrandPalette.accent : StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Groups

    private var visible: [AgentNotification] {
        guard let filter else { return store.items }
        return store.items.filter { $0.category == filter }
    }

    private var dayGroups: [(day: Date, items: [AgentNotification])] {
        let cal = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [AgentNotification]] = [:]
        for n in visible {
            let day = cal.startOfDay(for: n.createdAt ?? .distantPast)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(n)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }

    private func dayTitle(_ day: Date) -> Text {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return Text("TODAY") }
        if cal.isDateInYesterday(day) { return Text("YESTERDAY") }
        return Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func dayCard(_ day: Date, _ items: [AgentNotification]) -> some View {
        NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                dayTitle(day)
                    .strandOverline()
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(16)
                ForEach(items) { n in
                    row(n)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                                .padding(.leading, 52)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
    }

    // MARK: - Row

    private func row(_ n: AgentNotification) -> some View {
        let style = Self.style(for: n.category)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style.color)
                .frame(width: 24, height: 24)
                .background(Circle().fill(style.color.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(n.title)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let at = n.createdAt {
                        Text(at, format: .dateTime.hour().minute())
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                if let text = n.body, !text.isEmpty {
                    Text(text)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = Self.statusNote(n.status) {
                    Text(note)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            if n.readAt == nil {
                Circle().fill(StrandPalette.accent).frame(width: 8, height: 8).padding(.top, 6)
                    .accessibilityLabel(Text("Unread"))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { route(n) }
    }

    /// Open what the alert is about: tasks and reminders → Tasks, mail → Inbox, approvals → Approvals,
    /// anything else → Chat.
    private func route(_ n: AgentNotification) {
        let link = n.deeplink ?? ""
        if link.hasPrefix("noop://tasks") { JarvisRouter.shared.section = .tasks }
        else if link.hasPrefix("noop://inbox") || n.category == "email" { JarvisRouter.shared.section = .inbox }
        else if link.hasPrefix("noop://approvals") { JarvisRouter.shared.section = .approvals }
        else if link.hasPrefix("noop://chat") { JarvisRouter.shared.section = .chat }
    }

    private static func statusNote(_ status: String?) -> LocalizedStringKey? {
        switch status {
        case "held": return "Held for quiet hours"
        case "brief": return "Saved for your morning brief"
        case "off": return "Not pushed: this category is off"
        default: return nil
        }
    }

    private static func style(for category: String?) -> (symbol: String, color: Color) {
        switch category {
        case "school": return ("graduationcap.fill", StrandPalette.metricAmber)
        case "email": return ("envelope.fill", StrandPalette.metricPurple)
        case "health": return ("heart.fill", StrandPalette.metricRose)
        case "markets": return ("chart.line.uptrend.xyaxis", StrandPalette.metricCyan)
        default: return ("bell.fill", StrandPalette.accent)
        }
    }
}
#endif
