#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Jarvis tab
//
// The one tab that holds everything the noop-agent backend does for the wearer: Chat, Tasks, Inbox and
// Approvals behind a pinned segmented switcher. The health app keeps its original tab bar (Today,
// Trends, Sleep, …); the agent is a single destination inside it rather than owning the bar.
//
// Each section is the existing screen, unchanged — they keep their own in-content titles, pairing
// gates and refresh. JarvisView only adds the switcher and the routing state that lets Today's Jarvis
// card (and the shell) land on a specific section.

/// The four sections of the Jarvis tab, in switcher order.
enum JarvisSection: String, CaseIterable, Identifiable {
    case chat, tasks, inbox, approvals

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .chat: return "Chat"
        case .tasks: return "Tasks"
        case .inbox: return "Inbox"
        case .approvals: return "Approvals"
        }
    }
}

/// Which Jarvis section is showing. Shared so a Today card or a cross-screen request can pick the
/// section before the shell switches to the Jarvis tab, and the switch lands on it directly.
@MainActor
final class JarvisRouter: ObservableObject {
    static let shared = JarvisRouter()
    @Published var section: JarvisSection = .chat
    private init() {}
}

struct JarvisView: View {
    @ObservedObject private var config = AgentConfig.shared
    @ObservedObject private var router = JarvisRouter.shared

    var body: some View {
        if config.isPaired {
            selectedSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Pinned above whichever section is showing. A safe-area inset (not a VStack row) so each
                // section's own scroll content and background run underneath it and insets correctly.
                .safeAreaInset(edge: .top, spacing: 0) { switcher }
        } else {
            // One pairing screen for the whole tab, instead of one per section.
            PairingView()
        }
    }

    @ViewBuilder
    private var selectedSection: some View {
        switch router.section {
        case .chat: ChatView()
        case .tasks: TasksView()
        case .inbox: InboxView()
        case .approvals: ApprovalsView()
        }
    }

    private var switcher: some View {
        Picker(selection: $router.section) {
            ForEach(JarvisSection.allCases) { section in
                Text(section.title).tag(section)
            }
        } label: {
            Text("Jarvis")
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, NoopMetrics.screenHPadding)
        .padding(.vertical, 8)
        .background(StrandPalette.surfaceBase.opacity(0.94).ignoresSafeArea(edges: .top))
    }
}
#endif
