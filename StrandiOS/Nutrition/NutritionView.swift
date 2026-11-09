#if os(iOS)
import SwiftUI
import Charts
import StrandDesign

// MARK: - Nutrition tab
//
// Meals are logged in-app (manual / AI text / AI photo / barcode — see LogMealView) into the local
// NutritionStore, and lined up against the day's burn: Mifflin–St Jeor BMR from the shared
// ProfileStore (edited in Settings → Profile) plus the strap/Apple-Health active energy already
// banked in the Repository. Targets (weekday/weekend kcal, protein floor, deficit goal) are
// editable in the tab's own settings sheet. Google Sheet history comes in via a one-time import.

struct NutritionView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @ObservedObject private var store = NutritionStore.shared

    // Editable targets — the spec's defaults.
    @AppStorage("noop.nutrition.weekdayKcal") private var weekdayKcal = 2350.0
    @AppStorage("noop.nutrition.weekendKcal") private var weekendKcal = 3050.0
    @AppStorage("noop.nutrition.proteinFloor") private var proteinFloor = 200.0
    @AppStorage("noop.nutrition.deficitGoal") private var deficitGoal = 350.0

    /// 0 = today, 1 = yesterday, … Day navigation stays offset-based so it survives refetches.
    @State private var dayOffset = 0
    @State private var showSettings = false
    @State private var showLog = false

    private var selectedDayKey: String {
        let d = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date()
        return NutritionMath.dayKey(d)
    }

    /// Total burn estimate for a day: profile BMR + active energy, when banked.
    private func burned(for dayKey: String) -> (total: Double, hasActive: Bool) {
        let bmr = NutritionMath.bmr(sex: profile.sex, weightKg: profile.weightKg,
                                    heightCm: profile.heightCm, ageYears: profile.age)
        let active = repo.days.first(where: { $0.day == dayKey })?.activeKcalEst
        return (NutritionMath.burnedKcal(activeKcal: active, bmr: bmr), active != nil)
    }

    var body: some View {
        ScreenScaffold(title: "Nutrition",
                       subtitle: "Intake vs your burn",
                       onRefresh: { await repo.refresh() },
                       topBackground: liquidScaffoldSky(),
                       trailing: {
                           HStack(spacing: 16) {
                               Button { showLog = true } label: {
                                   Image(systemName: "plus.circle.fill")
                                       .font(.system(size: 20, weight: .semibold))
                                       .foregroundStyle(StrandPalette.accent)
                               }
                               .accessibilityLabel("Log meal")
                               Button { showSettings = true } label: {
                                   Image(systemName: "gearshape")
                                       .font(.system(size: 17, weight: .semibold))
                                       .foregroundStyle(StrandPalette.accent)
                               }
                               .accessibilityLabel("Nutrition settings")
                           }
                       }) {
            if let info = store.infoMessage {
                infoCard(info, symbol: "checkmark.circle.fill")
            }
            if let error = store.errorMessage {
                infoCard(error, symbol: "exclamationmark.triangle.fill")
            }
            if store.isImporting {
                StatePill("Importing from sheet…", tone: .accent, pulsing: true)
            }

            dayNav
            balanceCard
            macrosCard
            trendCard
            weeklyCard
            mealsCard
        }
        .task { await repo.refresh() }
        .sheet(isPresented: $showSettings) { NutritionSettingsView() }
        .sheet(isPresented: $showLog) { LogMealView(dayKey: selectedDayKey, store: store) }
    }

    // MARK: - Info / error states

    private func infoCard(_ message: String, symbol: String) -> some View {
        DataPendingNote(title: "Nutrition", message: LocalizedStringKey(message), symbol: symbol)
    }

    // MARK: - Day navigation

    private var dayNav: some View {
        HStack {
            Button { dayOffset += 1 } label: {
                Image(systemName: "chevron.left.circle.fill").font(.title3)
            }
            Spacer()
            VStack(spacing: 2) {
                if dayOffset == 0 {
                    Text("Today").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                } else if let d = NutritionMath.date(for: selectedDayKey) {
                    Text(d, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                }
                if dayOffset != 0 {
                    Button("Jump to today") { dayOffset = 0 }
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                }
            }
            Spacer()
            Button { if dayOffset > 0 { dayOffset -= 1 } } label: {
                Image(systemName: "chevron.right.circle.fill").font(.title3)
            }
            .disabled(dayOffset == 0)
            .opacity(dayOffset == 0 ? 0.3 : 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.accent)
        .padding(.horizontal, 4)
    }

    // MARK: - Balance card (calculate_daily_balance)

    private var balanceCard: some View {
        let burn = burned(for: selectedDayKey)
        let b = NutritionMath.balance(forDate: selectedDayKey, in: store.entries,
                                      weekdayKcal: weekdayKcal, weekendKcal: weekendKcal,
                                      proteinFloor: proteinFloor, burnedKcal: burn.total)
        return NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(NutritionMath.isWeekend(selectedDayKey) ? "WEEKEND TARGET" : "WEEKDAY TARGET")
                        .strandOverline()
                    Spacer()
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(b.consumedKcal.rounded()))")
                        .font(StrandFont.rounded(34)).foregroundStyle(StrandPalette.textPrimary)
                    Text("of \(Int(b.targetKcal.rounded())) kcal eaten")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }

                macroBar(fraction: min(max(b.consumedKcal / max(b.targetKcal, 1), 0), 1.2),
                         color: b.remainingKcal >= 0 ? StrandPalette.accent : StrandPalette.metricRose,
                         track: StrandPalette.surfaceInset)

                HStack(spacing: 16) {
                    stat(b.remainingKcal >= 0 ? "Remaining" : "Over target",
                         "\(Int(abs(b.remainingKcal).rounded())) kcal",
                         b.remainingKcal >= 0 ? StrandPalette.accent : StrandPalette.metricRose)
                    stat("Burned (est.)", "\(Int((b.burnedKcal ?? 0).rounded())) kcal",
                         StrandPalette.textPrimary)
                    if let deficit = b.deficitKcal {
                        stat(deficit >= 0 ? "Deficit" : "Surplus",
                             "\(Int(abs(deficit).rounded())) kcal",
                             deficit >= deficitGoal ? StrandPalette.accent
                                : (deficit >= 0 ? StrandPalette.textPrimary : StrandPalette.metricRose))
                    }
                }

                if !burn.hasActive {
                    Text("Burn = BMR only — no strap/Apple Health active energy banked for this day yet.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    // MARK: - Macros card

    private var macrosCard: some View {
        let t = NutritionMath.totals(forDate: selectedDayKey, in: store.entries)
        return NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("MACROS").strandOverline()
                macroRow("Protein", t.proteinG, floor: proteinFloor, unit: "g", color: StrandPalette.accent)
                macroRow("Carbs", t.carbsG, floor: nil, unit: "g", color: StrandPalette.restColor)
                macroRow("Fat", t.fatG, floor: nil, unit: "g", color: StrandPalette.gold)
                if t.calories > 0 {
                    let macroKcal = max(t.proteinG * 4 + t.carbsG * 4 + t.fatG * 9, 1)
                    Text(String(format: "Split: %.0f%% protein · %.0f%% carbs · %.0f%% fat",
                                t.proteinG * 4 / macroKcal * 100,
                                t.carbsG * 4 / macroKcal * 100,
                                t.fatG * 9 / macroKcal * 100))
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private func macroRow(_ label: String, _ grams: Double, floor: Double?, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                if let floor {
                    Text("\(Int(grams.rounded())) / \(Int(floor.rounded())) \(unit)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(grams >= floor ? StrandPalette.accent : StrandPalette.textSecondary)
                } else {
                    Text("\(Int(grams.rounded())) \(unit)")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            macroBar(fraction: floor.map { min(grams / max($0, 1), 1.2) } ?? 1,
                     color: color, track: StrandPalette.surfaceInset)
        }
    }

    private func macroBar(fraction: Double, color: Color, track: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track).frame(height: 6)
                Capsule().fill(color)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1), height: 6)
            }
        }
        .frame(height: 6)
    }

    // MARK: - 7-day trend

    private struct TrendPoint: Identifiable {
        let id = UUID()
        let dayKey: String
        let label: String
        let consumed: Double
        let burned: Double
    }

    private var trendCard: some View {
        var points: [TrendPoint] = []
        for back in stride(from: 6, through: 0, by: -1) {
            guard let d = Calendar.current.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let key = NutritionMath.dayKey(d)
            let t = NutritionMath.totals(forDate: key, in: store.entries)
            let burn = burned(for: key)
            let label = DateFormatter.localizedString(from: d, dateStyle: .short, timeStyle: .none)
                .components(separatedBy: "/").prefix(2).joined(separator: "/")
            points.append(TrendPoint(dayKey: key, label: label,
                                     consumed: t.calories, burned: burn.total))
        }
        return NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("LAST 7 DAYS").strandOverline()
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
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(StrandPalette.hairline)
                        AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .frame(height: 180)
                HStack(spacing: 16) {
                    legendDot(StrandPalette.accent, "Eaten")
                    legendDot(StrandPalette.metricRose, "Burned (BMR + active)")
                }
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    // MARK: - Weekly summary (generate_weekly_summary)

    private var weeklyCard: some View {
        let end = NutritionMath.dayKey(Date())
        let start = NutritionMath.dayKey(Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        var burnedByDay: [String: Double] = [:]
        for back in 0...6 {
            guard let d = Calendar.current.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let key = NutritionMath.dayKey(d)
            burnedByDay[key] = burned(for: key).total
        }
        let w = NutritionMath.weeklySummary(from: start, to: end, entries: store.entries,
                                            weekdayKcal: weekdayKcal, weekendKcal: weekendKcal,
                                            proteinFloor: proteinFloor, deficitGoal: deficitGoal,
                                            burnedByDay: burnedByDay)
        return NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("WEEKLY SUMMARY").strandOverline()
                    Spacer()
                    Text("\(w.daysWithEntries)/\(w.totalDays) days logged")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
                if w.daysWithEntries > 0 {
                    HStack(spacing: 16) {
                        stat("Avg kcal", "\(Int(w.avgCalories.rounded()))", StrandPalette.textPrimary)
                        stat("Avg protein", "\(Int(w.avgProtein.rounded())) g",
                             w.avgProtein >= proteinFloor ? StrandPalette.accent : StrandPalette.metricRose)
                        if let avgDeficit = w.avgDeficit {
                            stat("Avg deficit", "\(Int(avgDeficit.rounded())) kcal",
                                 avgDeficit >= deficitGoal ? StrandPalette.accent : StrandPalette.metricRose)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(w.bullets, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").foregroundStyle(StrandPalette.accent)
                            Text(line).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Meals list

    private var mealsCard: some View {
        let meals = store.meals.filter { $0.date == selectedDayKey }
        return NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("MEALS").strandOverline()
                    Spacer()
                    Button { showLog = true } label: {
                        Label("Log", systemImage: "plus")
                            .font(StrandFont.subhead)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                }
                .padding(16)
                if meals.isEmpty {
                    Text("Nothing logged for this day — tap + to describe, photograph or scan a meal.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, 16).padding(.bottom, 16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(meals) { meal in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(meal.name).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                                    Spacer()
                                    Text("\(Int(meal.calories.rounded())) kcal")
                                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                                }
                                HStack(spacing: 10) {
                                    Text("P \(Int(meal.proteinG.rounded())) g")
                                    Text("C \(Int(meal.carbsG.rounded())) g")
                                    Text("F \(Int(meal.fatG.rounded())) g")
                                    if !meal.notes.isEmpty {
                                        Text("· \(meal.notes)").lineLimit(1)
                                    }
                                }
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.leading, 16)
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(role: .destructive) { store.delete(id: meal.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                }
            }
        }
    }

    // MARK: - Small stat

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.headline).foregroundStyle(color)
        }
    }
}
#endif
