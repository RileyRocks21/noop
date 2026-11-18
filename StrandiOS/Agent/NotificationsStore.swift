#if os(iOS)
import Foundation

// MARK: - Notification history store
//
// GET /notifications → everything the agent wanted to tell the wearer, newest first: pushed, held for
// quiet hours / the morning brief, or switched off for its category. It is the place to look back while
// push notifications aren't reaching the phone. POST /notifications/read marks them seen. The server
// sends `notifications.updated` whenever one is stored or read, so the list and badge stay live.

struct AgentNotification: Codable, Identifiable, Equatable {
    var id: String
    var kind: String?
    var title: String
    var body: String?
    var category: String?        // "school" | "email" | "health" | "markets" | "reminders"
    var priority: String?
    var deeplink: String?
    var createdAt: Date?
    var readAt: Date?
    var status: String?          // "sent" | "shown" | "held" | "brief" | "off"
}

@MainActor
final class NotificationsStore: ObservableObject {
    static let shared = NotificationsStore()

    @Published private(set) var items: [AgentNotification] = []
    @Published private(set) var unread = 0
    @Published private(set) var isLoading = false
    @Published private(set) var reachedEnd = false
    @Published var errorMessage: String?

    private static let pageSize = 100
    private var subscription: UUID?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        AgentSocketHub.shared.start()
        subscription = AgentSocketHub.shared.subscribe(
            handler: { [weak self] event in
                guard event.type == "notifications.updated" || event.type == "notification" else { return }
                Task { @MainActor in await self?.refresh() }
            },
            onRefetch: { [weak self] in
                Task { @MainActor in await self?.refresh() }
            })
        Task { await refresh() }
    }

    private struct Page: Decodable {
        let notifications: [AgentNotification]
        let unread: Int
    }

    /// Reload the newest page (keeps any older pages already loaded beyond it).
    func refresh() async {
        // Runs outside the caller's task: SwiftUI cancels a pull-to-refresh task when the list re-renders
        // mid-request, which showed up as URLError -999 instead of fresh data.
        await Task { await self.load() }.value
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page = try await AgentAPI.shared.get("/notifications",
                                                           query: ["limit": String(Self.pageSize)])
            let fresh = page.notifications
            let freshIDs = Set(fresh.map(\.id))
            let oldest = fresh.last?.createdAt ?? .distantFuture
            // Older rows from earlier "load more" pages that this page doesn't cover.
            let older = items.filter { !freshIDs.contains($0.id) && ($0.createdAt ?? .distantPast) < oldest }
            items = fresh + older
            unread = page.unread
            if older.isEmpty { reachedEnd = fresh.count < Self.pageSize }
            errorMessage = nil
        } catch {
            if !AgentErrors.isCancellation(error) { errorMessage = NutritionStore.describe(error) }
        }
    }

    /// Next page of older notifications.
    func loadMore() async {
        guard !isLoading, !reachedEnd, let last = items.last?.createdAt else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page = try await AgentAPI.shared.get("/notifications", query: [
                "limit": String(Self.pageSize),
                "before": AgentNotificationDates.iso.string(from: last),
            ])
            let known = Set(items.map(\.id))
            items += page.notifications.filter { !known.contains($0.id) }
            unread = page.unread
            reachedEnd = page.notifications.count < Self.pageSize
        } catch {
            if !AgentErrors.isCancellation(error) { errorMessage = NutritionStore.describe(error) }
        }
    }

    /// Mark everything seen. Optimistic: the dots clear at once, the server count follows.
    func markAllRead() {
        guard unread > 0 || items.contains(where: { $0.readAt == nil }) else { return }
        let now = Date()
        items = items.map { var n = $0; if n.readAt == nil { n.readAt = now }; return n }
        unread = 0
        struct Body: Encodable {}
        struct Result: Decodable { let unread: Int }
        Task {
            do {
                let r: Result = try await AgentAPI.shared.post("/notifications/read", body: Body())
                unread = r.unread
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }
}

enum AgentNotificationDates {
    /// Matches the server's `toISOString()` (milliseconds, UTC) so `before` paging is exact.
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
#endif
