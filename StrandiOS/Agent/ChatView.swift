#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Chat tab
//
// The streaming conversation with the agent. Unpaired → the Pairing screen stands in its place.
// Paired → history + an input bar; replies stream in over the WebSocket (message.delta) and tool
// activity renders as small chips ("Checked Brightspace") under the assistant bubble. When the
// socket drops, a small offline banner appears and the socket reconnects with backoff.

struct ChatView: View {
    @ObservedObject private var config = AgentConfig.shared
    @ObservedObject private var hub = AgentSocketHub.shared
    @ObservedObject private var store = ChatStore.shared
    @State private var draft = ""

    var body: some View {
        if config.isPaired {
            chatContent
                .onAppear {
                    store.start()
                    // A prompt staged while Chat wasn't on screen (Today's Jarvis card opens Jarvis on
                    // Chat, which creates this view fresh) never fires onChange — take it here.
                    if let prompt = store.pendingPrompt { draft = prompt; store.pendingPrompt = nil }
                }
                .onChange(of: store.pendingPrompt) { _, prompt in
                    // "Open chat about it" from a Today card: drop the prompt into the draft for
                    // review, don't auto-send.
                    if let prompt { draft = prompt; store.pendingPrompt = nil }
                }
        } else {
            PairingView()
        }
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            if !hub.isOnline {
                Text("Offline — reconnecting to your server…")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(StrandPalette.gold.opacity(0.15))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if store.nextBefore != nil {
                            Button(store.isLoadingHistory ? "Loading…" : "Load earlier messages") {
                                Task { await store.loadOlder() }
                            }
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.accent)
                            .padding(.top, 8)
                        }

                        ForEach(store.messages) { message in
                            bubble(for: message)
                                .id(message.id)
                        }

                        if let streamingId = store.streamingId {
                            assistantBubble(text: store.streamingText + " ▍",
                                            chips: store.toolChips[streamingId] ?? [])
                                .id(streamingId)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .onChange(of: store.messages.count) { _, _ in
                    if let last = store.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: store.streamingText) { _, _ in
                    if let id = store.streamingId {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }

            if let error = store.errorMessage {
                Text(error)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.metricRose)
                    .padding(.horizontal, 14)
            }

            // Input bar
            HStack(spacing: 10) {
                TextField("Message your agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(StrandPalette.surfaceInset))
                Button {
                    store.send(draft)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSending)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(StrandPalette.surfaceBase)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Bubbles

    @ViewBuilder
    private func bubble(for message: AgentChatMessage) -> some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(StrandPalette.accent))
            }
        } else if message.role == "assistant" {
            assistantBubble(text: message.text, chips: message.tools ?? store.toolChips[message.id] ?? [])
        }
        // system messages are intentionally not rendered in the chat stream
    }

    private func assistantBubble(text: String, chips: [AgentChatMessage.ToolRef]) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                if !chips.isEmpty {
                    // Tool activity chips, newest last: "Checked Brightspace" etc.
                    FlowChips(chips: chips)
                }
                Text(text)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StrandPalette.surfaceInset))
            Spacer(minLength: 48)
        }
    }
}

/// Left-wrapping row of tool chips. Simple HStack-wrap by width estimate is enough for chips;
/// they are short labels and few per message.
private struct FlowChips: View {
    let chips: [AgentChatMessage.ToolRef]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text(chip.label ?? chip.name)
                        .font(StrandFont.footnote)
                }
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(StrandPalette.surfaceBase))
            }
        }
    }
}
#endif
