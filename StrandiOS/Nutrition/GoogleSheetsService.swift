#if os(iOS)
import Foundation
import Security

// MARK: - Google Sheets service (service-account auth, no third-party deps)
//
// The Python spec authenticates with `gspread` + a service-account JSON key. On iOS there is no
// Python, so this does the equivalent directly: build a JWT (RS256), exchange it at the OAuth
// token endpoint, then call the Sheets v4 values endpoint. The credential JSON ships as a bundle
// resource (injected by CI from the GOOGLE_SERVICE_ACCOUNT_JSON secret, or dropped into the app's
// Documents folder via Files for local builds) and never leaves the device except to
// oauth2.googleapis.com and sheets.googleapis.com.

/// The service-account JSON key (subset of fields we need).
struct GoogleServiceAccount: Codable {
    let clientEmail: String
    let privateKey: String
    let tokenURI: String

    enum CodingKeys: String, CodingKey {
        case clientEmail = "client_email"
        case privateKey = "private_key"
        case tokenURI = "token_uri"
    }

    /// Load from the app's Documents folder first (Files-app drop-in for local/dev builds), then
    /// fall back to the bundle resource baked in by CI. nil = not configured.
    static func load() -> GoogleServiceAccount? {
        var candidates: [URL] = []
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs.appendingPathComponent("GoogleServiceAccount.json"))
        }
        if let bundled = Bundle.main.url(forResource: "GoogleServiceAccount", withExtension: "json") {
            candidates.append(bundled)
        }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let account = try? JSONDecoder().decode(GoogleServiceAccount.self, from: data) else { continue }
            return account
        }
        return nil
    }
}

enum NutritionSyncError: LocalizedError {
    case noCredentials
    case badPrivateKey
    case tokenExchangeFailed(String)
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No Google service-account credential found. Add GoogleServiceAccount.json to the app bundle (CI secret) or drop it into the app's Documents folder via Files."
        case .badPrivateKey:
            return "The service-account private key could not be imported."
        case .tokenExchangeFailed(let detail):
            return "Google rejected the credential: \(detail)"
        case .http(let code, let body):
            if code == 403 {
                return "403 from Google Sheets — enable the Google Sheets API in Google Cloud Console (project vmformarketdata) and share the sheet with the service-account email. \(body)"
            }
            if code == 404 {
                return "404 from Google Sheets — the Spreadsheet ID looks wrong, or the sheet isn't shared with the service-account email."
            }
            return "Google Sheets returned HTTP \(code): \(body)"
        case .badResponse:
            return "Unexpected response from Google."
        }
    }
}

