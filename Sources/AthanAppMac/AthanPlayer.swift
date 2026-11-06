import AppKit
import AVFoundation

/// Plays the athan (or a soft chime) and fades it out on stop.
@MainActor
final class AthanPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?
    private var watcher: Timer?

    func play(path: String, volume: Double) {
        stop(fade: false)
        let url = path.isEmpty ? nil : URL(fileURLWithPath: path)
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let p = try? AVAudioPlayer(contentsOf: url) else {
            chime(volume: volume)
            return
        }
        p.volume = Float(volume)
        p.prepareToPlay()
        p.play()
        player = p
        isPlaying = true
        watcher = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                if !player.isPlaying { self.isPlaying = false; self.watcher?.invalidate() }
            }
        }
    }

    /// A gentle notification sound, used for deferred reminders and when no athan file is set.
    func chime(volume: Double) {
        let sound = NSSound(named: "Glass") ?? NSSound(named: "Purr")
        sound?.volume = Float(volume)
        sound?.play()
    }

    func stop(fade: Bool = true) {
        watcher?.invalidate()
        guard let p = player else { isPlaying = false; return }
        if fade {
            p.setVolume(0, fadeDuration: 0.8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { p.stop() }
        } else {
            p.stop()
        }
        player = nil
        isPlaying = false
    }
}
