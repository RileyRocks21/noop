#if os(iOS)
import Foundation

// MARK: - Nutrition store: local meal log (the source of truth)
//
// Meals are logged IN the app now (manual / AI text / AI photo / barcode) and stored on-device as
// JSON in Documents/nutrition_log.json. The Google Sheet path survives as an explicit one-time
// import (importFromSheet) so existing history carries across; it is no longer the live source.

/// One logged meal. Distinct from MealEntry by carrying a stable UUID (two identical meals on one
/// day must not share a SwiftUI id) plus provenance + creation time.
struct LoggedMeal: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: String        // YYYY-MM-DD local day key
    var name: String
    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var notes: String
    var source: String      // "manual" | "ai-text" | "ai-photo" | "barcode" | "sheet"
    var createdAt = Date()

    var asMealEntry: MealEntry {
        MealEntry(date: date, name: name, calories: calories,
                  proteinG: proteinG, carbsG: carbsG, fatG: fatG, notes: notes)
    }
}

@MainActor
final class NutritionStore: ObservableObject {
    static let shared = NutritionStore()

    @Published private(set) var meals: [LoggedMeal] = []
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published private(set) var isImporting = false

    /// View-facing projection: the NutritionMath functions operate on MealEntry.
    var entries: [MealEntry] { meals.map(\.asMealEntry) }

    /// Most-recent distinct meal names for the quick re-log list (free — no AI call).
    var recentMeals: [LoggedMeal] {
        var seen = Set<String>()
        var out: [LoggedMeal] = []
        for m in meals.sorted(by: { $0.createdAt > $1.createdAt }) {
            let key = m.name.lowercased()
            if seen.insert(key).inserted { out.append(m) }
            if out.count == 10 { break }
        }
        return out
    }

    private var storeURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("nutrition_log.json")
    }

    private init() { load() }

    // MARK: Persistence

    private func load() {
        guard let url = storeURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([LoggedMeal].self, from: data) else { return }
        meals = decoded.sorted { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
    }

    private func persist() {
        guard let url = storeURL,
              let data = try? JSONEncoder().encode(meals) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: CRUD

    func add(_ meal: LoggedMeal) {
        meals.append(meal)
        meals.sort { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
        persist()
    }

    func update(_ meal: LoggedMeal) {
        guard let i = meals.firstIndex(where: { $0.id == meal.id }) else { return }
        meals[i] = meal
        persist()
    }

    func delete(id: UUID) {
        meals.removeAll { $0.id == id }
        persist()
    }

    // MARK: One-time Google Sheet import

    /// Pulls the sheet once and merges rows not already present (dedupe on date+name+rounded
    /// calories). Returns nothing; reports via infoMessage/errorMessage.
    func importFromSheet(spreadsheetID: String) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let rows = try await GoogleSheetsService.shared.fetchRows(spreadsheetID: spreadsheetID)
            let parsed = Self.parseSheet(rows)
            var existing = Set(meals.map { "\($0.date)|\($0.name.lowercased())|\(Int($0.calories.rounded()))" })
            var added = 0
            for e in parsed {
                let key = "\(e.date)|\(e.name.lowercased())|\(Int(e.calories.rounded()))"
                guard existing.insert(key).inserted else { continue }
                meals.append(LoggedMeal(date: e.date, name: e.name, calories: e.calories,
                                        proteinG: e.proteinG, carbsG: e.carbsG, fatG: e.fatG,
                                        notes: e.notes, source: "sheet"))
                added += 1
            }
            meals.sort { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
            persist()
            errorMessage = nil
            infoMessage = added > 0
                ? "Imported \(added) meal\(added == 1 ? "" : "s") from the sheet."
                : "Sheet read OK — nothing new to import."
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Errors users can act on. URLError carries almost nothing in localizedDescription
    /// ("cancelled"), so append the domain/code for support.
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "\(urlError.localizedDescription) (NSURLErrorDomain \(urlError.code.rawValue))"
        }
        return error.localizedDescription
    }

    // MARK: - Sheet parsing (import path)

    /// Sheet rows → entries. Skips the header row; tolerates short rows, thousand separators,
    /// and dates given as text (YYYY-MM-DD and common locale shapes) or Sheets serial numbers.
    static func parseSheet(_ rows: [[Any]]) -> [MealEntry] {
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

    /// Normalise a date cell to YYYY-MM-DD. Accepts strings ("2026-11-08", "11/8/2026", "8/11/2026",
    /// "Nov 8 2026"…) and Sheets/Excel serial numbers (days since 1899-12-30).
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