/// Fetches nutrition rows from the tracker sheet. Actor so the token cache is race-free.
actor GoogleSheetsService {
    static let shared = GoogleSheetsService()

    private var cachedToken: (value: String, expiresAt: Date)?
    private var cachedKey: SecKey?

    /// Default spreadsheet: the user's "Nutrition & Macro Tracker Logs". Editable in the tab's
    /// settings; this is just the seed value.
    static let defaultSpreadsheetID = "1VlwopqcxEgo-Hnm1ByxU6VYhi1OSn2AQtq6hSVJiSbQ"

    // MARK: Public

    /// Fetch every row of the first worksheet, columns A:G, as raw cell values.
    /// `UNFORMATTED_VALUE` + `FORMATTED_STRING` dates: numbers come as JSON numbers, dates as
    /// strings exactly as displayed — the parser accepts both strings and Sheets serial numbers.
    func fetchRows(spreadsheetID: String) async throws -> [[Any]] {
        guard let account = GoogleServiceAccount.load() else { throw NutritionSyncError.noCredentials }
        let token = try await accessToken(account: account)

        var comps = URLComponents(string: "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetID)/values/A:G")!
        comps.queryItems = [
            URLQueryItem(name: "valueRenderOption", value: "UNFORMATTED_VALUE"),
            URLQueryItem(name: "dateTimeRenderOption", value: "FORMATTED_STRING"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw NutritionSyncError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(600), encoding: .utf8) ?? ""
            // A 401/403 can mean an expired/revoked token — drop the cache so the retry re-mints.
            if http.statusCode == 401 { cachedToken = nil }
            throw NutritionSyncError.http(http.statusCode, body)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["values"] as? [[Any]] else {
            // An empty sheet returns no "values" key at all — that's zero rows, not an error.
            return []
        }
        return values
    }

    // MARK: OAuth token (JWT bearer grant)

    private func accessToken(account: GoogleServiceAccount) async throws -> String {
        if let t = cachedToken, t.expiresAt.timeIntervalSinceNow > 120 { return t.value }

        let key = try signingKey(for: account)
        let now = Date()
        let header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": account.clientEmail,
            "scope": "https://www.googleapis.com/auth/spreadsheets.readonly",
            "aud": account.tokenURI,
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(now.timeIntervalSince1970) + 3600,
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let claimsData = try JSONSerialization.data(withJSONObject: claims)
        let unsigned = Self.base64url(headerData) + "." + Self.base64url(claimsData)

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key,
                                                    .rsaSignatureMessagePKCS1v15SHA256,
                                                    Data(unsigned.utf8) as CFData,
                                                    &error) as Data? else {
            throw NutritionSyncError.badPrivateKey
        }
        let jwt = unsigned + "." + Self.base64url(signature)

        var req = URLRequest(url: URL(string: account.tokenURI)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(jwt)"
            .data(using: .utf8)
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? "no body"
            throw NutritionSyncError.tokenExchangeFailed(body)
        }
        let ttl = (json["expires_in"] as? Double) ?? 3600
        cachedToken = (token, Date().addingTimeInterval(ttl))
        return token
    }

    // MARK: RSA key import (PKCS#8 PEM → PKCS#1 DER → SecKey)

    private func signingKey(for account: GoogleServiceAccount) throws -> SecKey {
        if let cachedKey { return cachedKey }
        let pem = account.privateKey
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\n", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let pkcs8 = Data(base64Encoded: pem),
              let pkcs1 = Self.unwrapPKCS8(pkcs8) else {
            throw NutritionSyncError.badPrivateKey
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw NutritionSyncError.badPrivateKey
        }
        cachedKey = key
        return key
    }

    /// Minimal DER walk of PKCS#8 PrivateKeyInfo — SEQUENCE { version, algorithm, OCTET STRING } —
    /// returning the inner RSAPrivateKey (PKCS#1) blob that SecKeyCreateWithData accepts.
    static func unwrapPKCS8(_ der: Data) -> Data? {
        /// Reads one TLV with the expected tag off the front of the buffer, returning its value.
        func readTLV(_ buffer: inout [UInt8], _ tag: UInt8) -> [UInt8]? {
            guard buffer.count >= 2, buffer[0] == tag else { return nil }
            buffer.removeFirst()
            var length = Int(buffer.removeFirst())
            if length & 0x80 != 0 {
                let n = length & 0x7F
                guard n > 0, n <= 4, buffer.count >= n else { return nil }
                length = 0
                for _ in 0..<n { length = (length << 8) | Int(buffer.removeFirst()) }
            }
            guard buffer.count >= length else { return nil }
            let value = Array(buffer.prefix(length))
            buffer.removeFirst(length)
            return value
        }
        var outer = [UInt8](der)
        guard var seq = readTLV(&outer, 0x30) else { return nil }
        guard readTLV(&seq, 0x02) != nil else { return nil }   // version INTEGER
        guard readTLV(&seq, 0x30) != nil else { return nil }   // algorithm identifier SEQUENCE
        guard let octets = readTLV(&seq, 0x04), !octets.isEmpty else { return nil }  // privateKey OCTET STRING
        return Data(octets)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
