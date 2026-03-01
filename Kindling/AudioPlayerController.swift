import AVFoundation
import Foundation

#if os(iOS)
  import MediaPlayer
  import UIKit
#endif

final class AudioPlayerController: ObservableObject {
  private enum ResumeStore {
    static let keyPrefix = "audioPlayer.resumePosition."
  }

  private static let resumeRewindSeconds: Double = 2.5

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
  @Published private(set) var seekHistory: [Double] = []

  private var player: AVPlayer?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var chapterLoadTask: Task<Void, Never>?
  private var currentBookID: String?
  #if os(iOS)
    private var artworkLoadTask: Task<Void, Never>?
  #endif

  init() {
    #if os(iOS)
      configureRemoteCommands()
    #endif
  }

  deinit {
    chapterLoadTask?.cancel()
    resetObservers()
    #if os(iOS)
      artworkLoadTask?.cancel()
      teardownRemoteCommands()
    #endif
  }

  func load(
    url: URL,
    bookID: String,
    title: String,
    author: String? = nil,
    description: String? = nil,
    artworkURL: URL? = nil
  ) {
    resetObservers()
    chapterLoadTask?.cancel()
    #if os(iOS)
      artworkLoadTask?.cancel()
    #endif
    currentBookID = bookID
    self.title = title
    self.author = author ?? ""
    self.bookDescription = description ?? ""
    self.artworkURL = artworkURL
    let savedPosition = persistedPosition(for: bookID)
    self.currentTime = savedPosition
    self.duration = 0
    self.isPlaying = false
    self.chapters = []
    self.seekHistory = []

    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playback, mode: .spokenAudio)
      try? session.setActive(true)
    #endif

    let player = AVPlayer(url: url)
    self.player = player
    if savedPosition > 0 {
      let resumeTime = CMTime(seconds: savedPosition, preferredTimescale: 1_000)
      player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    attachTimeObserver(to: player)
    observeEndOfPlayback(for: player)
    loadChapters(from: url)
    #if os(iOS)
      updateNowPlayingInfo()
      loadNowPlayingArtwork(from: artworkURL)
    #endif
  }

  func play() {
    if shouldRewindOnResume {
      let rewindTarget = max(0, currentTime - Self.resumeRewindSeconds)
      let rewindTime = CMTime(seconds: rewindTarget, preferredTimescale: 1_000)
      player?.currentItem?.cancelPendingSeeks()
      player?.seek(to: rewindTime, toleranceBefore: .zero, toleranceAfter: .zero)
      currentTime = rewindTarget
      persistCurrentPosition()
    }
    player?.play()
    player?.rate = Float(playbackRate)
    isPlaying = true
    #if os(iOS)
      updateNowPlayingInfo()
    #endif
  }

  func pause() {
    player?.pause()
    isPlaying = false
    persistCurrentPosition()
    #if os(iOS)
      updateNowPlayingInfo()
    #endif
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
    #if os(iOS)
      updateNowPlayingInfo()
    #endif
  }

  func seek(to seconds: Double, recordHistory: Bool = true) {
    let clampedSeconds = min(max(seconds, 0), max(duration, 0))
    if recordHistory {
      rememberSeekOrigin(currentTime)
    }
    currentTime = clampedSeconds
    persistCurrentPosition()

    let time = CMTime(seconds: clampedSeconds, preferredTimescale: 1_000)
    player?.currentItem?.cancelPendingSeeks()
    player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    #if os(iOS)
      updateNowPlayingInfo()
    #endif
  }

  func skip(by seconds: Double) {
    let target = max(0, currentTime + seconds)
    seek(to: target)
  }

  func rememberCurrentPositionForSeek() {
    rememberSeekOrigin(currentTime)
  }

  func restorePreviousSeek() {
    guard let previousTime = seekHistory.popLast() else { return }
    seek(to: previousTime, recordHistory: false)
  }

  func stop() {
    player?.pause()
    isPlaying = false
    persistCurrentPosition()
    currentTime = 0
    #if os(iOS)
      updateNowPlayingInfo()
    #endif
  }

  func unload() {
    persistCurrentPosition()
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
    seekHistory = []
    #if os(iOS)
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    #endif
  }

  var hasLoadedItem: Bool {
    player != nil && title.isEmpty == false
  }

