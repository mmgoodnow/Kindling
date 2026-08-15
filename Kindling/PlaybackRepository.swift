import Foundation
import SwiftData

@MainActor
final class PlaybackRepository {
  private enum Keys {
    static let resumePrefix = "audioPlayer.resumePosition."
    static let rate = "audioPlayer.playbackRate"
    static let recoveryCheckpoint = "audioPlayer.playbackRecoveryCheckpoint.v1"
  }

  private struct RecoveryCheckpoint: Codable {
    let canonicalID: String
    let aliases: [String]
    let bookPodibleID: String?
    let manifestationID: Int?
    let positionSeconds: Double
    let durationSeconds: Double?
    let playbackRate: Double
    let updatedAt: Date
  }

  private struct LegacySession: Codable {
    let resumeID: String
    let podibleID: String?
    let manifestationID: Int?
  }

  private let context: ModelContext
  private let defaults: UserDefaults
  private var cachedStates: [PlaybackState]
  private var statesByCanonicalID: [String: PlaybackState]
  private var consolidatedCanonicalIDs: Set<String> = []

  init(context: ModelContext, defaults: UserDefaults = .standard) {
    self.context = context
    self.defaults = defaults
    let states = (try? context.fetch(FetchDescriptor<PlaybackState>())) ?? []
    self.cachedStates = states
    self.statesByCanonicalID = states.reduce(into: [:]) { result, state in
      result[state.canonicalID] = state
    }
  }

  func migrateLegacyState() throws {
    let legacyPositions = defaults.dictionaryRepresentation().compactMap {
      key, value -> (String, Double)? in
      guard key.hasPrefix(Keys.resumePrefix), let number = value as? NSNumber else { return nil }
      return (String(key.dropFirst(Keys.resumePrefix.count)), number.doubleValue)
    }
    let rate = (defaults.object(forKey: Keys.rate) as? NSNumber)?.doubleValue ?? 1

    for (resumeID, position) in legacyPositions where position > 0 {
      let state = rawState(for: resumeID)
      if state.positionSeconds <= 0 {
        state.positionSeconds = position
        state.playbackRate = rate
      }
    }
    if let data = defaults.data(forKey: "audioPlayer.lastSession"),
      let session = try? JSONDecoder().decode(LegacySession.self, from: data)
    {
      let identity = PlaybackIdentity(
        restoring: session.resumeID,
        podibleID: session.podibleID,
        manifestationID: session.manifestationID
      )
      _ = state(for: identity, createIfNeeded: true)
    }

    let books = (try? context.fetch(FetchDescriptor<LibraryBook>())) ?? []
    for book in books {
      for identity in playbackIdentities(for: book) {
        _ = state(for: identity, createIfNeeded: false)
      }
    }

    try reconcileRecoveryCheckpoint()
    try saveIfNeeded()
    for (resumeID, _) in legacyPositions {
      defaults.removeObject(forKey: Keys.resumePrefix + resumeID)
    }
    favoriteBooksWithPlaybackProgress()
    try saveIfNeeded()
  }

  func position(for identity: PlaybackIdentity) -> Double {
    state(for: identity, createIfNeeded: false)?.positionSeconds ?? legacyPosition(for: identity)
  }

  func progress(for identity: PlaybackIdentity, duration: Double?) -> Double? {
    guard let duration, duration.isFinite, duration > 0 else { return nil }
    let position = position(for: identity)
    guard position > 0, position < duration - 0.5 else { return nil }
    return min(max(position / duration, 0), 1)
  }

  func playbackRate(for identity: PlaybackIdentity?) -> Double {
    if let identity, let state = state(for: identity, createIfNeeded: false) {
      return state.playbackRate
    }
    return (defaults.object(forKey: Keys.rate) as? NSNumber)?.doubleValue ?? 1
  }

  func lastPlayedAt(for identity: PlaybackIdentity) -> Date? {
    state(for: identity, createIfNeeded: false)?.lastPlayedAt
  }

  func checkpoint(
    identity: PlaybackIdentity,
    position: Double,
    duration: Double?,
    playbackRate: Double,
    flush: Bool
  ) {
    let now = Date()
    let checkpoint = RecoveryCheckpoint(
      canonicalID: identity.canonicalID,
      aliases: [],
      bookPodibleID: identity.podibleID,
      manifestationID: identity.manifestationID,
      positionSeconds: max(position, 0),
      durationSeconds: duration,
      playbackRate: playbackRate,
      updatedAt: now
    )
    if let data = try? JSONEncoder().encode(checkpoint) {
      defaults.set(data, forKey: Keys.recoveryCheckpoint)
    }
    guard flush else { return }

    guard let state = state(for: identity, createIfNeeded: true) else { return }
    apply(checkpoint, to: state)
    try? saveIfNeeded()
  }

