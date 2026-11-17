#if os(iOS)
import Foundation
import UIKit
import LiveKit

// MARK: - Live voice call with Jarvis
//
// A call is a LiveKit room. The backend (`POST /voice/session`) creates the room, dispatches its voice
// agent into it and returns a join token; the app joins, publishes the microphone and plays the agent's
// audio. Speech-to-text, the orchestrator (same tools and memory as Chat) and text-to-speech all run on the
// server, so this store only handles connection, audio routing, captions and the agent's state.
//
// Pinned to LiveKit Swift SDK 2.14.0 (project.yml): the newest release whose package manifest the macOS-15
// CI leg's Xcode can still resolve. The protocol facts below come from livekit-agents 1.8 (the voice worker):
//   - captions arrive as text streams on topic "lk.transcription"; one stream per caption segment
//     ("lk.segment_id"), the agent's as deltas, the owner's republished whole; sender = who spoke
//   - the agent publishes its state in the participant attribute "lk.agent.state"

/// LiveKit Agents protocol keys. Outside the main-actor store so the caption reader (off the main actor) can use them.
private enum CallKeys {
    static let transcriptionTopic = "lk.transcription"
    static let segmentId = "lk.segment_id"
    static let final = "lk.transcription_final"
    static let agentState = "lk.agent.state"
}

/// What the agent is doing, from its `lk.agent.state` attribute.
enum JarvisAgentState: String {
    case initializing, idle, listening, thinking, speaking
}

/// One caption line.
struct CallCaption: Identifiable, Equatable {
    let id: String          // lk.segment_id
    var fromOwner: Bool
    var text: String
    var isFinal: Bool
}

@MainActor
final class VoiceCallStore: ObservableObject {
    static let shared = VoiceCallStore()

    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting
        case ended(String?)   // optional reason shown briefly before the screen closes
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var agentState: JarvisAgentState = .initializing
    @Published private(set) var captions: [CallCaption] = []
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeaker = false
    @Published private(set) var connectedAt: Date?
    /// Drives the full-screen call UI. Set when a call starts; cleared when the ended screen is dismissed.
    @Published var isPresented = false

    private var room: Room?
    private var roomName: String?
    private var delegate: CallRoomDelegate?
    private var reconnectDeadline: Task<Void, Never>?

    private init() {}

    var isActive: Bool {
        switch phase {
        case .connecting, .connected, .reconnecting: return true
        default: return false
        }
    }

    // MARK: Start / end

    func start() {
        guard !isActive else { isPresented = true; return }
        phase = .connecting
        agentState = .initializing
        captions = []
        isMuted = false
        isSpeaker = false
        connectedAt = nil
        isPresented = true
        Task { await connect() }
    }

    private func connect() async {
        let session: AgentVoiceSession
        do {
            session = try await AgentAPI.shared.post("/voice/session")
        } catch {
            guard phase == .connecting else { return }
            finish(reason: Self.describeStartError(error))
            return
        }
        guard phase == .connecting else {
            // Hung up before the server answered: close the room it just made.
            try? await AgentAPI.shared.send("/voice/session/\(session.room)/end", method: "POST")
            return
        }
        roomName = session.room

        let room = Room()
        let delegate = CallRoomDelegate(store: self)
        room.add(delegate: delegate)
        self.room = room
        self.delegate = delegate

        // Earpiece by default (it's a phone call); the speaker button flips it.
        AudioManager.shared.isSpeakerOutputPreferred = false
        do {
            try await room.registerTextStreamHandler(for: CallKeys.transcriptionTopic) { [weak self] reader, sender in
                guard let self else { return }
                try await self.consumeCaption(reader: reader, sender: sender.stringValue)
            }
            try await room.connect(url: session.url, token: session.token)
            try await room.localParticipant.setMicrophone(enabled: true)
        } catch {
            await room.disconnect()
            try? await AgentAPI.shared.send("/voice/session/\(session.room)/end", method: "POST")
            guard phase == .connecting else { return }
            finish(reason: String(localized: "Couldn't connect the call: \(error.localizedDescription)"))
            return
        }
        guard phase == .connecting else {
            // Hung up while connecting: hangUp() had no room or room name yet, so close both here.
            await room.disconnect()
            try? await AgentAPI.shared.send("/voice/session/\(session.room)/end", method: "POST")
            return
        }
        phase = .connected
        connectedAt = .now
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isProximityMonitoringEnabled = true
        refreshAgentState()
    }

    /// The owner hung up.
    func hangUp() {
        guard isActive else { isPresented = false; return }
        let room = self.room
        let name = roomName
        finish(reason: nil)
        Task {
            await room?.disconnect()
            if let name {
                // Tells the server to close the room and log "Call ended"; failure is harmless.
                try? await AgentAPI.shared.send("/voice/session/\(name)/end", method: "POST")
            }
        }
    }

