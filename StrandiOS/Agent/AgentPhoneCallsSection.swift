#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Agent Settings → Phone calls
//
// The sideloaded app can't receive push, so Jarvis can ring the owner's real phone instead
// (backend: noop-agent's phone module). This part of Agent Settings shows whether the server is
// set up to call, the wake-up call times per weekday, the urgent-call and task-reminder switches,
// the call quiet hours, a test call, and the recent call history. Edits stage in a local draft
// and save through AgentCallsStore (debounced, latest wins).

struct AgentPhoneCallsSection: View {
    @ObservedObject private var store = AgentCallsStore.shared
    @State private var draft = AgentCallSettings()

    /// Backend weekday keys, Monday first (the week as the owner reads it).
    private static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    /// Index into Calendar.weekdaySymbols (Sunday = 0) for each backend key.
    private static let symbolIndex: [String: Int] = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]

    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        Group {
            callsSection
            if store.status?.configured == true && (draft.wakeEnabled ?? true) {
                wakeSection
            }
            recentSection
        }
        .onAppear {
            store.start()
            draft = store.currentDraft
        }
        // Adopt the server copy only when no local edit is waiting on it.
        .onChange(of: store.status) { _, new in
            guard !store.isDirty, let new else { return }
            draft = new.settings
        }
    }

    // MARK: Status, switches, quiet hours, test call

    private var callsSection: some View {
        Section {
            statusRow
            if store.status?.configured == true {
                Toggle("Wake-up call", isOn: boolBinding(\.wakeEnabled, default: true))
                Toggle("Urgent calls", isOn: boolBinding(\.urgentEnabled, default: true))
                Toggle("Task reminders", isOn: boolBinding(\.remindersEnabled, default: true))
                DatePicker("No calls from", selection: quietBinding(\.start, fallback: "22:30"),
                           displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: quietBinding(\.end, fallback: "07:00"),
                           displayedComponents: .hourAndMinute)
                testCallRow
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusCritical)
            }
        } header: {
            Text("Phone calls")
        } footer: {
            Text("Jarvis calls your phone for the wake-up call, urgent email or market news, and tasks due within two hours. Urgent calls and reminders wait out these quiet hours; the wake-up call and calls you asked for don't.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if let status = store.status {
            if status.configured {
                HStack {
                    Label("Calls go to", systemImage: "phone.fill")
                        .font(StrandFont.body)
                    Spacer()
                    Text(verbatim: status.ownerNumber ?? "—")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                    StatePill("Ready", tone: .positive, showsDot: false)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Not set up on the server", systemImage: "phone.badge.waveform")
                            .font(StrandFont.body)
                        Spacer()
                        StatePill("Needs setup", tone: .warning, showsDot: false)
                    }
                    Text("Follow “Phone calls” in the backend README, then set these in .env:")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    if let missing = status.missing, !missing.isEmpty {
                        Text(verbatim: missing.joined(separator: ", "))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        } else {
            HStack {
                Text("Checking the server…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var testCallRow: some View {
        Button {
            store.callMeNow()
        } label: {
            HStack {
                Label("Call me now (test)", systemImage: "phone.arrow.up.right")
                if store.testState == .placing { Spacer(); ProgressView() }
            }
        }
        .disabled(store.testState == .placing)
        switch store.testState {
        case .ringing:
            Label("Calling — your phone should ring in a few seconds.", systemImage: "phone.connection")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusPositive)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusCritical)
        case .idle, .placing:
            EmptyView()
        }
    }

    // MARK: Wake-up times

    private var wakeSection: some View {
        Section {
            ForEach(Self.weekdays, id: \.self) { day in
                HStack {
                    Toggle(isOn: dayEnabledBinding(day)) {
                        Text(verbatim: weekdayName(day))
                            .font(StrandFont.body)
                    }
                    if wakeTime(day) != nil {
                        DatePicker("Wake-up time", selection: dayTimeBinding(day), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }
            }
        } header: {
            Text("Wake-up call")
        } footer: {
            Text("Jarvis rings at this time with a short version of the morning brief, and you can talk back. Days without a time get no call. No answer: two more tries, five minutes apart.")
        }
    }

    private func weekdayName(_ day: String) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard let i = Self.symbolIndex[day], i < symbols.count else { return day }
        return symbols[i]
    }

    private func wakeTime(_ day: String) -> String? {
        guard let value = draft.wakeTimes?[day] else { return nil }
        return value
    }

    private func setWakeTime(_ day: String, _ value: String?) {
        var times = draft.wakeTimes ?? [:]
        times[day] = .some(value)
        draft.wakeTimes = times
        commit()
    }

    private func dayEnabledBinding(_ day: String) -> Binding<Bool> {
        Binding(
            get: { wakeTime(day) != nil },
            set: { on in
                if on {
                    // Start from the time used on another day, so setting up a week is a few taps.
                    let other = Self.weekdays.compactMap { wakeTime($0) }.first
                    setWakeTime(day, other ?? "07:00")
                } else {
                    setWakeTime(day, nil)
                }
            }
        )
    }

    private func dayTimeBinding(_ day: String) -> Binding<Date> {
        Binding(
            get: { date(from: wakeTime(day) ?? "07:00") },
            set: { setWakeTime(day, Self.hhmm.string(from: $0)) }
        )
    }

    // MARK: Recent calls

    private var recentSection: some View {
        Section {
            if store.calls.isEmpty {
                Text("No calls yet.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach(store.calls) { call in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: call.kind))
                        .foregroundStyle(StrandPalette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: call.reason ?? "")
                            .font(StrandFont.subhead)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if let at = call.startedAt {
                                Text(at.formatted(.relative(presentation: .named)))
                            }
                            if let seconds = call.durationSeconds, seconds > 0 {
                                Text(verbatim: "·")
                                Text(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                            }
                            if let attempt = call.attempt, attempt > 1 {
                                Text(verbatim: "·")
                                Text("Try \(attempt)")
                            }
                        }
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    callStatusPill(call.status)
                }
            }
        } header: {
            Text("Recent calls")
        }
    }

    private func icon(for kind: String?) -> String {
        switch kind {
        case "wake":      return "alarm"
        case "urgent":    return "exclamationmark.bubble"
        case "reminder":  return "checklist"
        case "scheduled": return "clock"
        default:          return "phone"
        }
    }

    private func callStatusPill(_ status: String?) -> some View {
        let (label, tone): (LocalizedStringKey, StrandTone) = {
            switch status {
            case "ringing":   return ("Ringing", .accent)
            case "answered":  return ("On the call", .positive)
            case "completed": return ("Answered", .positive)
            case "no_answer": return ("No answer", .warning)
            case "failed":    return ("Failed", .critical)
            default:          return ("Unknown", .neutral)
            }
        }()
        return StatePill(label, tone: tone, showsDot: false)
    }

    // MARK: Bindings + save

    private func boolBinding(_ keyPath: WritableKeyPath<AgentCallSettings, Bool?>, default fallback: Bool) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: keyPath] ?? fallback },
            set: { value in
                draft[keyPath: keyPath] = value
                commit()
            }
        )
    }

    private func quietBinding(_ keyPath: WritableKeyPath<AgentCallSettings.QuietHours, String?>, fallback: String) -> Binding<Date> {
        Binding(
            get: { date(from: draft.quietHours?[keyPath: keyPath] ?? fallback) },
            set: { value in
                var hours = draft.quietHours ?? AgentCallSettings.QuietHours()
                hours[keyPath: keyPath] = Self.hhmm.string(from: value)
                draft.quietHours = hours
                commit()
            }
        )
    }

    /// "HH:mm" → today at that time (what the hour-and-minute pickers display).
    private func date(from hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let hour = parts.first ?? 7
        let minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    private func commit() {
        store.save(draft)
    }
}
#endif