  func setPlaybackRate(_ rate: Double, identity: PlaybackIdentity?) {
    defaults.set(rate, forKey: Keys.rate)
    guard let identity else { return }
    guard let state = state(for: identity, createIfNeeded: true) else { return }
    state.playbackRate = rate
    state.updatedAt = Date()
    try? saveIfNeeded()
  }

  func clear(identity: PlaybackIdentity) {
    if let state = state(for: identity, createIfNeeded: false) {
      state.positionSeconds = 0
      state.updatedAt = Date()
    }
    try? saveIfNeeded()
    removeLegacyDefaults(for: identity)
    defaults.removeObject(forKey: Keys.recoveryCheckpoint)
  }

  func flushRecoveryJournal() {
    try? reconcileRecoveryCheckpoint()
    try? saveIfNeeded()
  }

  private func state(for identity: PlaybackIdentity, createIfNeeded: Bool) -> PlaybackState? {
    if consolidatedCanonicalIDs.contains(identity.canonicalID) == false {
      consolidateLegacyStates(for: identity)
    }

    if let exact = exactState(for: identity.canonicalID) {
      exact.aliasesJSON = nil
      exact.bookPodibleID = identity.podibleID ?? exact.bookPodibleID
      exact.manifestationID = identity.manifestationID ?? exact.manifestationID
      return exact
    }

    guard createIfNeeded else { return nil }
    let state = PlaybackState(
      canonicalID: identity.canonicalID,
      aliasesJSON: nil,
      bookPodibleID: identity.podibleID,
      manifestationID: identity.manifestationID,
      positionSeconds: legacyPosition(for: identity),
      playbackRate: defaultPlaybackRate()
    )
    context.insert(state)
    cachedStates.append(state)
    statesByCanonicalID[state.canonicalID] = state
    return state
  }

  private func reconcileRecoveryCheckpoint() throws {
    guard let data = defaults.data(forKey: Keys.recoveryCheckpoint),
      let checkpoint = try? JSONDecoder().decode(RecoveryCheckpoint.self, from: data)
    else { return }
    let identity = PlaybackIdentity(
      restoring: checkpoint.canonicalID,
      aliases: checkpoint.aliases,
      podibleID: checkpoint.bookPodibleID,
      manifestationID: checkpoint.manifestationID
    )
    guard let state = state(for: identity, createIfNeeded: true) else { return }
    let stateHasPlayback = state.positionSeconds > 0 || state.lastPlayedAt != nil
    if stateHasPlayback == false || checkpoint.updatedAt >= state.updatedAt {
      apply(checkpoint, to: state)
    }
  }

  private func apply(_ checkpoint: RecoveryCheckpoint, to state: PlaybackState) {
    state.aliasesJSON = nil
    state.bookPodibleID = checkpoint.bookPodibleID ?? state.bookPodibleID
    state.manifestationID = checkpoint.manifestationID ?? state.manifestationID
    state.positionSeconds = checkpoint.positionSeconds
    state.durationSeconds = checkpoint.durationSeconds
    state.playbackRate = checkpoint.playbackRate
    state.lastPlayedAt = checkpoint.updatedAt
    state.updatedAt = checkpoint.updatedAt
  }

  private func exactState(for canonicalID: String) -> PlaybackState? {
    statesByCanonicalID[canonicalID]
  }

  private func allStates() -> [PlaybackState] {
    cachedStates
  }

  private func legacyPosition(for identity: PlaybackIdentity) -> Double {
    identity.migrationResumeIDs.compactMap { resumeID in
      (defaults.object(forKey: Keys.resumePrefix + resumeID) as? NSNumber)?.doubleValue
    }.max() ?? 0
  }

  private static func decodedAliases(_ data: Data?) -> Set<String> {
    guard let data, let aliases = try? JSONDecoder().decode([String].self, from: data) else {
      return []
    }
    return Set(aliases)
  }

  private func saveIfNeeded() throws {
    if context.hasChanges {
      try context.save()
    }
  }

  private func favoriteBooksWithPlaybackProgress() {
    let progressedBookIDs = Set(
      allStates().compactMap { state in
        state.positionSeconds > 0 ? state.bookPodibleID : nil
      })
    guard progressedBookIDs.isEmpty == false else { return }
    let books = (try? context.fetch(FetchDescriptor<LibraryBook>())) ?? []
    for book in books where progressedBookIDs.contains(book.podibleId) {
      if let localState = book.localState {
        localState.isFavorite = true
      } else {
        let localState = LocalBookState(bookPodibleId: book.podibleId, isFavorite: true, book: book)
        context.insert(localState)
        book.localState = localState
      }
    }
  }

