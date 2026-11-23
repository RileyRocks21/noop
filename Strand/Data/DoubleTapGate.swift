import Foundation

/// How many strap double-taps it takes to run the configured double-tap action.
///
/// The strap firmware decides what counts as a double-tap and its accelerometer threshold cannot be
/// tuned from the app, so a knock against a desk or a bag can register as one. This setting is a
/// software confirmation on top: the lower the sensitivity, the more deliberate double-taps the action
/// needs inside a short window. Raw values are persisted (`BehaviorStore`), so never rename a case.
enum DoubleTapSensitivity: String, CaseIterable, Identifiable {
    /// One double-tap runs the action (the behavior before this setting existed).
    case standard
    /// Two double-taps within 4 seconds.
    case low
    /// Three double-taps within 6 seconds.
    case lowest

    var id: String { rawValue }

    /// Double-taps needed to run the action.
    var requiredTaps: Int {
        switch self {
        case .standard: return 1
        case .low:      return 2
        case .lowest:   return 3
        }
    }

    /// Seconds within which all `requiredTaps` must land, measured from the first of them.
    var window: TimeInterval {
        switch self {
        case .standard: return 0
        case .low:      return 4
        case .lowest:   return 6
        }
    }

    var label: String {
        switch self {
        case .standard: return String(localized: "Standard")
        case .low:      return String(localized: "Low")
        case .lowest:   return String(localized: "Lowest")
        }
    }

    /// One line explaining what the user has to do at this sensitivity.
    var help: String {
        switch self {
        case .standard: return String(localized: "One double-tap runs the action.")
        case .low:      return String(localized: "Double-tap twice within 4 seconds to run the action.")
        case .lowest:   return String(localized: "Double-tap three times within 6 seconds to run the action.")
        }
    }
}

/// Counts strap double-taps toward the confirmation `DoubleTapSensitivity` asks for. Pure and
/// clock-free (the caller passes the time), so it is unit-tested without a strap.
///
/// The window slides: a tap older than `window` before the newest one is forgotten, so a stray knock
/// followed much later by a deliberate pair still confirms on that pair rather than on the knock.
struct DoubleTapGate {

    enum Decision: Equatable {
        /// Enough double-taps landed inside the window: run the action. The count is reset.
        case fire
        /// Counted, still waiting for more: `count` of `required` inside `window` seconds.
        case armed(count: Int, required: Int, window: TimeInterval)
    }

    /// Changing the sensitivity drops any half-finished sequence, so taps counted under one setting
    /// cannot complete a sequence under another.
    var sensitivity: DoubleTapSensitivity {
        didSet { if sensitivity != oldValue { pending.removeAll() } }
    }

    private var pending: [Date] = []

    init(sensitivity: DoubleTapSensitivity = .low) {
        self.sensitivity = sensitivity
    }

    /// Double-taps counted toward the current sequence (0 when idle).
    var pendingCount: Int { pending.count }

    /// Count one double-tap at `now` and say whether the action should run.
    mutating func register(at now: Date) -> Decision {
        let required = sensitivity.requiredTaps
        guard required > 1 else {
            pending.removeAll()
            return .fire
        }
        let window = sensitivity.window
        pending.removeAll { now.timeIntervalSince($0) > window || $0 > now }
        pending.append(now)
        if pending.count >= required {
            pending.removeAll()
            return .fire
        }
        return .armed(count: pending.count, required: required, window: window)
    }

    /// Forget any half-finished sequence.
    mutating func reset() {
        pending.removeAll()
    }
}
