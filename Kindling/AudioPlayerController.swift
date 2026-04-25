import AVFoundation
import Foundation

#if os(iOS)
  import MediaPlayer
  import UIKit
#endif

final class AudioPlayerController: ObservableObject {
  final class PlaybackProgressState: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    /// Total seconds of contiguous data buffered ahead of the playhead.
    /// Always 0 for fully-local files (which have everything available).
    @Published var bufferedSeconds: Double = 0
  }

  private enum ResumeStore {
    static let keyPrefix = "audioPlayer.resumePosition."
    static let sessionKey = "audioPlayer.lastSession"
  }

  private struct PersistedSession: Codable {
    let resumeID: String
    let fileRelativePath: String
    let title: String
    let author: String
    let description: String
    let artworkURLString: String?
  }

  private static let resumeRewindSeconds: Double = 2.5

  struct Chapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let startTime: Double
    let duration: Double
  }

  @Published var isPlaying: Bool = false
  @Published var title: String = ""
  @Published var author: String = ""
  @Published var bookDescription: String = ""
  @Published var artworkURL: URL?
  @Published var chapters: [Chapter] = []
  @Published var transcript: PodibleTranscript?
  @Published var playbackRate: Double = 1.0
  @Published private(set) var seekHistory: [Double] = []
  /// True when AVPlayer wants to play but is waiting on the network (typical
  /// during initial buffering of streamed content or after a network stall).
  @Published private(set) var isStalled: Bool = false

  let progress = PlaybackProgressState()

  private var player: AVPlayer?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var chapterLoadTask: Task<Void, Never>?
  private var currentResumeID: String?
  private var currentFileURL: URL?
  private var loadedRangesObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var lastBufferRefreshAt: CFTimeInterval = 0
  private var pendingBufferRefresh: Bool = false
  /// Retained because `AVURLAsset.resourceLoader.setDelegate(_:queue:)`
  /// holds the delegate weakly. Releasing this kills streaming mid-playback.
  private var streamingLoader: StreamingAssetLoader?
  #if os(iOS)
    private var artworkLoadTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var shouldResumeAfterInterruption = false
  #endif

  init() {
    #if os(iOS)
      configureRemoteCommands()
      observeAudioInterruptions()
    #endif
  }

  deinit {
    chapterLoadTask?.cancel()
    resetObservers()
    #if os(iOS)
      artworkLoadTask?.cancel()
      teardownRemoteCommands()
      if let interruptionObserver {
        NotificationCenter.default.removeObserver(interruptionObserver)
      }
    #endif
  }

  func load(
    url: URL,
    resumeID: String,
    title: String,
    author: String? = nil,
    description: String? = nil,
    artworkURL: URL? = nil
  ) {
    streamingLoader = nil
    prepareForLoad(
      resumeID: resumeID,
      url: url,
      title: title,
      author: author,
      description: description,
      artworkURL: artworkURL
    )
    let savedPosition = persistedPosition(for: resumeID)
    let player = AVPlayer(url: url)
    self.player = player
    finishLoad(
      player: player,
      savedPosition: savedPosition,
      chapterURL: url,
      artworkURL: artworkURL,
      observesBuffering: false
    )
  }

  /// Streams audio over HTTP using `StreamingAssetLoader` so the request
  /// carries an `Authorization: Bearer ...` header. `httpURL` is the real
  /// HTTPS URL of the audio file; the loader proxies range requests.
  func loadStreaming(
    httpURL: URL,
    accessToken: String?,
    resumeID: String,
    title: String,
    author: String? = nil,
    description: String? = nil,
    artworkURL: URL? = nil
  ) {
    guard let proxyURL = StreamingAssetLoader.proxyURL(for: httpURL) else {
      // Fall back to plain load if we can't construct the custom-scheme URL.
      load(
        url: httpURL, resumeID: resumeID, title: title, author: author,
        description: description, artworkURL: artworkURL)
      return
    }

    let loader = StreamingAssetLoader(httpURL: httpURL, accessToken: accessToken)
    streamingLoader = loader
    prepareForLoad(
      resumeID: resumeID,
      url: httpURL,
      title: title,
      author: author,
      description: description,
      artworkURL: artworkURL
    )
    let savedPosition = persistedPosition(for: resumeID)

    let asset = AVURLAsset(url: proxyURL)
    asset.resourceLoader.setDelegate(loader, queue: .main)
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    self.player = player
    // Don't run `loadChapters` for streamed playback yet — it forces an
    // additional asset metadata load that may fetch the entire file from
    // the end-of-file chapter atom on m4b. Punted; chapters arrive when /
    // if the server-side chapter RPC is available via `applyRemoteChapters`.
    finishLoad(
      player: player,
      savedPosition: savedPosition,
      chapterURL: nil,
      artworkURL: artworkURL,
      observesBuffering: true
    )
  }

  private func prepareForLoad(
    resumeID: String,
    url: URL,
    title: String,
    author: String?,
    description: String?,
    artworkURL: URL?
  ) {
    resetObservers()
    chapterLoadTask?.cancel()
    #if os(iOS)
      artworkLoadTask?.cancel()
    #endif
    currentResumeID = resumeID
    currentFileURL = url
    self.title = title
    self.author = author ?? ""
    self.bookDescription = description ?? ""
    self.artworkURL = artworkURL
    progress.currentTime = persistedPosition(for: resumeID)
    progress.duration = 0
    self.isPlaying = false
    self.chapters = []
    self.transcript = nil
    self.seekHistory = []

    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playback, mode: .spokenAudio)
      try? session.setActive(true)
    #endif
  }

  private func finishLoad(
    player: AVPlayer,
    savedPosition: Double,
    chapterURL: URL?,
    artworkURL: URL?,
    observesBuffering: Bool
  ) {
    persistSession()
    if savedPosition > 0 {
      let resumeTime = CMTime(seconds: savedPosition, preferredTimescale: 1_000)
      player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    attachTimeObserver(to: player)
    if observesBuffering {
      attachStreamingObservers(to: player)
    }
    observeEndOfPlayback(for: player)
    if let chapterURL {
      loadChapters(from: chapterURL)
    }
    #if os(iOS)
      updateNowPlayingInfo()
      loadNowPlayingArtwork(from: artworkURL)
    #endif
  }

  func play() {
    if shouldRewindOnResume {
      let rewindTarget = max(0, progress.currentTime - Self.resumeRewindSeconds)
      let rewindTime = CMTime(seconds: rewindTarget, preferredTimescale: 1_000)
      player?.currentItem?.cancelPendingSeeks()
      player?.seek(to: rewindTime, toleranceBefore: .zero, toleranceAfter: .zero)
      progress.currentTime = rewindTarget
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
    let clampedSeconds = min(max(seconds, 0), max(progress.duration, 0))
    if recordHistory {
      rememberSeekOrigin(progress.currentTime)
    }
    progress.currentTime = clampedSeconds
    persistCurrentPosition()

    let time = CMTime(seconds: clampedSeconds, preferredTimescale: 1_000)
    player?.currentItem?.cancelPendingSeeks()
    player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    #if os(iOS)
      updateNowPlayingInfo()
    #endif
  }

  func skip(by seconds: Double) {
    let target = max(0, progress.currentTime + seconds)
    seek(to: target)
  }

  func rememberCurrentPositionForSeek() {
    rememberSeekOrigin(progress.currentTime)
  }

  func restorePreviousSeek() {
    guard let previousTime = seekHistory.popLast() else { return }
    seek(to: previousTime, recordHistory: false)
  }

  func stop() {
    player?.pause()
    isPlaying = false
    persistCurrentPosition()
    progress.currentTime = 0
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
    currentFileURL = nil
    progress.duration = 0
    title = ""
    author = ""
    bookDescription = ""
    artworkURL = nil
    chapters = []
    transcript = nil
    seekHistory = []
    #if os(iOS)
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    #endif
  }

  var hasLoadedItem: Bool {
    player != nil && title.isEmpty == false
  }

  var currentTime: Double {
    progress.currentTime
  }

  var duration: Double {
    progress.duration
  }

  @discardableResult
  func restoreLastSession() -> Bool {
    guard let session = persistedSession() else { return false }
    guard let url = try? LibraryStorage().url(forRelativePath: session.fileRelativePath) else {
      clearPersistedSession()
      clearPersistedPosition(for: session.resumeID)
      return false
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      clearPersistedSession()
      clearPersistedPosition(for: session.resumeID)
      return false
    }

    load(
      url: url,
      resumeID: session.resumeID,
      title: session.title,
      author: session.author.isEmpty ? nil : session.author,
      description: session.description.isEmpty ? nil : session.description,
      artworkURL: session.artworkURLString.flatMap(URL.init(string:))
    )
    return true
  }

  var canRestorePreviousSeek: Bool {
    seekHistory.isEmpty == false
  }

  @MainActor
  func applyRemoteTranscript(_ transcript: PodibleTranscript?, for resumeID: String) {
    guard currentResumeID == resumeID else { return }
    self.transcript = transcript
  }

  @MainActor
  func applyRemoteChapters(_ markers: [PodibleChapterMarker], for resumeID: String) {
    guard currentResumeID == resumeID else { return }
    guard markers.isEmpty == false else { return }

    let sorted = markers.sorted { $0.startTime < $1.startTime }
    let nextChapters = sorted.enumerated().map { index, marker in
      let nextStart =
        sorted.indices.contains(index + 1)
        ? sorted[index + 1].startTime
        : progress.duration
      let duration = max(nextStart - marker.startTime, 0)
      return Chapter(
        id: index,
        title: Self.normalizedChapterTitle(marker.title, fallbackIndex: index),
        startTime: marker.startTime,
        duration: duration
      )
    }
    chapters = nextChapters
  }

  private func attachTimeObserver(to player: AVPlayer) {
    let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
    timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      [weak self] time in
      guard let self else { return }
      let seconds = time.seconds
      if seconds.isFinite {
        self.progress.currentTime = seconds
        self.persistCurrentPosition()
        #if os(iOS)
          self.updateNowPlayingInfo()
        #endif
      }
      if let duration = player.currentItem?.duration.seconds, duration.isFinite {
        self.progress.duration = duration
        #if os(iOS)
          self.updateNowPlayingInfo()
        #endif
      }
      // Only worth tracking buffered ahead while streaming.
      if self.loadedRangesObservation != nil {
        self.refreshBufferedSeconds()
      }
    }
  }

  private func attachStreamingObservers(to player: AVPlayer) {
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) {
      [weak self] player, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
          self.isStalled = true
        default:
          self.isStalled = false
        }
      }
    }
    if let item = player.currentItem {
      loadedRangesObservation = item.observe(\.loadedTimeRanges, options: [.new]) {
        [weak self] _, _ in
        self?.scheduleBufferRefresh()
      }
    }
  }

  /// Throttles `refreshBufferedSeconds` to at most ~4Hz. The KVO callback
  /// can fire many times per second during initial buffering of a streamed
  /// asset; without throttling we'd flood the main queue with state writes.
  private func scheduleBufferRefresh() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.pendingBufferRefresh { return }
      let now = CACurrentMediaTime()
      let elapsed = now - self.lastBufferRefreshAt
      let interval: CFTimeInterval = 0.25
      if elapsed >= interval {
        self.lastBufferRefreshAt = now
        self.refreshBufferedSeconds()
      } else {
        self.pendingBufferRefresh = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (interval - elapsed)) { [weak self] in
          guard let self else { return }
          self.pendingBufferRefresh = false
          self.lastBufferRefreshAt = CACurrentMediaTime()
          self.refreshBufferedSeconds()
        }
      }
    }
  }

  private func refreshBufferedSeconds() {
    guard let item = player?.currentItem else {
      progress.bufferedSeconds = 0
      return
    }
    let currentSeconds = progress.currentTime
    // Find the loaded range containing the playhead and report how far past
    // the playhead it extends. Other islands of buffered data don't help us.
    var bufferedAhead: Double = 0
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      let start = range.start.seconds
      let end = (range.start + range.duration).seconds
      guard start.isFinite, end.isFinite else { continue }
      if currentSeconds >= start && currentSeconds <= end {
        bufferedAhead = max(bufferedAhead, end - currentSeconds)
      } else if start > currentSeconds {
        // No bridge between playhead and this future island — ignore.
      }
    }
    if bufferedAhead != progress.bufferedSeconds {
      progress.bufferedSeconds = bufferedAhead
    }
  }

  private func observeEndOfPlayback(for player: AVPlayer) {
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { [weak self] _ in
      self?.isPlaying = false
      self?.progress.currentTime = self?.progress.duration ?? 0
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
    loadedRangesObservation?.invalidate()
    loadedRangesObservation = nil
    timeControlObservation?.invalidate()
    timeControlObservation = nil
    isStalled = false
    progress.bufferedSeconds = 0
  }

  private func rememberSeekOrigin(_ seconds: Double) {
    let normalized = min(max(seconds, 0), max(progress.duration, 0))
    guard seekHistory.last.map({ abs($0 - normalized) < 0.25 }) != true else { return }
    seekHistory.append(normalized)
  }

  private func persistedPosition(for resumeID: String) -> Double {
    UserDefaults.standard.double(forKey: ResumeStore.keyPrefix + resumeID)
  }

  private func persistCurrentPosition() {
    guard let currentResumeID else { return }
    UserDefaults.standard.set(progress.currentTime, forKey: ResumeStore.keyPrefix + currentResumeID)
  }

  private func clearPersistedPosition() {
    guard let currentResumeID else { return }
    clearPersistedPosition(for: currentResumeID)
  }

  private func clearPersistedPosition(for resumeID: String) {
    UserDefaults.standard.removeObject(forKey: ResumeStore.keyPrefix + resumeID)
  }

  private func persistSession() {
    guard let currentResumeID, let currentFileURL else { return }
    guard let relativePath = try? LibraryStorage().relativePath(forFileURL: currentFileURL) else {
      return
    }

    let session = PersistedSession(
      resumeID: currentResumeID,
      fileRelativePath: relativePath,
      title: title,
      author: author,
      description: bookDescription,
      artworkURLString: artworkURL?.absoluteString
    )

    guard let data = try? JSONEncoder().encode(session) else { return }
    UserDefaults.standard.set(data, forKey: ResumeStore.sessionKey)
  }

  private func persistedSession() -> PersistedSession? {
    guard let data = UserDefaults.standard.data(forKey: ResumeStore.sessionKey) else { return nil }
    return try? JSONDecoder().decode(PersistedSession.self, from: data)
  }

  private func clearPersistedSession() {
    UserDefaults.standard.removeObject(forKey: ResumeStore.sessionKey)
  }

  private var shouldRewindOnResume: Bool {
    guard progress.currentTime > 0.5 else { return false }
    if progress.duration.isFinite, progress.duration > 0,
      progress.currentTime >= progress.duration - 0.5
    {
      return false
    }
    return true
  }

  #if os(iOS)
    private func observeAudioInterruptions() {
      interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        queue: .main
      ) { [weak self] notification in
        self?.handleAudioInterruption(notification)
      }
    }

    private func handleAudioInterruption(_ notification: Notification) {
      guard
        let info = notification.userInfo,
        let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
        let interruptionType = AVAudioSession.InterruptionType(rawValue: rawType)
      else { return }

      switch interruptionType {
      case .began:
        shouldResumeAfterInterruption = isPlaying
        if isPlaying {
          player?.pause()
          isPlaying = false
          updateNowPlayingInfo()
        }
      case .ended:
        let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
        let shouldResume = shouldResumeAfterInterruption && options.contains(.shouldResume)
        shouldResumeAfterInterruption = false
        guard shouldResume else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)
        play()
      @unknown default:
        shouldResumeAfterInterruption = false
      }
    }

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
      nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = progress.duration
      nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progress.currentTime
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

      var chapters: [Chapter] = []
      chapters.reserveCapacity(metadataGroups.count)

      for (index, group) in metadataGroups.enumerated() {
        let startTime = group.timeRange.start.seconds
        guard startTime.isFinite else { continue }

        let duration = group.timeRange.duration.seconds
        let title = await chapterTitle(for: group, index: index)
        chapters.append(
          Chapter(
            id: index,
            title: title,
            startTime: startTime,
            duration: duration.isFinite ? duration : 0
          )
        )
      }

      return chapters
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

  private static func chapterTitle(for group: AVTimedMetadataGroup, index: Int) async -> String {
    if let titleItem = AVMetadataItem.metadataItems(
      from: group.items,
      filteredByIdentifier: .commonIdentifierTitle
    ).first,
      let title = try? await titleItem.load(.stringValue),
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