  private func consolidateLegacyStates(for identity: PlaybackIdentity) {
    let exact = exactState(for: identity.canonicalID)
    let migrationIDs = Set(identity.migrationResumeIDs)
    let candidates = cachedStates.filter { state in
      guard state !== exact, isCompatible(state, with: identity) else { return false }
      let stateIDs = Self.decodedAliases(state.aliasesJSON).union([state.canonicalID])
      let matchesKnownID = stateIDs.isDisjoint(with: migrationIDs) == false
      let matchesMetadata =
        identity.podibleID != nil
        && state.bookPodibleID == identity.podibleID
        && state.manifestationID == identity.manifestationID
      return matchesKnownID || matchesMetadata
    }
    let source = candidates.max { $0.updatedAt < $1.updatedAt }

    var target = exact
    if target == nil, let source {
      let migrated = PlaybackState(
        canonicalID: identity.canonicalID,
        aliasesJSON: nil,
        bookPodibleID: identity.podibleID ?? source.bookPodibleID,
        manifestationID: identity.manifestationID ?? source.manifestationID,
        positionSeconds: source.positionSeconds,
        durationSeconds: source.durationSeconds,
        playbackRate: source.playbackRate,
        lastPlayedAt: source.lastPlayedAt,
        updatedAt: source.updatedAt
      )
      context.insert(migrated)
      cachedStates.append(migrated)
      target = migrated
    } else if let target, let source,
      source.updatedAt > target.updatedAt
        || (target.positionSeconds <= 0 && source.positionSeconds > 0)
    {
      copyPlayback(from: source, to: target)
    }

    if let target {
      target.aliasesJSON = nil
      target.bookPodibleID = identity.podibleID ?? target.bookPodibleID
      target.manifestationID = identity.manifestationID ?? target.manifestationID
    }

    for candidate in candidates {
      context.delete(candidate)
      cachedStates.removeAll { $0 === candidate }
    }
    statesByCanonicalID = cachedStates.reduce(into: [:]) { result, state in
      result[state.canonicalID] = state
    }
    consolidatedCanonicalIDs.insert(identity.canonicalID)

    guard target != nil || candidates.isEmpty == false else { return }
    do {
      try saveIfNeeded()
      removeLegacyDefaults(for: identity)
    } catch {
      consolidatedCanonicalIDs.remove(identity.canonicalID)
    }
  }

  private func isCompatible(_ state: PlaybackState, with identity: PlaybackIdentity) -> Bool {
    if let podibleID = identity.podibleID,
      let statePodibleID = state.bookPodibleID,
      statePodibleID != podibleID
    {
      return false
    }

    let stateIDs = Self.decodedAliases(state.aliasesJSON).union([state.canonicalID])
    let encodedManifestationIDs = Set(stateIDs.compactMap(PlaybackIdentity.manifestationID(in:)))
    if let manifestationID = identity.manifestationID {
      if let stateManifestationID = state.manifestationID,
        stateManifestationID != manifestationID
      {
        return false
      }
      if encodedManifestationIDs.isEmpty == false,
        encodedManifestationIDs.contains(manifestationID) == false
      {
        return false
      }
    } else if state.manifestationID != nil || encodedManifestationIDs.isEmpty == false {
      return false
    }
    return true
  }

  private func copyPlayback(from source: PlaybackState, to target: PlaybackState) {
    target.positionSeconds = source.positionSeconds
    target.durationSeconds = source.durationSeconds
    target.playbackRate = source.playbackRate
    target.lastPlayedAt = source.lastPlayedAt
    target.updatedAt = source.updatedAt
  }

  private func rawState(for resumeID: String) -> PlaybackState {
    if let state = exactState(for: resumeID) { return state }
    let state = PlaybackState(
      canonicalID: resumeID,
      aliasesJSON: nil,
      manifestationID: PlaybackIdentity.manifestationID(in: resumeID)
    )
    context.insert(state)
    cachedStates.append(state)
    statesByCanonicalID[resumeID] = state
    return state
  }

  private func playbackIdentities(for book: LibraryBook) -> [PlaybackIdentity] {
    guard let data = book.playbackJSON,
      let playback = try? JSONDecoder().decode(PodiblePlayback.self, from: data)
    else {
      return [
        PlaybackIdentity(
          openLibraryWorkID: book.openLibraryWorkID,
          podibleID: book.podibleId,
          manifestationID: nil
        )
      ]
    }

    let manifestationIDs = ([playback.audio] + playback.audioOptions.map(Optional.some))
      .compactMap { $0?.manifestationId }
      .reduce(into: [Int]()) { result, manifestationID in
        if result.contains(manifestationID) == false {
          result.append(manifestationID)
        }
      }
    return (manifestationIDs.isEmpty ? [nil] : manifestationIDs.map(Optional.some)).map {
      PlaybackIdentity(
        openLibraryWorkID: book.openLibraryWorkID,
        podibleID: book.podibleId,
        manifestationID: $0
      )
    }
  }

  private func removeLegacyDefaults(for identity: PlaybackIdentity) {
    for resumeID in identity.migrationResumeIDs {
      defaults.removeObject(forKey: Keys.resumePrefix + resumeID)
    }
  }

  private func defaultPlaybackRate() -> Double {
    (defaults.object(forKey: Keys.rate) as? NSNumber)?.doubleValue ?? 1
  }
}
