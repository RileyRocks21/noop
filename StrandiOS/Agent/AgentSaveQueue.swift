import Foundation

// MARK: - Latest-wins save queue
//
// The pure half of Agent Settings saving. A PUT /settings carries the whole object, so only the
// newest draft matters: an edit made while a save is in flight is held (replacing any older held
// draft) and sent as soon as that save finishes. Nothing is dropped and nothing is sent twice.
// Free of SwiftUI and networking so StrandTests compiles it directly (see project.yml).

struct AgentSaveQueue<Value> {
    /// The newest draft not yet handed to a save.
    private(set) var pending: Value?
    /// Whether a save is currently on the wire.
    private(set) var inFlight = false
    /// The newest draft the user made, until every save that carries it has finished. Lets a view
    /// that reopens mid-save start from the user's edit rather than the older server copy.
    private(set) var latest: Value?

    /// True while any local edit has not yet been answered by the server.
    var isDirty: Bool { inFlight || pending != nil }

    /// Stage a new draft. Replaces any older draft still waiting.
    mutating func enqueue(_ value: Value) {
        pending = value
        latest = value
    }

    /// Hand out the draft to send now, or nil when a save is already in flight or nothing waits.
    mutating func begin() -> Value? {
        guard !inFlight, let value = pending else { return nil }
        pending = nil
        inFlight = true
        return value
    }

    /// Mark the in-flight save as done. Returns true when a newer draft is waiting to be sent.
    mutating func finish() -> Bool {
        inFlight = false
        if pending == nil { latest = nil }
        return pending != nil
    }
}

// MARK: - Brightspace iCal URL validation

enum AgentICalURL: Equatable {
    /// The field is blank: clear the feed.
    case empty
    /// A usable http(s) URL, trimmed.
    case valid(String)
    /// Something that is not an http(s) URL with a host.
    case invalid

    static func validate(_ raw: String) -> AgentICalURL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return .invalid }
        return .valid(trimmed)
    }
}
