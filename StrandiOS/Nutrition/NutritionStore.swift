#if os(iOS)
import Foundation

// MARK: - Nutrition store: fetch → parse → cache
//
// Owns the sheet rows for the Nutrition tab. Pulls via GoogleSheetsService, parses into MealEntry,
// and caches to Documents/nutrition_cache.json so the tab opens instantly and works offline.

@MainActor
final class NutritionStore: ObservableObject {
    @Published private(set) var entries: [MealEntry] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    /// One shared instance: the fetch must outlive any single view's task (see refreshDetached).
    static let shared = NutritionStore()

    /// True when a service-account credential is reachable (bundle resource or Documents drop-in).
    var hasCredentials: Bool { GoogleServiceAccount.load() != nil }

    private var cacheURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("nutrition_cache.json")
    }

    private struct Cache: Codable {
        let syncedAt: Date
        let entries: [MealEntry]
    }

    private init() { loadCache() }

    /// Load cached rows so the tab renders immediately; callers then refresh() for freshness.
    func loadCache() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        entries = cache.entries
        lastSync = cache.syncedAt
    }

    /// Fire-and-forget refresh for SwiftUI callers. `.task` and `.refreshable` run in a task SwiftUI
    /// CANCELS when the view re-renders or the refresh gesture ends — and a cancelled parent kills
    /// the in-flight URLSession request with URLError.cancelled ("sheet sync failed: cancelled").
    /// An unstructured Task is not tied to that lifetime, so the fetch always runs to completion.
    func refreshDetached(spreadsheetID: String) {
        Task { await refresh(spreadsheetID: spreadsheetID) }
    }

    /// Pull the whole sheet and re-parse. Errors land in `errorMessage`; stale cache stays on screen.
    func refresh(spreadsheetID: String) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await fetchWithRetry(spreadsheetID: spreadsheetID)
            let parsed = Self.parse(rows)
            entries = parsed
            lastSync = Date()
            errorMessage = nil
            if let url = cacheURL,
               let data = try? JSONEncoder().encode(Cache(syncedAt: Date(), entries: parsed)) {
                try? data.write(to: url, options: .atomic)
            }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// One automatic retry after a beat for transient cancellation; then the error surfaces.
    private func fetchWithRetry(spreadsheetID: String) async throws -> [[Any]] {
        do {
            return try await GoogleSheetsService.shared.fetchRows(spreadsheetID: spreadsheetID)
        } catch let e as URLError where e.code == .cancelled {
            try await Task.sleep(nanoseconds: 600_000_000)
            return try await GoogleSheetsService.shared.fetchRows(spreadsheetID: spreadsheetID)
        }
    }

    /// Errors users can act on. URLError carries almost nothing in localizedDescription ("cancelled"),
    /// so append the domain/code for support.
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return "The request was cancelled before it finished — pull to refresh to try again. (NSURLErrorDomain \(urlError.code.rawValue))"
            }
            return "\(urlError.localizedDescription) (NSURLErrorDomain \(urlError.code.rawValue))"
        }
        return error.localizedDescription
    }

    // MARK: - Parsing

    /// Sheet rows → entries. Skips the header row; tolerates short rows, thousand separators,
    /// and dates given as text (YYYY-MM-DD and common locale shapes) or Sheets serial numbers.
    static func parse(_ rows: [[Any]]) -> [MealEntry] {
        var out: [MealEntry] = []
        for row in rows {
            func cell(_ i: Int) -> Any? { i < row.count ? row[i] : nil }
            func string(_ i: Int) -> String {
                if let s = cell(i) as? String { return s.trimmingCharacters(in: .whitespaces) }
                if let n = cell(i) as? NSNumber { return n.stringValue }
                return ""
            }
            func number(_ i: Int) -> Double {
                if let n = cell(i) as? NSNumber { return n.doubleValue }
                if let s = cell(i) as? String {
                    return Double(s.replacingOccurrences(of: ",", with: "")
                                    .trimmingCharacters(in: .whitespaces)) ?? 0
                }
                return 0
            }

            guard let rawDate = cell(0) else { continue }
            let dateText = string(0)
            // Header row ("Date", "Meal Name", …) — skip.
            if dateText.caseInsensitiveCompare("date") == .orderedSame { continue }
            guard let dayKey = normalizeDate(rawDate) else { continue }

            let name = string(1)
            let calories = number(2), protein = number(3), carbs = number(4), fat = number(5)
            // A row with no name and all-zero macros is padding, not a log.
            guard !name.isEmpty || calories > 0 || protein > 0 || carbs > 0 || fat > 0 else { continue }

            out.append(MealEntry(date: dayKey, name: name.isEmpty ? "Meal" : name,
                                 calories: calories, proteinG: protein, carbsG: carbs, fatG: fat,
                                 notes: string(6)))
        }
        return out.sorted { ($0.date, $0.name) < ($1.date, $1.name) }
    }

    /// Normalise a date cell to YYYY-MM-DD. Accepts strings ("2026-11-08", "11/8/2026", "8/11/2026"
    /// when unambiguous, "Nov 8 2026"…) and Sheets/Excel serial numbers (days since 1899-12-30).
    private static func normalizeDate(_ raw: Any) -> String? {
        if let n = raw as? NSNumber {
            // Sheets serial day number.
            let serial = n.doubleValue
            guard serial > 20000, serial < 80000 else { return nil }   // ~1954…~2088
            let base = NutritionMath.dayFormatter.date(from: "1899-12-30")!
            let d = Date(timeInterval: serial * 86400, since: base)
            return NutritionMath.dayKey(d)
        }
        guard let s0 = raw as? String else { return nil }
        let s = s0.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let d = NutritionMath.dayFormatter.date(from: s) { return NutritionMath.dayKey(d) }
        // Fallback shapes for sheets whose Date column is formatted differently.
        let formats = ["M/d/yyyy", "M/d/yy", "d/M/yyyy", "yyyy/M/d", "MMM d, yyyy", "d MMM yyyy", "yyyy.MM.dd"]
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return NutritionMath.dayKey(d) }
        }
        return nil
    }
}
#endif