  var canRestorePreviousSeek: Bool {
    seekHistory.isEmpty == false
  }

  private func attachTimeObserver(to player: AVPlayer) {
    let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
    timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      [weak self] time in
      guard let self else { return }
      let seconds = time.seconds
      if seconds.isFinite {
        self.currentTime = seconds
        self.persistCurrentPosition()
        #if os(iOS)
          self.updateNowPlayingInfo()
        #endif
      }
      if let duration = player.currentItem?.duration.seconds, duration.isFinite {
        self.duration = duration
        #if os(iOS)
          self.updateNowPlayingInfo()
        #endif
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
      self?.clearPersistedPosition()
      #if os(iOS)
        self?.updateNowPlayingInfo()
      #endif
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

  private func rememberSeekOrigin(_ seconds: Double) {
    let normalized = min(max(seconds, 0), max(duration, 0))
    guard seekHistory.last.map({ abs($0 - normalized) < 0.25 }) != true else { return }
    seekHistory.append(normalized)
  }

  private func persistedPosition(for bookID: String) -> Double {
    UserDefaults.standard.double(forKey: ResumeStore.keyPrefix + bookID)
  }

  private func persistCurrentPosition() {
    guard let currentBookID else { return }
    UserDefaults.standard.set(currentTime, forKey: ResumeStore.keyPrefix + currentBookID)
  }

  private func clearPersistedPosition() {
    guard let currentBookID else { return }
    UserDefaults.standard.removeObject(forKey: ResumeStore.keyPrefix + currentBookID)
  }

  private var shouldRewindOnResume: Bool {
    guard currentTime > 0.5 else { return false }
    if duration.isFinite, duration > 0, currentTime >= duration - 0.5 {
      return false
    }
    return true
  }

  #if os(iOS)
    private func configureRemoteCommands() {
      let commandCenter = MPRemoteCommandCenter.shared()
      commandCenter.playCommand.isEnabled = true
      commandCenter.pauseCommand.isEnabled = true
      commandCenter.changePlaybackPositionCommand.isEnabled = true
      commandCenter.skipBackwardCommand.isEnabled = true
      commandCenter.skipForwardCommand.isEnabled = true
      commandCenter.skipBackwardCommand.preferredIntervals = [15]
      commandCenter.skipForwardCommand.preferredIntervals = [30]

      commandCenter.playCommand.addTarget { [weak self] _ in
        guard let self else { return .commandFailed }
        self.play()
        return .success
      }
      commandCenter.pauseCommand.addTarget { [weak self] _ in
        guard let self else { return .commandFailed }
        self.pause()
        return .success
      }
      commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
        guard
          let self,
          let positionEvent = event as? MPChangePlaybackPositionCommandEvent
        else { return .commandFailed }
        self.seek(to: positionEvent.positionTime)
        return .success
      }
      commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
        guard let self else { return .commandFailed }
        self.skip(by: -15)
        return .success
      }
      commandCenter.skipForwardCommand.addTarget { [weak self] _ in
        guard let self else { return .commandFailed }
        self.skip(by: 30)
        return .success
      }
    }

    private func teardownRemoteCommands() {
      let commandCenter = MPRemoteCommandCenter.shared()
      commandCenter.playCommand.removeTarget(nil)
      commandCenter.pauseCommand.removeTarget(nil)
      commandCenter.changePlaybackPositionCommand.removeTarget(nil)
      commandCenter.skipBackwardCommand.removeTarget(nil)
      commandCenter.skipForwardCommand.removeTarget(nil)
    }

    private func updateNowPlayingInfo(artwork: MPMediaItemArtwork? = nil) {
      var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
      nowPlayingInfo[MPMediaItemPropertyTitle] = title
      nowPlayingInfo[MPMediaItemPropertyArtist] = author
      nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
      nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
      nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0
      if let artwork {
        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func loadNowPlayingArtwork(from url: URL?) {
      guard let url else { return }
      artworkLoadTask = Task { [weak self] in
        guard
          let (data, _) = try? await URLSession.shared.data(from: url),
          let image = UIImage(data: data)
        else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        guard Task.isCancelled == false else { return }
        await MainActor.run { [weak self] in
          self?.updateNowPlayingInfo(artwork: artwork)
        }
      }
    }
  #endif

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
}
