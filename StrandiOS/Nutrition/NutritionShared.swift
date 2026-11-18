#if os(iOS)
import SwiftUI
import Charts
import StrandDesign

// MARK: - Nutrition: shared burn + trend resolvers
//
// The Nutrition page and Today's nutrition card both state "eaten" and "burned". They read them from
// these resolvers, with one profile/strap snapshot and one clock passed in, so the two screens can't
// disagree (AGENTS.md: two readouts of one fact must not be able to disagree).

/// Burn for one day. Days end at midnight (local).
/// - Past days: `soFar` == `projected` == the strap's whole-day total (BMR floor).
/// - Today: `soFar` is the strap's running total (resting burn included while worn), floored at
///   BMR × time elapsed to cover unworn gaps. `projected` = soFar + the REST of the day at resting
///   rate. The active burn rate is deliberately NOT extrapolated: a 7am gym session stretched to
///   midnight projected ~4,000 kcal from a normal workout.
struct NutritionBurnEstimate: Equatable {
    var soFar: Double
    var projected: Double
    var hasActive: Bool
    var isToday: Bool
}

/// One day on the intake-vs-burn trend chart.
struct NutritionTrendPoint: Identifiable, Equatable {
    var id: String { dayKey }
    let dayKey: String
    let label: String
    let consumed: Double
    let burned: Double
}

/// Main-actor bound: it reads the Repository and ProfileStore, and only views call it.
@MainActor
enum NutritionBurn {
    /// Mifflin–St Jeor BMR from the shared profile.
    static func bmr(_ profile: ProfileStore) -> Double {
        NutritionMath.bmr(sex: profile.sex, weightKg: profile.weightKg,
                          heightCm: profile.heightCm, ageYears: profile.age)
    }

    /// The strap's whole-day total for a day key, when one is banked.
    static func strapTotal(_ repo: Repository, _ dayKey: String) -> Double? {
        repo.days.first(where: { $0.day == dayKey })?.activeKcalEst
    }

    static func estimate(dayKey: String, strapTotal: Double?, bmr: Double, now: Date) -> NutritionBurnEstimate {
        guard dayKey == NutritionMath.dayKey(now) else {
            let total = NutritionMath.burnedKcal(strapTotalKcal: strapTotal, bmr: bmr)
            return NutritionBurnEstimate(soFar: total, projected: total, hasActive: strapTotal != nil, isToday: false)
        }
        // Fraction of the local day elapsed. Floored at 4% (~1 h) so early-morning numbers stay sane.
        let start = Calendar.current.startOfDay(for: now)
        let elapsed = min(1, max(0.04, now.timeIntervalSince(start) / 86400))
        let soFar = max(strapTotal ?? 0, bmr * elapsed)
        return NutritionBurnEstimate(soFar: soFar, projected: soFar + bmr * (1 - elapsed),
                                     hasActive: strapTotal != nil, isToday: true)
    }

    /// The last `days` days, oldest first: what was eaten vs the whole-day burn figure.
    static func trend(days: Int, entries: [MealEntry], bmr: Double, now: Date,
                      strapTotal: (String) -> Double?) -> [NutritionTrendPoint] {
        var points: [NutritionTrendPoint] = []
        for back in stride(from: days - 1, through: 0, by: -1) {
            guard let d = Calendar.current.date(byAdding: .day, value: -back, to: now) else { continue }
            let key = NutritionMath.dayKey(d)
            let t = NutritionMath.totals(forDate: key, in: entries)
            let label = DateFormatter.localizedString(from: d, dateStyle: .short, timeStyle: .none)
                .components(separatedBy: "/").prefix(2).joined(separator: "/")
            points.append(NutritionTrendPoint(
                dayKey: key, label: label, consumed: t.calories,
                burned: NutritionMath.burnedKcal(strapTotalKcal: strapTotal(key), bmr: bmr)))
        }
        return points
    }

    /// Averages over the days that have meals logged (an unlogged day isn't a zero-calorie day).
    static func loggedAverages(_ points: [NutritionTrendPoint]) -> (eaten: Double, burned: Double, days: Int)? {
        let logged = points.filter { $0.consumed > 0 }
        guard !logged.isEmpty else { return nil }
        let n = Double(logged.count)
        return (logged.map(\.consumed).reduce(0, +) / n, logged.map(\.burned).reduce(0, +) / n, logged.count)
    }
}

/// Eaten (bars) vs burned (line) per day.
struct NutritionTrendChart: View {
    let points: [NutritionTrendPoint]
    var height: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(points) { p in
                    BarMark(x: .value("Day", p.label), y: .value("Eaten", p.consumed))
                        .foregroundStyle(StrandPalette.accent.gradient)
                        .cornerRadius(4)
                    LineMark(x: .value("Day", p.label), y: .value("Burned", p.burned),
                             series: .value("Series", "burn"))
                        .foregroundStyle(StrandPalette.metricRose)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(StrandPalette.hairline)
                    AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(height: height)
            HStack(spacing: 16) {
                legendDot(StrandPalette.accent, "Eaten")
                legendDot(StrandPalette.metricRose, "Burned (BMR + active)")
            }
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func legendDot(_ color: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

/// Opens the Nutrition page (a More destination) from elsewhere, e.g. Today's nutrition card.
enum NutritionNav {
    static let openNotification = Notification.Name("noop.nutrition.open")

    @MainActor static func open() {
        NotificationCenter.default.post(name: openNotification, object: nil)
    }
}
#endif
