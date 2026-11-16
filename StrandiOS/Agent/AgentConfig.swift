#if os(iOS)
import Foundation

// MARK: - Agent connection config + token storage
//
// The pairing state for the noop-agent backend: the server URL lives in UserDefaults (not secret —
// it's a Tailscale/LAN address), the long-lived device token lives in the Keychain (same Security-
// framework idiom as AIKeyStore, never plain storage, per the handoff). A 401 from any call routes
// through `handleUnauthorized`, which clears the token — the UI observes `isPaired` and drops back
// to the Pairing screen.

@MainActor
final class AgentConfig: ObservableObject {
    static let shared = AgentConfig()

    /// Editable in Settings → Server. No default: the backend runs on the owner's own machine over
    /// Tailscale, so there is no URL to ship.
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.urlKey) }
    }
    /// Set by a successful pair, cleared by unpair / a 401 anywhere.
    @Published private(set) var isPaired: Bool
    /// The paired device id, shown in Settings so support questions have something to point at.
    @Published private(set) var deviceId: String?
    /// Last successful GET /health version string, shown in Settings → Server.
    @Published var backendVersion: String? {
        didSet { UserDefaults.standard.set(backendVersion, forKey: Self.versionKey) }
    }

    private static let urlKey = "noop.agent.serverURL"
    private static let versionKey = "noop.agent.backendVersion"

    private init() {
        serverURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        deviceId = UserDefaults.standard.string(forKey: Self.deviceIdKey)
        backendVersion = UserDefaults.standard.string(forKey: Self.versionKey)
        isPaired = Self.readToken() != nil
    }

    // MARK: Pairing lifecycle

    func didPair(deviceId: String, token: String) {
        Self.saveToken(token)
        UserDefaults.standard.set(deviceId, forKey: Self.deviceIdKey)
        self.deviceId = deviceId
        isPaired = true
    }

    func unpair() {
        Self.clearToken()
        UserDefaults.standard.removeObject(forKey: Self.deviceIdKey)
        deviceId = nil
        isPaired = false
    }

    /// A 401 anywhere means the token is dead — clear it and let the UI return to pairing.
    func handleUnauthorized() {
        unpair()
    }

    /// The bearer token for API calls and the WebSocket query parameter. nil when unpaired.
    nonisolated var token: String? { Self.readToken() }

    /// Base URL for requests, normalised: trims whitespace/trailing slashes and prefixes http://
    /// when the owner typed a bare host. nil when the field is empty.
    var baseURL: URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    // MARK: Keychain (service "com.noop.agent")

    private static let deviceIdKey = "noop.agent.deviceId"
    private static let service = "com.noop.agent"
    private static let account = "device-token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func saveToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private static func readToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }

    private static func clearToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
#endif
