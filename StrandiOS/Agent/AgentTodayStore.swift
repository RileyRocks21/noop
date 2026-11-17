#if os(iOS)
import AVFoundation
import Foundation

// MARK: - Agent Today store
//
// Backs the agent home screen: GET /today (brief + health + nutrition + due + events + weather),
// refreshed on appear and whenever the socket pushes `today.updated`. Also owns the brief's audio
// playback (an AVPlayer must outlive the button tap that started it, so it lives here).

@MainActor
final class AgentTodayStore: ObservableObject {
    static let shared = AgentTodayStore()

    @Published private(set) var today: AgentToday?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlayingBrief = false
    @Published var errorMessage: String?

    private var player: AVPlayer?
    private var subscription: UUID?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        AgentSocketHub.shared.start()
        subscription = AgentSocketHub.shared.subscribe(
            handler: { [weak self] event in
                guard event.type == "today.updated" else { return }
                Task { @MainActor in await self?.refresh() }
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
        do {
            today = try await AgentAPI.shared.get("/today")
            errorMessage = nil
        } catch {
            errorMessage = NutritionStore.describe(error)
        }
    }

    // MARK: Brief audio

    /// Play/pause the brief's MP3. `audioUrl` may be server-relative — resolved against the
    /// configured base URL.
    func toggleBriefAudio() {
        if isPlayingBrief {
            player?.pause()
            isPlayingBrief = false
            return
        }
        guard let raw = today?.brief?.audioUrl, !raw.isEmpty,
              let url = resolveURL(raw) else { return }
        let player = AVPlayer(url: url)
        self.player = player
        player.play()
        isPlayingBrief = true
        // Flip the button back when the clip ends.
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isPlayingBrief = false }
        }
    }

    private func resolveURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil { return url }
        return AgentConfig.shared.baseURL?.appendingPathComponent(raw)
    }
}

// MARK: - Cross-screen "open chat about it"

enum AgentNav {
    /// Posted when an agent screen wants the shell to switch to the Chat tab.
    static let openChatNotification = Notification.Name("noop.agent.openChat")

    /// Hand a prompt to the Chat tab and ask the shell to switch to it.
    @MainActor static func openChat(about topic: String) {
        ChatStore.shared.pendingPrompt = topic
        NotificationCenter.default.post(name: openChatNotification, object: nil)
    }
}
#endif
