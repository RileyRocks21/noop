import Foundation

// MARK: - Task action helpers
//
// Pure date and text logic behind the Tasks screen: snooze presets and the link found in a task's
// notes. Kept free of SwiftUI and of the stores so every decision can be checked with a fixed clock
// and calendar.

/// Snooze presets offered on a task. Every preset resolves strictly after `now`.
enum SnoozePreset: String, CaseIterable, Identifiable {
    case hour, tonight, tomorrow, nextWeek
    var id: String { rawValue }

    /// From this hour on, "Tonight" (20:00) is too close or already past, so it is not offered.
    static let tonightCutoffHour = 19

    var label: String {
        switch self {
        case .hour:     return String(localized: "Snooze 1 h")
        case .tonight:  return String(localized: "Tonight")
        case .tomorrow: return String(localized: "Tomorrow")
        case .nextWeek: return String(localized: "Next week")
        }
    }

    /// Presets that make sense at `now`: "Tonight" is dropped from 19:00 on.
    static func available(at now: Date, calendar: Calendar = .current) -> [SnoozePreset] {
        let hour = calendar.component(.hour, from: now)
        return allCases.filter { $0 != .tonight || hour < tonightCutoffHour }
    }

    /// The snooze-until instant: +1 hour, tonight 20:00, tomorrow 08:00, or next Monday 08:00.
    /// Anything that would land at or before `now` falls back to tomorrow 08:00.
    func date(from now: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        func at8(daysAhead: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: daysAhead, to: startOfToday) ?? startOfToday
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)
                ?? day.addingTimeInterval(8 * 3600)
        }
        let candidate: Date
        switch self {
        case .hour:
            candidate = now.addingTimeInterval(3600)
        case .tonight:
            candidate = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now
        case .tomorrow:
            candidate = at8(daysAhead: 1)
        case .nextWeek:
            // Gregorian weekday numbering: Sunday = 1, Monday = 2. Today being Monday means a week out.
            let weekday = calendar.component(.weekday, from: now)
            let days = (2 - weekday + 7) % 7
            candidate = at8(daysAhead: days == 0 ? 7 : days)
        }
        if candidate > now { return candidate }
        let fallback = at8(daysAhead: 1)
        return fallback > now ? fallback : now.addingTimeInterval(3600)
    }
}

/// Links inside a task's notes (Brightspace tasks carry the course on one line and the URL on the next).
enum TaskLinks {
    /// The first http(s) URL in `notes`, if any.
    static func firstURL(in notes: String?) -> URL? {
        guard let notes, !notes.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(notes.startIndex..., in: notes)
        for match in detector.matches(in: notes, options: [], range: range) {
            if let url = match.url, let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return url
            }
        }
        return nil
    }

    /// The notes with any line that is only a link removed, so the link is not shown twice beside
    /// its own button. Returns nil when nothing readable is left.
    static func displayText(for notes: String?) -> String? {
        guard let notes else { return nil }
        let kept = notes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if let url = firstURL(in: line), url.absoluteString == line { return false }
                return true
            }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }
}
