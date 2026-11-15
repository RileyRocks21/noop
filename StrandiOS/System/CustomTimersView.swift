#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Custom timers screen
//
// Set a labelled countdown; when it finishes the WHOOP strap buzzes (CustomTimersStore's injected
// buzz closure → AppModel.buzz) and the phone posts a local notification as the background backup.
// Reached from More → App → Timers.

struct CustomTimersView: View {
    @ObservedObject private var store = CustomTimersStore.shared

    @State private var label = ""
    @State private var hours = 0
    @State private var minutes = 5
    @State private var seconds = 0
    @State private var showFired = false

    private var pickedSeconds: TimeInterval {
        TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    var body: some View {
        ScreenScaffold(title: "Timers",
                       subtitle: "Buzzes your strap when done",
                       topBackground: liquidScaffoldSky()) {
            newTimerCard
            if !store.timers.isEmpty {
                runningCard
            }
        }
        .onChange(of: store.firedLabel) { _, value in
            showFired = value != nil
        }
        .alert("Timer finished", isPresented: $showFired) {
            Button("OK") { store.firedLabel = nil }
        } message: {
            Text(store.firedLabel ?? "")
        }
    }

    // MARK: - New timer

    private var newTimerCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("NEW TIMER").strandOverline()

                TextField("Label (optional)", text: $label)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(StrandPalette.surfaceInset))

                HStack(spacing: 0) {
                    picker(value: $hours, range: 0...23, unit: "h")
                    picker(value: $minutes, range: 0...59, unit: "m")
                    picker(value: $seconds, range: 0...59, unit: "s")
                }
                .frame(height: 110)
                .clipped()

                // One-tap presets for the common cases.
                HStack(spacing: 8) {
                    preset(60, "1 min")
                    preset(300, "5 min")
                    preset(600, "10 min")
                    preset(1200, "20 min")
                    preset(1800, "30 min")
                }

                Button {
                    store.start(label: label, durationSeconds: pickedSeconds)
                    label = ""
                } label: {
                    Text("Start timer")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.surfaceBase)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(StrandPalette.accent))
                }
                .buttonStyle(.plain)
                .disabled(pickedSeconds <= 0)
                .opacity(pickedSeconds <= 0 ? 0.4 : 1)
            }
        }
    }

    private func picker(value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        HStack(spacing: 2) {
            Picker("", selection: value) {
                ForEach(range, id: \.self) { v in
                    Text("\(v)").tag(v)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            Text(unit)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func preset(_ secs: TimeInterval, _ title: String) -> some View {
        Button {
            store.start(label: label, durationSeconds: secs)
            label = ""
        } label: {
            Text(title)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.accent)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Capsule().fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Running timers

    private var runningCard: some View {
        NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("RUNNING").strandOverline().padding(16)
                ForEach(store.timers) { timer in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(timer.label)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(timer.fireAt, format: .dateTime.hour().minute())
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        // Monospaced countdown so the digits don't jiggle as they roll.
                        Text(Self.format(timer.fireAt.timeIntervalSince(store.now)))
                            .font(StrandFont.rounded(22).monospacedDigit())
                            .foregroundStyle(StrandPalette.accent)
                        Button(role: .destructive) {
                            store.cancel(timer)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 8)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.leading, 16)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval.rounded(.up)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }
}
#endif
