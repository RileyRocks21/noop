#if os(iOS)
import SwiftUI
import AVFoundation
import StrandDesign

// MARK: - Call screen
//
// Full-screen, phone-call layout: who you're talking to and what it's doing (listening / thinking /
// speaking) with a live pulse, the call timer, rolling captions for both sides, and mute / speaker / end.
// All state lives in VoiceCallStore; this view only renders it.

struct CallView: View {
    @ObservedObject private var call = VoiceCallStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 48)
            Spacer(minLength: 24)
            JarvisPulse(state: call.agentState, active: call.phase == .connected)
                .frame(width: 168, height: 168)
            Spacer(minLength: 24)
            captionList
                .frame(maxHeight: 260)
            talkArea
                .padding(.top, 16)
            controls
                .padding(.top, 16)
                .padding(.bottom, 36)
        }
        .padding(.horizontal, NoopMetrics.screenHPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("Jarvis")
                .font(StrandFont.title1)
                .foregroundStyle(StrandPalette.textPrimary)
            statusLine
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch call.phase {
        case .idle, .connecting:
            Text("Calling…")
        case .reconnecting:
            Text("Reconnecting…")
        case .ended(let reason):
            if let reason { Text(reason) } else { Text("Call ended") }
        case .connected:
            HStack(spacing: 6) {
                if let start = call.connectedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(Self.elapsed(from: start, to: context.date))
                            .monospacedDigit()
                    }
                    Text(verbatim: "·")
                }
                Text(stateLabel)
            }
        }
    }

    private var stateLabel: LocalizedStringKey {
        switch call.agentState {
        case .initializing, .idle: return "Joining…"
        case .listening: return "Listening"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Captions

    private var captionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(call.captions) { caption in
                        captionRow(caption).id(caption.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: call.captions) { _, captions in
                if let last = captions.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func captionRow(_ caption: CallCaption) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            (caption.fromOwner ? Text("You") : Text("Jarvis"))
                .font(StrandFont.caption)
                .foregroundStyle(caption.fromOwner ? StrandPalette.textTertiary : StrandPalette.accent)
            Text(caption.text)
                .font(StrandFont.body)
                .foregroundStyle(caption.isFinal || !caption.fromOwner ? StrandPalette.textPrimary : StrandPalette.textSecondary)
        }
    }

    // MARK: Tap-to-talk + mic mode

    private var isLive: Bool { call.phase == .connected || call.phase == .reconnecting }

    /// The hold-to-talk button (tap-to-talk on), and the switches for tap-to-talk and iOS Mic Mode
    /// (Voice Isolation filters other voices on the phone itself).
    private var talkArea: some View {
        VStack(spacing: 12) {
            if call.isPushToTalk {
                Group {
                    if call.isHoldingTalk { Text("Listening… release to send") } else { Text("Hold to talk") }
                }
                    .font(StrandFont.subhead)
                    .foregroundStyle(call.isHoldingTalk ? StrandPalette.accent : StrandPalette.textSecondary)
                Circle()
                    .fill(call.isHoldingTalk ? StrandPalette.accent : StrandPalette.surfaceInset)
                    .frame(width: 96, height: 96)
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(call.isHoldingTalk ? StrandPalette.surfaceBase : StrandPalette.textPrimary)
                    )
                    .scaleEffect(call.isHoldingTalk ? 1.08 : 1)
                    .animation(.easeOut(duration: 0.12), value: call.isHoldingTalk)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                // Dragging well off the button cancels instead of sending.
                                if hypot(v.translation.width, v.translation.height) > 120 {
                                    call.talkReleased(cancelled: true)
                                } else {
                                    call.talkPressed()
                                }
                            }
                            .onEnded { v in
                                call.talkReleased(cancelled: hypot(v.translation.width, v.translation.height) > 120)
                            }
                    )
                    .accessibilityLabel(Text("Hold to talk"))
                    .accessibilityAddTraits(.isButton)
            }
            HStack(spacing: 20) {
                Button {
                    call.setPushToTalk(!call.isPushToTalk)
                } label: {
                    Group {
                        if call.isPushToTalk {
                            Label("Hands-free", systemImage: "person.wave.2")
                        } else {
                            Label("Tap to talk", systemImage: "hand.tap")
                        }
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                Button {
                    // iOS's own Mic Mode picker (Standard / Voice Isolation / Wide Spectrum).
                    AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                } label: {
                    Label("Mic mode", systemImage: "mic.badge.plus")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(!isLive)
        .opacity(isLive ? 1 : 0.4)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(alignment: .top) {
            controlButton(call.isMuted ? "mic.slash.fill" : "mic.fill",
                          label: call.isMuted ? "Unmute" : "Mute",
                          on: call.isMuted) { call.toggleMute() }
            Spacer()
            VStack(spacing: 8) {
                Button {
                    call.hangUp()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 76, height: 76)
                        .background(Circle().fill(StrandPalette.metricRose))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("End call"))
                Text("End")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            controlButton("speaker.wave.2.fill",
                          label: "Speaker",
                          on: call.isSpeaker) { call.toggleSpeaker() }
        }
        .padding(.horizontal, 12)
        .disabled(!(call.phase == .connected || call.phase == .reconnecting) && !isConnecting)
    }

    private var isConnecting: Bool { call.phase == .connecting }

    private func controlButton(_ symbol: String, label: LocalizedStringKey, on: Bool,
                               action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(on ? StrandPalette.surfaceBase : StrandPalette.textPrimary)
                    .frame(width: 68, height: 68)
                    .background(Circle().fill(on ? StrandPalette.textPrimary : StrandPalette.surfaceInset))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(label))
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

// MARK: - Pulse

/// The "who's talking" visual: rings that breathe slowly while Jarvis listens, quicken while it thinks
/// and swell while it speaks. Driven by the agent's reported state, not by audio levels.
private struct JarvisPulse: View {
    let state: JarvisAgentState
    let active: Bool

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let speed = Self.motion(state).speed
            let depth = Self.motion(state).depth
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = t * speed + Double(i) * 0.9
                    Circle()
                        .stroke(StrandPalette.accent.opacity(0.35 - Double(i) * 0.1), lineWidth: 2)
                        .scaleEffect(active ? 0.72 + Double(i) * 0.12 + sin(phase) * depth : 0.72 + Double(i) * 0.12)
                }
                Circle()
                    .fill(StrandPalette.accent.opacity(active ? 0.9 : 0.4))
                    .scaleEffect(0.5 + (active && state == .speaking ? sin(t * speed * 1.7) * 0.04 : 0))
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(StrandPalette.surfaceBase)
            }
        }
        .accessibilityHidden(true)
    }

    /// How fast and how far the rings move for each agent state.
    static func motion(_ state: JarvisAgentState) -> (speed: Double, depth: Double) {
        switch state {
        case .speaking: return (3.2, 0.16)
        case .thinking: return (1.8, 0.07)
        case .listening: return (0.9, 0.05)
        case .initializing, .idle: return (0.5, 0.03)
        }
    }
}
#endif
