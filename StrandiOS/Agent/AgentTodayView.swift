#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Agent Today (the new home)
//
// The owner-facing morning surface for the noop-agent backend: the brief (text + MP3 playback),
// health numbers, calories in vs burned (linking into the existing Nutrition tab), the next 3 due
// items, the next 3 events, and weather with the best run window. Every card can be tapped to open
// Chat about it. Empty states are first-class — the contract allows brief/health to be null.
//
// The OLD health dashboard still exists (More → Health Today); this screen is additive.

struct AgentTodayView: View {
    @ObservedObject private var config = AgentConfig.shared
    @ObservedObject private var hub = AgentSocketHub.shared
    @ObservedObject private var store = AgentTodayStore.shared

    var body: some View {
        if config.isPaired {
            content
                .onAppear { store.start() }
        } else {
            PairingView()
        }
    }

    private var content: some View {
        ScreenScaffold(title: "Today",
                       subtitle: LocalizedStringKey(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())),
                       onRefresh: { await store.refresh() },
                       topBackground: liquidScaffoldSky()) {
            if !hub.isOnline {
                offlineBanner
            }
            if let error = store.errorMessage {
                DataPendingNote(title: "Today", message: LocalizedStringKey(error),
                                symbol: "exclamationmark.triangle.fill")
            }

            briefCard
            healthCard
            nutritionCard
            dueCard
            eventsCard
            weatherCard
        }
    }

    private var offlineBanner: some View {
        Text("Offline — showing cached data, reconnecting…")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StrandPalette.gold.opacity(0.15)))
    }

    // MARK: - Brief

    @ViewBuilder
    private var briefCard: some View {
        if let brief = store.today?.brief {
            cardButton(topic: "Tell me more about today's brief.") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("YOUR BRIEF").strandOverline()
                        Spacer()
                        if brief.audioUrl != nil {
                            Button {
                                store.toggleBriefAudio()
                            } label: {
                                Image(systemName: store.isPlayingBrief
                                      ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(StrandPalette.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(brief.script)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Health

    @ViewBuilder
    private var healthCard: some View {
        if let h = store.today?.health {
            cardButton(topic: "How's my health data looking today?") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("HEALTH").strandOverline()
                    HStack(spacing: 16) {
                        if let v = h.recovery { stat("Recovery", "\(Int(v.rounded()))%") }
                        if let v = h.hrvMs { stat("HRV", "\(Int(v.rounded())) ms") }
                        if let v = h.sleepHours { stat("Sleep", String(format: "%.1f h", v)) }
                        if let v = h.strain { stat("Strain", String(format: "%.1f", v)) }
                    }
                }
            }
        }
    }

    // MARK: - Nutrition

    @ViewBuilder
    private var nutritionCard: some View {
        let kcalIn = store.today?.nutrition?.kcalIn
        cardButton(topic: "How are my calories looking today?") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("NUTRITION").strandOverline()
                    Spacer()
                    // Deep link into the existing Nutrition tab.
                    Button {
                        NotificationCenter.default.post(name: AgentNav.openNutritionNotification, object: nil)
                    } label: {
                        Label("Open", systemImage: "fork.knife")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
                if let kcalIn {
                    Text("\(Int(kcalIn.rounded())) kcal eaten")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                } else {
                    Text("Nothing logged yet today.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    // MARK: - Due items (next 3)

    @ViewBuilder
    private var dueCard: some View {
        let due = Array((store.today?.due ?? [])
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            .prefix(3))
        if !due.isEmpty {
            cardButton(topic: "What's due soon? Walk me through it.") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("DUE NEXT").strandOverline()
                    ForEach(due) { item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                if let course = item.course {
                                    Text(course)
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                            Spacer()
                            if let dueAt = item.dueAt {
                                Text(dueAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Events (next 3)

    @ViewBuilder
    private var eventsCard: some View {
        let events = Array((store.today?.events ?? [])
            .sorted { ($0.startAt ?? .distantFuture) < ($1.startAt ?? .distantFuture) }
            .prefix(3))
        if !events.isEmpty {
            cardButton(topic: "What does my schedule look like?") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("COMING UP").strandOverline()
                    ForEach(events) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.title)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            if let startAt = event.startAt {
                                Text(startAt, format: .dateTime.hour().minute())
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Weather + run window

    @ViewBuilder
    private var weatherCard: some View {
        if let w = store.today?.weather {
            cardButton(topic: "When's the best time for a run today?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WEATHER").strandOverline()
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let temp = w.tempC {
                            Text("\(Int(temp.rounded()))°")
                                .font(StrandFont.rounded(28))
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                        if let summary = w.summary {
                            Text(summary)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    if let window = w.bestRunWindow {
                        Label("Best run window: \(window)", systemImage: "figure.run")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    /// A NoopCard that opens Chat about `topic` when tapped (tap-any-card per the handoff).
    private func cardButton<Content: View>(topic: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        Button {
            AgentNav.openChat(about: topic)
        } label: {
            NoopCard { content() }
        }
        .buttonStyle(.plain)
    }
}

extension AgentNav {
    /// Posted when an agent screen wants the shell to switch to the Nutrition tab.
    static let openNutritionNotification = Notification.Name("noop.agent.openNutrition")
}
#endif
