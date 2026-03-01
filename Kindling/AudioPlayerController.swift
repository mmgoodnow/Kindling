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
  @Published var bookDescription: String = ""
  @Published var artworkURL: URL?
  @Published var chapters: [Chapter] = []
  @Published var playbackRate: Double = 1.0

  private var player: AVPlayer?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var chapterLoadTask: Task<Void, Never>?

  func load(
    url: URL,
    title: String,
    author: String? = nil,
    description: String? = nil,
    artworkURL: URL? = nil
  ) {
    resetObservers()
    chapterLoadTask?.cancel()
    self.title = title
    self.author = author ?? ""
    self.bookDescription = description ?? ""
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
    player?.rate = Float(playbackRate)
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

  func setPlaybackRate(_ rate: Double) {
    let clampedRate = min(max(rate, 0.5), 3.0)
    playbackRate = clampedRate
    if isPlaying {
      player?.rate = Float(clampedRate)
    }
  }

  func seek(to seconds: Double) {
    let clampedSeconds = min(max(seconds, 0), max(duration, 0))
    currentTime = clampedSeconds

    let time = CMTime(seconds: clampedSeconds, preferredTimescale: 1_000)
    player?.currentItem?.cancelPendingSeeks()
    player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
    bookDescription = ""
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
      await MainActor.run { [weak self] in
        self?.chapters = chapters
      }
    }
  }

  private static func extractChapters(from url: URL) async -> [Chapter] {
    let asset = AVURLAsset(url: url)

    do {
      let locales = try await asset.load(.availableChapterLocales)
      let metadataGroups = try await loadChapterMetadataGroups(
        from: asset,
        preferredLanguages: Locale.preferredLanguages,
        availableLocales: locales
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

  private static func loadChapterMetadataGroups(
    from asset: AVURLAsset,
    preferredLanguages: [String],
    availableLocales: [Locale]
  ) async throws -> [AVTimedMetadataGroup] {
    let preferredGroups: [AVTimedMetadataGroup] = try await withCheckedThrowingContinuation {
      continuation in
      asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: preferredLanguages) {
        groups,
        error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: groups ?? [])
        }
      }
    }

    if preferredGroups.isEmpty == false {
      return preferredGroups
    }

    guard let locale = availableLocales.first else { return [] }
    return try await asset.loadChapterMetadataGroups(
      withTitleLocale: locale,
      containingItemsWithCommonKeys: []
    )
  }

  private static func chapterTitle(for group: AVTimedMetadataGroup, index: Int) -> String {
    if let titleItem = AVMetadataItem.metadataItems(
      from: group.items,
      filteredByIdentifier: .commonIdentifierTitle
    ).first,
      let title = titleItem.stringValue,
      title.isEmpty == false
    {
      return normalizedChapterTitle(title, fallbackIndex: index)
    }

    return "Chapter \(index + 1)"
  }

  private static func normalizedChapterTitle(_ rawTitle: String, fallbackIndex: Int) -> String {
    let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return "Chapter \(fallbackIndex + 1)" }

    if let chapterNumber = Int(trimmed), trimmed.allSatisfy(\.isNumber) {
      return "Chapter \(chapterNumber)"
    }

    return trimmed
  }

  deinit {
    chapterLoadTask?.cancel()
    resetObservers()
  }
}
