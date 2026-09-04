import AVFoundation
import Foundation

/// Small playback state for the source preview.
final class VideoPreviewState: ObservableObject {
    let player: AVPlayer
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isPlaying = false

    private var timeObserver: Any?

    init(asset: AVAsset) {
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
            isPlaying = player.rate != 0
            if duration > 0, currentTime >= duration - 0.05 {
                player.pause()
                isPlaying = false
            }
        }

        Task { @MainActor [weak self] in
            let loaded = try? await asset.load(.duration)
            self?.duration = max(0, loaded?.seconds ?? 0)
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    func togglePlayback() {
        if player.rate == 0 {
            if duration > 0, currentTime >= duration - 0.05 {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        } else {
            pause()
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        let target = min(max(seconds, 0), max(duration, 0))
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}
