import AVFoundation
import Foundation

final class AudioPlayerController: ObservableObject {
  @Published var isPlaying: Bool = false
  @Published var currentTime: Double = 0
  @Published var duration: Double = 0
  @Published var title: String = ""

  private var player: AVPlayer?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?

  func load(url: URL, title: String) {
    resetObservers()
    self.title = title

    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playback, mode: .spokenAudio)
      try? session.setActive(true)
    #endif

    let player = AVPlayer(url: url)
    self.player = player
    attachTimeObserver(to: player)
    observeEndOfPlayback(for: player)
  }

  func play() {
    player?.play()
    isPlaying = true
  }

  func pause() {
    player?.pause()
    isPlaying = false
  }

  func togglePlayback() {
    if isPlaying {
      pause()
    } else {
      play()
    }
  }

  func seek(to seconds: Double) {
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    player?.seek(to: time)
  }

  func stop() {
    player?.pause()
    isPlaying = false
    currentTime = 0
  }

  private func attachTimeObserver(to player: AVPlayer) {
    let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
    timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      [weak self] time in
      guard let self else { return }
      let seconds = time.seconds
      if seconds.isFinite {
        self.currentTime = seconds
      }
      if let duration = player.currentItem?.duration.seconds, duration.isFinite {
        self.duration = duration
      }
    }
  }

  private func observeEndOfPlayback(for player: AVPlayer) {
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { [weak self] _ in
      self?.isPlaying = false
      self?.currentTime = self?.duration ?? 0
    }
  }

  private func resetObservers() {
    if let timeObserver {
      player?.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
  }

  deinit {
    resetObservers()
  }
}
