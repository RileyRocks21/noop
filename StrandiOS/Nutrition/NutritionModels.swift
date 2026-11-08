#if os(iOS)
import Foundation

// MARK: - Nutrition data model
//
// Swift port of the Python spec for the "Nutrition & Macro Tracker Logs" Google Sheet:
//   columns: Date (YYYY-MM-DD) | Meal Name | Calories | Protein (g) | Carbs (g) | Fat (g) | Notes
// The three spec functions live here as pure statics (`entries(forDate:)` → get_entries_for_date,
// `balance(forDate:)` → calculate_daily_balance, `weeklySummary(...)` → generate_weekly_summary)
// so they stay testable without a network or a UI.

/// One logged meal row from the sheet.
struct MealEntry: Equatable, Codable, Identifiable {
    var id: String { "\(date)|\(name)|\(calories)|\(proteinG)|\(carbsG)|\(fatG)" }
    let date: String        // YYYY-MM-DD (local day key, same format the Repository uses)
    let name: String
    let calories: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let notes: String
}

/// Summed totals for one day (the sum half of `get_entries_for_date`).
struct NutritionDayTotals: Equatable {
    let date: String
    var calories: Double = 0
    var proteinG: Double = 0
    var carbsG: Double = 0
    var fatG: Double = 0
    var meals: [MealEntry] = []
}

/// The result of `calculate_daily_balance`: consumed vs target vs burned.
struct NutritionDailyBalance: Equatable {
    let date: String
    let consumedKcal: Double
    let targetKcal: Double
    /// target − consumed. Positive = room left under the target; negative = over target.
    let remainingKcal: Double
    let consumedProtein: Double
    let proteinFloor: Double
    /// floor − consumed. Positive = still short of the protein floor; negative = floor cleared.
    let proteinGap: Double
    /// Total burn estimate for the day (BMR from profile + strap/active energy), when known.
    let burnedKcal: Double?
    /// burned − consumed. Positive = calorie deficit; negative = surplus. nil when burn is unknown.
    let deficitKcal: Double?
}

/// The result of `generate_weekly_summary`: grouped daily averages + adherence + an executive
/// summary of consistency, macro balance and the average-deficit goal.
struct NutritionWeeklySummary: Equatable {
    let startDate: String
    let endDate: String
    let totalDays: Int
    let daysWithEntries: Int
    let avgCalories: Double
    let avgProtein: Double
    let avgCarbs: Double
    let avgFat: Double
    /// Mean (burned − consumed) across days that have BOTH a sheet entry and a burn figure. nil when
    /// no day qualifies (e.g. no strap data yet), so the UI never fabricates a deficit number.
    let avgDeficit: Double?
    let daysMeetingDeficitGoal: Int
    let daysWithBurnData: Int
    let daysMeetingProteinFloor: Int
    /// Share of logged calories from each macro (protein/carbs/fat × 4/4/9 kcal per gram).
    let proteinShare: Double
    let carbsShare: Double
    let fatShare: Double
    /// Plain-language executive summary lines (consistency, macro balance, deficit adherence).
    let bullets: [String]
}

enum NutritionMath {

    // MARK: Day keys

    /// Local-day formatter shared with the sheet's Date column (YYYY-MM-DD).
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func date(for dayKey: String) -> Date? { dayFormatter.date(from: dayKey) }

    static func isWeekend(_ dayKey: String) -> Bool {
        guard let d = date(for: dayKey) else { return false }
        let wd = Calendar.current.component(.weekday, from: d)
        return wd == 1 || wd == 7
    }

    /// Weekday vs weekend calorie target for a day key.
    static func targetKcal(for dayKey: String, weekday: Double, weekend: Double) -> Double {
        isWeekend(dayKey) ? weekend : weekday
    }

    // MARK: get_entries_for_date

    static func entries(forDate target: String, in entries: [MealEntry]) -> [MealEntry] {
        entries.filter { $0.date == target }
    }

    static func totals(forDate target: String, in entries: [MealEntry]) -> NutritionDayTotals {
        var t = NutritionDayTotals(date: target)
        t.meals = entries(forDate: target, in: entries)
        for m in t.meals {
            t.calories += m.calories
            t.proteinG += m.proteinG
            t.carbsG += m.carbsG
            t.fatG += m.fatG
        }
        return t
    }

    // MARK: calculate_daily_balance

    static func balance(forDate target: String,
                        in entries: [MealEntry],
                        weekdayKcal: Double,
                        weekendKcal: Double,
                        proteinFloor: Double,
                        burnedKcal: Double?) -> NutritionDailyBalance {
        let t = totals(forDate: target, in: entries)
        let targetKcal = targetKcal(for: target, weekday: weekdayKcal, weekend: weekendKcal)
        return NutritionDailyBalance(
            date: target,
            consumedKcal: t.calories,
            targetKcal: targetKcal,
            remainingKcal: targetKcal - t.calories,
            consumedProtein: t.proteinG,
            proteinFloor: proteinFloor,
            proteinGap: proteinFloor - t.proteinG,
            burnedKcal: burnedKcal,
            deficitKcal: burnedKcal.map { $0 - t.calories })
    }

    // MARK: Energy burn estimate

