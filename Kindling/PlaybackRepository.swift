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
      let identity = PlaybackIdentity(canonicalID: resumeID)
      let state = state(for: identity, createIfNeeded: true)
      state.positionSeconds = max(state.positionSeconds, position)
      state.playbackRate = rate
      state.updatedAt = max(state.updatedAt, .distantPast)
    }
    if let data = defaults.data(forKey: "audioPlayer.lastSession"),
      let session = try? JSONDecoder().decode(LegacySession.self, from: data)
    {
      let identity = PlaybackIdentity(
        canonicalID: session.resumeID,
        podibleID: session.podibleID,
        manifestationID: session.manifestationID
      )
      let state = state(for: identity, createIfNeeded: true)
      state.bookPodibleID = session.podibleID ?? state.bookPodibleID
      state.manifestationID = session.manifestationID ?? state.manifestationID
    }
    favoriteBooksWithPlaybackProgress()
    try reconcileRecoveryCheckpoint()
    try saveIfNeeded()
  }

  func position(for identity: PlaybackIdentity) -> Double {
    if let exact = exactState(for: identity.canonicalID) {
      return exact.positionSeconds
    }
    if let recovered = aliasState(for: identity) {
      return recovered.positionSeconds
    }
    return legacyPosition(for: identity)
  }

  func progress(for identity: PlaybackIdentity, duration: Double?) -> Double? {
    guard let duration, duration.isFinite, duration > 0 else { return nil }
    let position = position(for: identity)
    guard position > 0, position < duration - 0.5 else { return nil }
    return min(max(position / duration, 0), 1)
  }

  func playbackRate(for identity: PlaybackIdentity?) -> Double {
    if let identity, let state = exactState(for: identity.canonicalID) ?? aliasState(for: identity)
    {
      return state.playbackRate
    }
    return (defaults.object(forKey: Keys.rate) as? NSNumber)?.doubleValue ?? 1
  }

  func lastPlayedAt(for identity: PlaybackIdentity) -> Date? {
    (exactState(for: identity.canonicalID) ?? aliasState(for: identity))?.lastPlayedAt
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
      aliases: identity.allResumeIDs,
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

    let state = state(for: identity, createIfNeeded: true)
    apply(checkpoint, to: state)
    try? saveIfNeeded()
  }

  func setPlaybackRate(_ rate: Double, identity: PlaybackIdentity?) {
    defaults.set(rate, forKey: Keys.rate)
    guard let identity else { return }
    let state = state(for: identity, createIfNeeded: true)
    state.playbackRate = rate
    state.updatedAt = Date()
    try? saveIfNeeded()
  }

  func clear(identity: PlaybackIdentity) {
    for state in matchingStates(for: identity) {
      state.positionSeconds = 0
      state.updatedAt = Date()
    }
    try? saveIfNeeded()
    defaults.removeObject(forKey: Keys.recoveryCheckpoint)
  }

  func flushRecoveryJournal() {
    try? reconcileRecoveryCheckpoint()
    try? saveIfNeeded()
  }

  private func state(for identity: PlaybackIdentity, createIfNeeded: Bool) -> PlaybackState {
    if let exact = exactState(for: identity.canonicalID) {
      exact.aliasesJSON = encodedAliases(identity.allResumeIDs)
      exact.bookPodibleID = identity.podibleID ?? exact.bookPodibleID
      exact.manifestationID = identity.manifestationID ?? exact.manifestationID
      return exact
    }

    let source = aliasState(for: identity)
    let state = PlaybackState(
      canonicalID: identity.canonicalID,
      aliasesJSON: encodedAliases(identity.allResumeIDs),
      bookPodibleID: identity.podibleID,
      manifestationID: identity.manifestationID,
      positionSeconds: source?.positionSeconds ?? legacyPosition(for: identity),
      durationSeconds: source?.durationSeconds,
      playbackRate: source?.playbackRate ?? playbackRate(for: nil),
      lastPlayedAt: source?.lastPlayedAt,
      updatedAt: source?.updatedAt ?? Date()
    )
    if createIfNeeded {
      context.insert(state)
      cachedStates.append(state)
      statesByCanonicalID[state.canonicalID] = state
    }
    return state
  }

  private func reconcileRecoveryCheckpoint() throws {
    guard let data = defaults.data(forKey: Keys.recoveryCheckpoint),
      let checkpoint = try? JSONDecoder().decode(RecoveryCheckpoint.self, from: data)
    else { return }
    let identity = PlaybackIdentity(
      canonicalID: checkpoint.canonicalID,
      aliases: checkpoint.aliases,
      podibleID: checkpoint.bookPodibleID,
      manifestationID: checkpoint.manifestationID
    )
    let hadExactState = exactState(for: identity.canonicalID) != nil
    let state = state(for: identity, createIfNeeded: true)
    if hadExactState == false || checkpoint.updatedAt >= state.updatedAt {
      apply(checkpoint, to: state)
    }
  }

  private func apply(_ checkpoint: RecoveryCheckpoint, to state: PlaybackState) {
    state.aliasesJSON = encodedAliases(checkpoint.aliases)
    state.bookPodibleID = checkpoint.bookPodibleID
    state.manifestationID = checkpoint.manifestationID
    state.positionSeconds = checkpoint.positionSeconds
    state.durationSeconds = checkpoint.durationSeconds
    state.playbackRate = checkpoint.playbackRate
    state.lastPlayedAt = checkpoint.updatedAt
    state.updatedAt = checkpoint.updatedAt
  }

  private func exactState(for canonicalID: String) -> PlaybackState? {
    statesByCanonicalID[canonicalID]
  }

  private func aliasState(for identity: PlaybackIdentity) -> PlaybackState? {
    matchingStates(for: identity).max { $0.updatedAt < $1.updatedAt }
  }

  private func matchingStates(for identity: PlaybackIdentity) -> [PlaybackState] {
    let resumeIDs = Set(identity.allResumeIDs)
    return allStates().filter { state in
      resumeIDs.contains(state.canonicalID)
        || resumeIDs.isDisjoint(with: decodedAliases(state.aliasesJSON)) == false
    }
  }

  private func allStates() -> [PlaybackState] {
    cachedStates
  }

  private func legacyPosition(for identity: PlaybackIdentity) -> Double {
    identity.allResumeIDs.compactMap { resumeID in
      (defaults.object(forKey: Keys.resumePrefix + resumeID) as? NSNumber)?.doubleValue
    }.max() ?? 0
  }

  private func encodedAliases(_ aliases: [String]) -> Data? {
    try? JSONEncoder().encode(aliases)
  }

  private func decodedAliases(_ data: Data?) -> Set<String> {
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
}
