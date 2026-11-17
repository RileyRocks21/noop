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
    /// Posted when an agent surface wants the shell to switch to the Jarvis tab. The section to show is
    /// set on `JarvisRouter.shared` BEFORE posting, so the tab opens on it directly.
    static let openJarvisNotification = Notification.Name("noop.agent.openJarvis")

    /// Switch to the Jarvis tab, showing `section`.
    @MainActor static func openJarvis(_ section: JarvisSection) {
        JarvisRouter.shared.section = section
        NotificationCenter.default.post(name: openJarvisNotification, object: nil)
    }

    /// Hand a prompt to Jarvis's Chat (staged in the draft for review, not sent) and switch to it.
    @MainActor static func openChat(about topic: String) {
        ChatStore.shared.pendingPrompt = topic
        openJarvis(.chat)
    }
}
#endif