    /// Mifflin–St Jeor BMR (kcal/day). `sex` is the ProfileStore token: "male" | "female" |
    /// "nonbinary"; nonbinary uses the midpoint of the two constants, which is the honest read of
    /// a two-constant equation applied outside its two fitted groups.
    static func bmr(sex: String, weightKg: Double, heightCm: Double, ageYears: Int) -> Double {
        let base = 10 * weightKg + 6.25 * heightCm - 5 * Double(ageYears)
        switch sex.lowercased() {
        case "male":   return base + 5
        case "female": return base - 161
        default:       return base - 78
        }
    }

    /// Total burn for a day = BMR (profile) + above-resting active energy (strap estimate /
    /// Apple Health import), when the active half exists. BMR alone is still returned when no
    /// active figure is banked — labelled as such at the call site.
    static func burnedKcal(activeKcal: Double?, bmr: Double) -> Double {
        (activeKcal ?? 0) + bmr
    }

    // MARK: generate_weekly_summary

    /// Groups the range by day, computes averages over LOGGED days, and writes the executive
    /// summary. `burnedByDay` maps day keys to a total-burn figure (see `burnedKcal`); days
    /// missing from it simply don't feed the deficit stats.
    static func weeklySummary(from startKey: String,
                              to endKey: String,
                              entries: [MealEntry],
                              weekdayKcal: Double,
                              weekendKcal: Double,
                              proteinFloor: Double,
                              deficitGoal: Double,
                              burnedByDay: [String: Double]) -> NutritionWeeklySummary {
        var keys: [String] = []
        var cursor = date(for: startKey)
        let end = date(for: endKey)
        while let d = cursor, let e = end, d <= e {
            keys.append(dayKey(d))
            cursor = Calendar.current.date(byAdding: .day, value: 1, to: d)
        }

        var logged = 0
        var sumKcal = 0.0, sumProtein = 0.0, sumCarbs = 0.0, sumFat = 0.0
        var deficits: [Double] = []
        var deficitHits = 0
        var proteinHits = 0

        for key in keys {
            let t = totals(forDate: key, in: entries)
            guard !t.meals.isEmpty else { continue }
            logged += 1
            sumKcal += t.calories; sumProtein += t.proteinG; sumCarbs += t.carbsG; sumFat += t.fatG
            if t.proteinG >= proteinFloor { proteinHits += 1 }
            if let burned = burnedByDay[key] {
                let deficit = burned - t.calories
                deficits.append(deficit)
                if deficit >= deficitGoal { deficitHits += 1 }
            }
        }

        let n = Double(max(logged, 1))
        let avgKcal = sumKcal / n, avgProtein = sumProtein / n, avgCarbs = sumCarbs / n, avgFat = sumFat / n
        let macroKcal = max(avgProtein * 4 + avgCarbs * 4 + avgFat * 9, 1)
        let avgDeficit = deficits.isEmpty ? nil : deficits.reduce(0, +) / Double(deficits.count)

        var bullets: [String] = []
        if logged == 0 {
            bullets.append("No meals logged between \(startKey) and \(endKey) — log in the sheet to see trends here.")
        } else {
            let pct = Int((Double(logged) / Double(max(keys.count, 1)) * 100).rounded())
            bullets.append("Logged \(logged) of \(keys.count) days (\(pct)% consistency).")
            if let avgDeficit {
                let adherence = Int((Double(deficitHits) / Double(deficits.count) * 100).rounded())
                let avgInt = Int(avgDeficit.rounded()), goalInt = Int(deficitGoal.rounded())
                if avgDeficit >= deficitGoal {
                    bullets.append("Average deficit \(avgInt) kcal/day — ahead of the \(goalInt) kcal goal, hit on \(deficitHits) of \(deficits.count) measured days (\(adherence)%).")
                } else if avgDeficit >= 0 {
                    bullets.append("Average deficit \(avgInt) kcal/day — below the \(goalInt) kcal goal (hit \(deficitHits) of \(deficits.count) measured days, \(adherence)%).")
                } else {
                    bullets.append("Running a \(-avgInt) kcal/day SURPLUS on average — the \(goalInt) kcal deficit goal was hit on \(deficitHits) of \(deficits.count) measured days.")
                }
            } else {
                bullets.append("Deficit tracking needs burn data — wear the strap (or sync Apple Health) on logged days.")
            }
            bullets.append("Protein floor \(Int(proteinFloor.rounded())) g reached on \(proteinHits) of \(logged) logged days (avg \(Int(avgProtein.rounded())) g).")
            let pShare = avgProtein * 4 / macroKcal, cShare = avgCarbs * 4 / macroKcal, fShare = avgFat * 9 / macroKcal
            bullets.append("Macro balance: \(Int((pShare * 100).rounded()))% protein / \(Int((cShare * 100).rounded()))% carbs / \(Int((fShare * 100).rounded()))% fat of logged calories.")
        }

        return NutritionWeeklySummary(
            startDate: startKey, endDate: endKey,
            totalDays: keys.count, daysWithEntries: logged,
            avgCalories: logged == 0 ? 0 : avgKcal,
            avgProtein: logged == 0 ? 0 : avgProtein,
            avgCarbs: logged == 0 ? 0 : avgCarbs,
            avgFat: logged == 0 ? 0 : avgFat,
            avgDeficit: avgDeficit,
            daysMeetingDeficitGoal: deficitHits,
            daysWithBurnData: deficits.count,
            daysMeetingProteinFloor: proteinHits,
            proteinShare: avgProtein * 4 / macroKcal,
            carbsShare: avgCarbs * 4 / macroKcal,
            fatShare: avgFat * 9 / macroKcal,
            bullets: bullets)
    }
}
#endif
