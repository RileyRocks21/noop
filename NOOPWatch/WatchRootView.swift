import SwiftUI
import WatchKit
import StrandDesign

// MARK: - WatchRootView — the swipeable page deck
//
// The watch app is a deck of full-screen pages you swipe (or turn the Digital Crown) between, each sized to
// exactly ONE screen so nothing ever needs scrolling: the glance (today's synced scores) first, then the
// three on-watch active features, then the actions page (Find iPhone). A page-style TabView with the dots
// showing replaces the old push-nav, so every screen is one swipe away and the page indicator makes that
// obvious. The phone stays the brain for the SCORES on the glance; Breathe / Workout / Intervals run on
// the watch's own sensors + haptics.
//
// The root also owns the "timer finished" alert: the phone's custom timers buzz the watch on completion
// (WatchScoreStore.timerAlert), and the haptic burst below is what makes it unmissable.
struct WatchRootView: View {
    @EnvironmentObject private var store: WatchScoreStore
    @State private var showTimerAlert = false

    var body: some View {
        TabView {
            WatchGlanceView()
            WatchBreatheView()
            WatchWorkoutView()
            WatchIntervalView()
            WatchActionsView()
        }
        // watchOS page TabView shows the page-indicator dots by default; the iOS background-display-mode
        // customisation is unavailable here, so the plain page style is the right call.
        .tabViewStyle(.page)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .onChange(of: store.timerAlert) { _, value in
            guard value != nil else { return }
            showTimerAlert = true
            buzzRepeatedly()
        }
        .alert("Timer finished", isPresented: $showTimerAlert) {
            Button("OK") { store.timerAlert = nil }
        } message: {
            Text(store.timerAlert ?? "")
        }
    }

    /// A run of notification haptics — six pulses a third of a second apart, so a finished timer is
    /// felt, not just displayed. Stop taps the alert away; the burst is short enough to leave alone.
    private func buzzRepeatedly() {
        let device = WKInterfaceDevice.current()
        for i in 0..<6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.35) {
                device.play(.notification)
            }
        }
    }
}
