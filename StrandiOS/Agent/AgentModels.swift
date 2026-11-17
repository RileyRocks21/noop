#if os(iOS)
import Foundation

// MARK: - Agent API models (the noop-agent backend contract)
//
// Codable mirrors of the handoff's "API and WebSocket contract" section. camelCase on the wire
// (the backend's default), UUID-string ids, ISO-8601 UTC timestamps. Type names get an `Agent`
// prefix where the bare name would collide with Swift/Foundation (`Task`, `Event`, `Memory`).

struct AgentTask: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var notes: String?
    var source: String?          // "manual" | "brightspace" | "email" | "agent"
    var dueAt: Date?
    var priority: String?        // "low" | "normal" | "high" | "critical"
    var status: String?          // "open" | "done" | "snoozed"
    var snoozedUntil: Date?
}

struct AgentDueItem: Codable, Identifiable, Equatable {
    var id: String
    var course: String?
    var title: String
    var dueAt: Date?
    var type: String?
    var url: String?
}

struct AgentEvent: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var startAt: Date?
    var endAt: Date?
    var location: String?
}

struct AgentEmail: Codable, Identifiable, Equatable {
    var id: String
    var from: String?
    var subject: String?
    var summary: String?
    var receivedAt: Date?
    var category: String?        // "action" | "fyi" | "ignore"
    var taskId: String?
}

struct AgentApproval: Codable, Identifiable, Equatable {
    var id: String
    var action: String?
    var summary: String?
    var reason: String?
    var payload: String?
    var status: String?          // "pending" | "approved" | "rejected"
    var createdAt: Date?
}

struct AgentChatMessage: Codable, Identifiable, Equatable {
    struct ToolRef: Codable, Equatable {
        var name: String
        var label: String?
    }
    var id: String
    var role: String             // "user" | "assistant" | "system"
    var text: String
    var channel: String?         // "chat" | "voice" | "system"
    var createdAt: Date?
    var tools: [ToolRef]?
}

struct AgentBrief: Codable, Equatable {
    var script: String
    var audioUrl: String?
    var createdAt: Date?
}

struct AgentHealth: Codable, Equatable {
    var recovery: Double?
    var hrvMs: Double?
    var rhr: Double?
    var sleepHours: Double?
    var sleepPerformance: Double?
    var strain: Double?
    var kcalBurned: Double?
}

struct AgentWeather: Codable, Equatable {
    var summary: String?
    var tempC: Double?
    var bestRunWindow: String?
}

struct AgentToday: Codable, Equatable {
    var brief: AgentBrief?
    var health: AgentHealth?
    var nutrition: Nutrition?
    var due: [AgentDueItem]?
    var events: [AgentEvent]?
    var weather: AgentWeather?

    struct Nutrition: Codable, Equatable {
        var kcalIn: Double?
    }
}

struct AgentAuthRequest: Codable, Identifiable, Equatable {
    var id: String
    var site: String?
    var reason: String?
    var liveViewUrl: String?
    var expiresAt: Date?
    var status: String?          // "pending" | "completed" | "expired"
}

struct AgentDevSession: Codable, Identifiable, Equatable {
    var id: String
    var repo: String?
    var task: String?
    var status: String?          // "running" | "done" | "failed" | "stopped"
    var costUsd: Double?
    var startedAt: Date?
    var endedAt: Date?
}

struct AgentMemory: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var source: String?
    var pinned: Bool?
}

struct AgentRun: Codable, Identifiable, Equatable {
    var id: String
    var trigger: String?
    var summary: String?
    var costUsd: Double?
    var createdAt: Date?
}

struct AgentIntegration: Codable, Identifiable, Equatable {
    var provider: String
    var status: String?          // "ok" | "needs_auth" | "failing"
    var lastSyncAt: Date?
    var connectUrl: String?
    var id: String { provider }
}

struct AgentSettings: Codable, Equatable {
    struct QuietHours: Codable, Equatable {
        var start: String?       // "23:30"
        var end: String?         // "07:00"
    }
    struct WatchSymbol: Codable, Equatable, Identifiable {
        var symbol: String
        var movePct: Double?
        var id: String { symbol }
    }
    var quietHours: QuietHours?
    /// Category → level ("off" | "brief" | "silent" | "sound" | "call").
    var levels: [String: String]?
    var watchlist: [WatchSymbol]?
    var icalUrl: String?
}

// MARK: - Envelope helpers

struct AgentPairResponse: Codable {
    var deviceId: String
    var token: String
}

struct AgentHealthResponse: Codable {
    var ok: Bool?
    var version: String?
}

struct AgentMessagesPage: Codable {
    var messages: [AgentChatMessage]
    var nextBefore: String?
}

struct AgentSendResponse: Codable {
    var messageId: String
}

// MARK: - Shared coders

enum AgentCoders {
    /// ISO-8601 with fractional seconds first (what the backend emits), plain seconds as fallback.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Not an ISO-8601 date: \(s)")
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
#endif

#if os(iOS)
/// `POST /voice/session` → a LiveKit room the server's voice agent is already dispatched into.
struct AgentVoiceSession: Decodable {
    var url: String
    var room: String
    var token: String
    var expiresAt: String?
}
#endif
