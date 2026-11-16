#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Agent Settings (More → Agent Settings)
//
// One screen for the noop-agent backend's owner controls: integrations (with per-provider
// connect), the Brightspace iCal feed, quiet hours + per-category notification levels, the market
// watchlist, and the agent's long-term Memories. Edits stage in a local draft and PUT the whole
// settings object, so one change never drops the rest.

struct AgentSettingsView: View {
    @ObservedObject private var config = AgentConfig.shared
    @ObservedObject private var store = AgentSettingsStore.shared
    @Environment(\.openURL) private var openURL

    @State private var draft = AgentSettings()
    @State private var showServer = false
    @State private var newSymbol = ""
    @State private var newMemory = ""
    @State private var liveBrowser: AgentAuthRequest?
    @State private var isRequestingBrowser = false

    private static let categories = ["school", "email", "health", "markets", "reminders"]
    private static let levels = ["off", "brief", "silent", "sound", "call"]

    var body: some View {
        Group {
            if config.isPaired {
                form
            } else {
                PairingView()
            }
        }
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.start()
            draft = store.settings
        }
        .onChange(of: store.settings) { _, new in draft = new }
        .sheet(isPresented: $showServer) {
            NavigationStack {
                ServerSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showServer = false }
                                .foregroundStyle(StrandPalette.accent)
                        }
                    }
            }
        }
        .sheet(item: $liveBrowser) { request in
            if let raw = request.liveViewUrl, let url = URL(string: raw) {
                LiveBrowserView(url: url, title: request.site?.capitalized ?? "Live Browser")
            } else {
                Text("The server didn't return a live-view URL.")
                    .padding()
            }
        }
    }

    private var form: some View {
        Form {
            serverSection
            integrationsSection
            feedSection
            quietHoursSection
            levelsSection
            watchlistSection
            memoriesSection
            liveBrowserSection
            if let error = store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
    }

    // MARK: Server

    private var serverSection: some View {
        Section {
            Button {
                showServer = true
            } label: {
                HStack {
                    Label("Server & pairing", systemImage: "network")
                    Spacer()
                    Text(config.baseURL?.host ?? "Not set")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        }
    }

    // MARK: Integrations

    private var integrationsSection: some View {
        Section {
            if store.integrations.isEmpty {
                Text("No integrations reported yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.integrations) { integration in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(integration.provider.capitalized)
                            .font(.body)
                        if let at = integration.lastSyncAt {
                            Text("Synced \(at.formatted(.relative(presentation: .named)))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    statusChip(integration.status)
                    if integration.status == "needs_auth", let raw = integration.connectUrl,
                       let url = URL(string: raw) {
                        Button("Connect") { openURL(url) }
                            .font(.footnote)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Integrations")
        } footer: {
            Text("Connect opens the provider's own sign-in in Safari.")
        }
    }

    private func statusChip(_ status: String?) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case "ok":         return ("OK", .green)
            case "needs_auth": return ("Needs auth", .orange)
            case "failing":    return ("Failing", .red)
            default:           return ("Unknown", .secondary)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    // MARK: Brightspace feed

    private var feedSection: some View {
        Section {
            TextField("https://…/feed.ics", text: icalBinding)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Brightspace")
        } footer: {
            Text("Paste your Brightspace iCal subscription URL — the agent turns it into due dates and tasks.")
        }
    }

    private var icalBinding: Binding<String> {
        Binding(
            get: { draft.icalUrl ?? "" },
            set: { draft.icalUrl = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: Quiet hours

    private var quietHoursSection: some View {
        Section {
            DatePicker("Start", selection: quietBinding(\.start), displayedComponents: .hourAndMinute)
            DatePicker("End", selection: quietBinding(\.end), displayedComponents: .hourAndMinute)
        } header: {
            Text("Quiet hours")
        } footer: {
            Text("Only categories set to “sound” or “call” below can break through quiet hours.")
        }
    }

    /// Bridge a "HH:mm" settings string to a Date for the picker.
    private func quietBinding(_ keyPath: WritableKeyPath<AgentSettings.QuietHours, String?>) -> Binding<Date> {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let calendar = Calendar.current
        return Binding(
            get: {
                guard let raw = draft.quietHours?[keyPath: keyPath],
                      let parsed = formatter.date(from: raw) else {
                    return calendar.date(bySettingHour: keyPath == \.start ? 23 : 7,
                                         minute: 0, second: 0, of: Date()) ?? Date()
                }
                return parsed
            },
            set: { date in
                var hours = draft.quietHours ?? AgentSettings.QuietHours()
                hours[keyPath: keyPath] = formatter.string(from: date)
                draft.quietHours = hours
                commit()
            }
        )
    }

    // MARK: Notification levels

    private var levelsSection: some View {
        Section {
            ForEach(Self.categories, id: \.self) { category in
                Picker(category.capitalized, selection: levelBinding(category)) {
                    ForEach(Self.levels, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                }
            }
        } header: {
            Text("Notification levels")
        } footer: {
            Text("Off: never. Brief: in the morning brief only. Silent: notification centre. Sound: ping. Call: rings through like a phone call.")
        }
    }

    private func levelBinding(_ category: String) -> Binding<String> {
        Binding(
            get: { draft.levels?[category] ?? "silent" },
            set: { level in
                var levels = draft.levels ?? [:]
                levels[category] = level
                draft.levels = levels
                commit()
            }
        )
    }

    // MARK: Watchlist

    private var watchlistSection: some View {
        Section {
            ForEach(draft.watchlist ?? []) { symbol in
                HStack {
                    Text(symbol.symbol)
                        .font(.body.weight(.semibold))
                    Spacer()
                    Stepper(value: watchlistPctBinding(symbol.symbol),
                            in: 0.5...20, step: 0.5) {
                        Text("±\(String(format: "%.1f", symbol.movePct ?? 3))%")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                var list = draft.watchlist ?? []
                list.remove(atOffsets: offsets)
                draft.watchlist = list
                commit()
            }
            HStack {
                TextField("Add symbol (e.g. AAPL)", text: $newSymbol)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Add") {
                    let symbol = newSymbol.trimmingCharacters(in: .whitespaces).uppercased()
                    guard !symbol.isEmpty else { return }
                    var list = draft.watchlist ?? []
                    guard !list.contains(where: { $0.symbol == symbol }) else { return }
                    list.append(AgentSettings.WatchSymbol(symbol: symbol, movePct: 3))
                    draft.watchlist = list
                    newSymbol = ""
                    commit()
                }
                .disabled(newSymbol.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Watchlist")
        } footer: {
            Text("The agent pings you when a symbol moves more than its threshold in a day.")
        }
    }

    private func watchlistPctBinding(_ symbol: String) -> Binding<Double> {
        Binding(
            get: {
                draft.watchlist?.first(where: { $0.symbol == symbol })?.movePct ?? 3
            },
            set: { pct in
                guard let i = draft.watchlist?.firstIndex(where: { $0.symbol == symbol }) else { return }
                draft.watchlist?[i].movePct = pct
                commit()
            }
        )
    }

    // MARK: Memories

    private var memoriesSection: some View {
        Section {
            ForEach(store.memories) { memory in
                HStack(alignment: .top, spacing: 10) {
                    Button {
                        store.updateMemory(memory, pinned: !(memory.pinned ?? false))
                    } label: {
                        Image(systemName: (memory.pinned ?? false) ? "pin.fill" : "pin")
                            .foregroundStyle((memory.pinned ?? false) ? StrandPalette.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    Text(memory.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onDelete { offsets in
                for index in offsets { store.deleteMemory(store.memories[index]) }
            }
            HStack {
                TextField("Teach the agent something…", text: $newMemory)
                Button("Add") {
                    let text = newMemory.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    store.addMemory(text)
                    newMemory = ""
                }
                .disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Memories")
        } footer: {
            Text("Facts the agent should never forget — pinned memories rank first in its context.")
        }
    }

    // MARK: Live Browser

    private var liveBrowserSection: some View {
        Section {
            Button {
                Task {
                    isRequestingBrowser = true
                    defer { isRequestingBrowser = false }
                    liveBrowser = try? await store.requestAuth(site: "brightspace")
                }
            } label: {
                HStack {
                    Label("Open Live Browser", systemImage: "rectangle.on.rectangle.badge.person.crop")
                    if isRequestingBrowser { Spacer(); ProgressView() }
                }
            }
            .disabled(isRequestingBrowser)
        } footer: {
            Text("Watch the agent log into Brightspace for you and take over if it gets stuck.")
        }
    }

    // MARK: Save

    private func commit() {
        store.save(draft)
    }
}
#endif
