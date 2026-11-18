#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Nutrition card on Today
//
// Today's slice of the Nutrition page: eaten vs target, burned so far and by midnight, protein against
// the floor, and the last seven days of intake vs burn. Every figure comes from the same resolvers the
// Nutrition page uses (NutritionBurn, NutritionMath) with the same targets, so the two never disagree.
// Tapping the card opens the Nutrition page; + logs a meal for today.
//
// Pinned under the Jarvis card on both Todays, today-only, for the same reason the Jarvis card is
// pinned: `today.sectionOrder` is a byte-identical key shared with Android.

struct NutritionTodayCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @ObservedObject private var store = NutritionStore.shared

    // Same keys and defaults as NutritionView.
    @AppStorage("noop.nutrition.weekdayKcal") private var weekdayKcal = 2350.0
    @AppStorage("noop.nutrition.weekendKcal") private var weekendKcal = 3050.0
    @AppStorage("noop.nutrition.proteinFloor") private var proteinFloor = 200.0

    @State private var showLog = false

    var body: some View {
        // Re-evaluated once a minute so "burned so far" climbs with the clock.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            card(now: context.date)
        }
        .sheet(isPresented: $showLog) { LogMealView(dayKey: NutritionMath.dayKey(Date()), store: store) }
    }

    private func card(now: Date) -> some View {
        let todayKey = NutritionMath.dayKey(now)
        let bmr = NutritionBurn.bmr(profile)
        let est = NutritionBurn.estimate(dayKey: todayKey, strapTotal: NutritionBurn.strapTotal(repo, todayKey),
                                         bmr: bmr, now: now)
        let b = NutritionMath.balance(forDate: todayKey, in: store.entries,
                                      weekdayKcal: weekdayKcal, weekendKcal: weekendKcal,
                                      proteinFloor: proteinFloor, burnedKcal: est.projected)
        let points = NutritionBurn.trend(days: 7, entries: store.entries, bmr: bmr, now: now) {
            NutritionBurn.strapTotal(repo, $0)
        }
        let net = b.consumedKcal - est.soFar

        return NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("NUTRITION").strandOverline()
                    Spacer()
                    Button { showLog = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Log meal")
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(b.consumedKcal.rounded()))")
                        .font(StrandFont.rounded(34)).foregroundStyle(StrandPalette.textPrimary)
                    Text("of \(Int(b.targetKcal.rounded())) kcal eaten")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }

                bar(fraction: b.consumedKcal / max(b.targetKcal, 1),
                    color: b.remainingKcal >= 0 ? StrandPalette.accent : StrandPalette.metricRose)

                HStack(alignment: .top, spacing: 16) {
                    figure("Burned so far", "\(Int(est.soFar.rounded())) kcal", StrandPalette.textPrimary)
                    figure("By midnight", "~\(Int(est.projected.rounded())) kcal", StrandPalette.textPrimary)
                    figure(net <= 0 ? "Net so far" : "Over burn",
                         "\(net <= 0 ? "−" : "+")\(Int(abs(net).rounded())) kcal",
                         net <= 0 ? StrandPalette.accent : StrandPalette.metricRose)
                }

                HStack(spacing: 8) {
                    Text("Protein")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    bar(fraction: b.consumedProtein / max(b.proteinFloor, 1), color: StrandPalette.metricPurple)
                    Text("\(Int(b.consumedProtein.rounded())) / \(Int(b.proteinFloor.rounded())) g")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize()
                }

                Rectangle().fill(StrandPalette.hairline).frame(height: 1)

                Text("LAST 7 DAYS").strandOverline()
                NutritionTrendChart(points: points, height: 140)
                if let avg = NutritionBurn.loggedAverages(points) {
                    Text("Average on logged days: \(Int(avg.eaten.rounded())) eaten, \(Int(avg.burned.rounded())) burned")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { NutritionNav.open() }
    }

    private func bar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset).frame(height: 6)
                Capsule().fill(color).frame(width: geo.size.width * min(max(fraction, 0), 1), height: 6)
            }
        }
        .frame(height: 6)
    }

    private func figure(_ label: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.headline).foregroundStyle(color)
        }
    }
}
#endif
