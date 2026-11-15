import SwiftUI
import WatchKit
import StrandDesign

// MARK: - WatchActionsView — the Find iPhone page
//
// A full-screen page in the watch deck: TRIPLE-TAP anywhere on it and the paired iPhone plays a
// loud siren at max volume (it ignores the mute switch — see FindPhoneSound on the phone side).
// The tap target is the whole page because the feature exists for the moment you can't find the
// phone, not for careful aiming. A regular button sits below for the same thing in one tap.

struct WatchActionsView: View {
    @EnvironmentObject private var store: WatchScoreStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)

            Text("Find iPhone")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)

            Text(store.findPhoneSent ? "Pinging…" : "Triple-tap anywhere")
                .font(StrandFont.footnote)
                .foregroundStyle(store.findPhoneSent ? StrandPalette.accent : StrandPalette.textTertiary)

            Button {
                store.pingPhone()
            } label: {
                Label("Ping now", systemImage: "speaker.wave.3.fill")
            }
            .tint(StrandPalette.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 3) {
            store.pingPhone()
            WKInterfaceDevice.current().play(.click)
        }
    }
}
