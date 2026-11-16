#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Approvals screen (More → Approvals)
//
// The queue of actions the agent wants permission to take. Each card shows what it wants to do
// and why; Approve / Reject act immediately, Edit opens a sheet to adjust the payload before
// approving. New approvals also arrive live over the socket (approval.created) and bump the
// More-tab badge via ApprovalsStore.pendingCount.

struct ApprovalsView: View {
    @ObservedObject private var config = AgentConfig.shared
    @ObservedObject private var store = ApprovalsStore.shared
    @State private var editing: AgentApproval?
    @State private var editedPayload = ""

    var body: some View {
        Group {
            if config.isPaired {
                content
            } else {
                PairingView()
            }
        }
        .onAppear { store.start() }
    }

    private var content: some View {
        ScreenScaffold(title: "Approvals",
                       subtitle: store.pending.isEmpty ? "Nothing waiting" : "\(store.pending.count) waiting on you",
                       onRefresh: { await store.refresh() },
                       topBackground: liquidScaffoldSky()) {
            if let error = store.errorMessage {
                DataPendingNote(title: "Approvals", message: LocalizedStringKey(error),
                                symbol: "exclamationmark.triangle.fill")
            }
            ForEach(store.pending) { approval in
                approvalCard(approval)
            }
            if store.pending.isEmpty && !store.isLoading {
                Text("When the agent wants to send, buy or post something, it asks here first.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .sheet(item: $editing) { approval in
            editSheet(approval)
        }
    }

    private func approvalCard(_ approval: AgentApproval) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text((approval.action ?? "Action").uppercased())
                        .strandOverline()
                    Spacer()
                    if let at = approval.createdAt {
                        Text(at, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                if let summary = approval.summary {
                    Text(summary)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason = approval.reason {
                    Text(reason)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button {
                        store.decide(approval, decision: .approve)
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                            .font(StrandFont.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Capsule().fill(StrandPalette.accent))
                    }
                    .buttonStyle(.plain)
                    Button {
                        store.decide(approval, decision: .reject)
                    } label: {
                        Label("Reject", systemImage: "xmark")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.metricRose)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Capsule().stroke(StrandPalette.metricRose, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("Edit…") {
                        editedPayload = approval.payload ?? ""
                        editing = approval
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
                }
                .padding(.top, 2)
            }
        }
    }

    private func editSheet(_ approval: AgentApproval) -> some View {
        NavigationStack {
            Form {
                Section("What the agent will do") {
                    Text(approval.summary ?? "")
                        .font(.subheadline)
                }
                Section("Edit the payload before approving") {
                    TextEditor(text: $editedPayload)
                        .frame(minHeight: 140)
                }
            }
            .navigationTitle("Edit & approve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editing = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve edited") {
                        store.decide(approval, decision: .edit, editedPayload: editedPayload)
                        editing = nil
                    }
                }
            }
        }
    }
}
#endif
