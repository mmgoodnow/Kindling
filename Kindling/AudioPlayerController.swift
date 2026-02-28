import AVFoundation
import Foundation

final class AudioPlayerController: ObservableObject {
  struct Chapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let startTime: Double
    let duration: Double
  }

  @Published var isPlaying: Bool = false
  @Published var currentTime: Double = 0
  @Published var duration: Double = 0
  @Published var title: String = ""
  @Published var author: String = ""
  @Published var artworkURL: URL?
  @Published var chapters: [Chapter] = []

  private var player: AVPlayer?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var chapterLoadTask: Task<Void, Never>?

  func load(url: URL, title: String, author: String? = nil, artworkURL: URL? = nil) {
    resetObservers()
    chapterLoadTask?.cancel()
    self.title = title
    self.author = author ?? ""
    self.artworkURL = artworkURL
    self.currentTime = 0
    self.duration = 0
    self.isPlaying = false
    self.chapters = []

    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playback, mode: .spokenAudio)
      try? session.setActive(true)
    #endif

    let player = AVPlayer(url: url)
    self.player = player
    attachTimeObserver(to: player)
    observeEndOfPlayback(for: player)
    loadChapters(from: url)
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

  func skip(by seconds: Double) {
    let target = max(0, currentTime + seconds)
    seek(to: target)
  }

  func stop() {
    player?.pause()
    isPlaying = false
    currentTime = 0
  }

  func unload() {
    stop()
    resetObservers()
    chapterLoadTask?.cancel()
    chapterLoadTask = nil
    player = nil
    duration = 0
    title = ""
    author = ""
    artworkURL = nil
    chapters = []
  }

  var hasLoadedItem: Bool {
    player != nil && title.isEmpty == false
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

  private func loadChapters(from url: URL) {
    chapterLoadTask = Task { [weak self] in
      let chapters = await Self.extractChapters(from: url)
      guard Task.isCancelled == false else { return }
      await MainActor.run {
        self?.chapters = chapters
      }
    }
  }

  private static func extractChapters(from url: URL) async -> [Chapter] {
    let asset = AVURLAsset(url: url)

    do {
      _ = try await asset.load(.availableChapterLocales)
      let metadataGroups = try await asset.loadChapterMetadataGroupsBestMatchingPreferredLanguages(
        Locale.preferredLanguages
      )

      return metadataGroups.enumerated().compactMap { index, group in
        let startTime = group.timeRange.start.seconds
        guard startTime.isFinite else { return nil }

        let duration = group.timeRange.duration.seconds
        let title = chapterTitle(for: group, index: index)
        return Chapter(
          id: index,
          title: title,
          startTime: startTime,
          duration: duration.isFinite ? duration : 0
        )
      }
    } catch {
      return []
    }
  }

  private static func chapterTitle(for group: AVTimedMetadataGroup, index: Int) -> String {
    if let titleItem = AVMetadataItem.metadataItems(
      from: group.items,
      filteredByIdentifier: .commonIdentifierTitle
    ).first,
      let title = try? titleItem.load(.stringValue),
      let title,
      title.isEmpty == false
    {
      return title
    }

    return "Chapter \(index + 1)"
  }

  deinit {
    chapterLoadTask?.cancel()
    resetObservers()
  }
}
