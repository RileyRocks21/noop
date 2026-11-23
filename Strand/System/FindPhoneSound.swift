#if os(iOS)
import AVFoundation
import MediaPlayer
import UIKit

// MARK: - Find iPhone siren
//
// Triggered by the watch's triple-tap "Find iPhone" page (WatchSessionBridge's `findPhone` message).
// Plays a loud two-tone siren for ~15 seconds. Two tricks make it actually findable:
//   - the `.playback` audio-session category ignores the mute switch, and
//   - the media volume is pushed to max first (via the hidden-MPVolumeView-slider trick, the same
//     approach every "find my phone" app uses — there is no public volume-setter API).
// The player is a static so nothing can deallocate it mid-siren.

@MainActor
enum FindPhoneSound {

    /// How long the siren runs before stopping itself.
    static let duration: TimeInterval = 15

    private static var player: AVAudioPlayer?
    private static var stopWork: DispatchWorkItem?
    /// Keeps the invisible volume view alive for the app's lifetime once created.
    private static var volumeView: MPVolumeView?

    /// True while the siren is sounding. A strap double-tap uses this to stop the siren instead of
    /// restarting it.
    static var isPlaying: Bool { player?.isPlaying == true }

    static func play() {
        guard let url = Bundle.main.url(forResource: "findphone", withExtension: "wav") else { return }

        maxOutVolume()

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1     // loop the 2-second pattern until the stop timer
            p.volume = 1.0
            p.play()
            player = p
        } catch {
            return
        }

        stopWork?.cancel()
        let work = DispatchWorkItem {
            Task { @MainActor in stop() }
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    static func stop() {
        player?.stop()
        player = nil
        stopWork?.cancel()
        stopWork = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Push media volume to max. MPVolumeView's slider is the only sanctioned handle on system
    /// volume; the view is never added to a window, so nothing is visible.
    private static func maxOutVolume() {
        if volumeView == nil { volumeView = MPVolumeView(frame: .zero) }
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = 1.0
    }
}
#endif