    private func finish(reason: String?) {
        reconnectDeadline?.cancel()
        reconnectDeadline = nil
        room = nil
        delegate = nil
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.isProximityMonitoringEnabled = false
        phase = .ended(reason)
        // Show "Call ended" (or the reason) for a moment, then close the call screen.
        let delay: UInt64 = reason == nil ? 900_000_000 : 3_500_000_000
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, case .ended = self.phase else { return }
            self.isPresented = false
            self.phase = .idle
        }
    }

    // MARK: Controls

    func toggleMute() {
        guard let room, phase == .connected || phase == .reconnecting else { return }
        let mute = !isMuted
        isMuted = mute
        Task {
            do {
                try await room.localParticipant.setMicrophone(enabled: !mute)
            } catch {
                await MainActor.run { self.isMuted = !mute }
            }
        }
    }

    func toggleSpeaker() {
        isSpeaker.toggle()
        AudioManager.shared.isSpeakerOutputPreferred = isSpeaker
        // The proximity sensor blanks the screen at the ear; pointless (and annoying) on speaker.
        UIDevice.current.isProximityMonitoringEnabled = !isSpeaker && isActive
    }

    // MARK: Room events (forwarded from CallRoomDelegate on the main actor)

    fileprivate func connectionChanged(_ state: ConnectionState) {
        switch state {
        case .reconnecting:
            guard phase == .connected else { return }
            phase = .reconnecting
            // Give the SDK 20 s to recover, then end the call instead of hanging silently.
            reconnectDeadline?.cancel()
            reconnectDeadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, !Task.isCancelled, self.phase == .reconnecting else { return }
                self.hangUp()
            }
        case .connected:
            if phase == .reconnecting {
                reconnectDeadline?.cancel()
                phase = .connected
            }
        default:
            break
        }
    }

    fileprivate func disconnected(error: String?) {
        guard isActive else { return }
        finish(reason: error.map { String(localized: "Call dropped: \($0)") } ?? String(localized: "Jarvis ended the call."))
    }

    fileprivate func refreshAgentState() {
        guard let room else { return }
        let agent = room.remoteParticipants.values.first { $0.kind == .agent }
        if let raw = agent?.attributes[CallKeys.agentState], let state = JarvisAgentState(rawValue: raw) {
            agentState = state
        }
    }

    // MARK: Captions

    /// One text stream = one caption segment. Its chunks are appended as they arrive; a segment published
    /// again (the owner's interim → final transcript) arrives as a new stream with the same segment id and
    /// replaces the earlier text.
    private nonisolated func consumeCaption(reader: TextStreamReader, sender: String) async throws {
        let attrs = reader.info.attributes
        let segment = attrs[CallKeys.segmentId] ?? reader.info.id
        let isFinal = attrs[CallKeys.final] == "true"
        var text = ""
        for try await chunk in reader {
            text += chunk
            let snapshot = text
            await MainActor.run { self.upsertCaption(segment: segment, sender: sender, text: snapshot, isFinal: false) }
        }
        let finalText = text
        await MainActor.run { self.upsertCaption(segment: segment, sender: sender, text: finalText, isFinal: isFinal) }
    }

    private func upsertCaption(segment: String, sender: String, text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Identity is an NSObject: compare the strings, not the objects.
        let fromOwner = sender == room?.localParticipant.identity?.stringValue
        if let i = captions.firstIndex(where: { $0.id == segment }) {
            captions[i].text = trimmed
            captions[i].isFinal = captions[i].isFinal || isFinal
        } else {
            captions.append(CallCaption(id: segment, fromOwner: fromOwner, text: trimmed, isFinal: isFinal))
            if captions.count > 40 { captions.removeFirst(captions.count - 40) }
        }
    }

    // MARK: Errors

    private static func describeStartError(_ error: Error) -> String {
        if case AgentAPIError.http(let code, let body) = error {
            if code == 503 || body.contains("voice_not_configured") {
                return String(localized: "Voice isn't set up on your server yet. Add the LiveKit, Deepgram and ElevenLabs keys and start the voice profile.")
            }
            if code == 502 {
                return String(localized: "Your server couldn't start the voice agent. Is the voice container running?")
            }
        }
        return error.localizedDescription
    }
}

/// LiveKit calls its delegates off the main thread; this hops every event onto the store's main actor.
private final class CallRoomDelegate: NSObject, RoomDelegate, @unchecked Sendable {
    private weak var store: VoiceCallStore?

    init(store: VoiceCallStore) {
        self.store = store
    }

    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor [weak store] in store?.connectionChanged(connectionState) }
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        let message = error?.localizedDescription
        Task { @MainActor [weak store] in store?.disconnected(error: message) }
    }

    func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        Task { @MainActor [weak store] in store?.refreshAgentState() }
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak store] in store?.refreshAgentState() }
    }
}
#endif
