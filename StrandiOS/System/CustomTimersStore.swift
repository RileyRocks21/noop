#if os(iOS)
import Foundation
import UserNotifications

// MARK: - Custom countdown timers
//
// User-set alarms ("oven 12 min", "meeting in 45"): start one with a label + duration and when it
// fires the WATCH buzzes (a message over WatchConnectivity — the watch plays a run of notification
// haptics) and the phone posts a local notification as the backgrounded-app backup. Timers are
// persisted to UserDefaults so a relaunch keeps them running; on launch any timer that fired while
// the process was dead delivers its buzz + alert immediately.

struct CustomTimer: Codable, Equatable, Identifiable {
    var id = UUID()
    var label: String
    var durationSeconds: TimeInterval
    var fireAt: Date

    var remaining: TimeInterval { max(0, fireAt.timeIntervalSinceNow) }
}

@MainActor
final class CustomTimersStore: ObservableObject {
    static let shared = CustomTimersStore()

    @Published private(set) var timers: [CustomTimer] = []
    /// Republished every tick so the countdown text animates without each row owning a Timer.
    @Published private(set) var now = Date()
    /// The label of the timer that just fired while the app was foregrounded — drives the in-app
    /// alert on the timers screen. Cleared when the wearer dismisses it.
    @Published var firedLabel: String?

    private let defaultsKey = "noop.customTimers"
    private var ticker: Timer?

    private init() {
        load()
        startTicker()
        // Catch up anything that fired while the app was dead (UserNotifications may ALSO have shown
        // its banner — fine, the watch still needs its buzz).
        for t in timers where t.remaining <= 0 {
            fire(t)
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([CustomTimer].self, from: data) else { return }
        timers = decoded.sorted { $0.fireAt < $1.fireAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(timers) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: API

    /// Start a timer. Schedules the local-notification backup (fires even if the app is suspended)
    /// and asks for notification permission lazily — the prompt only appears the first time someone
    /// actually starts a timer.
    func start(label: String, durationSeconds: TimeInterval) {
        guard durationSeconds > 0 else { return }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let timer = CustomTimer(label: trimmed.isEmpty ? "Timer" : trimmed,
                                durationSeconds: durationSeconds,
                                fireAt: Date().addingTimeInterval(durationSeconds))
        timers.append(timer)
        timers.sort { $0.fireAt < $1.fireAt }
        persist()
        scheduleNotification(for: timer)
    }

    func cancel(_ timer: CustomTimer) {
        timers.removeAll { $0.id == timer.id }
        persist()
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID(timer)])
    }

    // MARK: Firing

    private func startTicker() {
        // Half-second cadence so the countdown UI doesn't visibly lag the second roll.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        now = Date()
        let due = timers.filter { $0.remaining <= 0 }
        guard !due.isEmpty else { return }
        for t in due { fire(t) }
    }

    private func fire(_ timer: CustomTimer) {
        // Remove FIRST so a fire can't double-deliver from the catch-up pass + the ticker.
        timers.removeAll { $0.id == timer.id }
        persist()
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID(timer)])
        // The actual ask: the WATCH buzzes.
        WatchSessionBridge.shared.sendMessageToWatch([
            WatchSessionBridge.timerDoneKey: timer.label,
            "duration": timer.durationSeconds
        ])
        firedLabel = timer.label
    }

    // MARK: Local-notification backup

    private static func notificationID(_ timer: CustomTimer) -> String {
        "noop.timer.\(timer.id.uuidString)"
    }

    private func scheduleNotification(for timer: CustomTimer) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Timer finished")
            content.body = timer.label
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, timer.fireAt.timeIntervalSinceNow), repeats: false)
            let request = UNNotificationRequest(identifier: Self.notificationID(timer),
                                                content: content, trigger: trigger)
            center.add(request)
        }
    }
}
#endif
