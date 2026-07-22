import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class LibraryStore {
  private(set) var books: [LibraryBook] = []
  private(set) var activities: [BookActivityState] = []
  private(set) var syncStates: [LibrarySyncState] = []
  private(set) var booksByID: [String: LibraryBook] = [:]
  private var activitiesByBookID: [String: BookActivityState] = [:]

  func update(
    books: [LibraryBook],
    activities: [BookActivityState],
    syncStates: [LibrarySyncState]
  ) {
    self.books = books
    self.activities = activities
    self.syncStates = syncStates
    self.booksByID = books.reduce(into: [:]) { result, book in
      result[book.podibleId] = book
    }
    self.activitiesByBookID = activities.reduce(into: [:]) { result, activity in
      result[activity.bookPodibleID] = activity
    }
  }

  func book(for id: String) -> LibraryBook? {
    booksByID[id]
  }

  func books(
    for mode: PodibleLibraryScreenMode,
    progress: (LibraryBook) -> Double?
  ) -> [LibraryBook] {
    switch mode {
    case .home, .library:
      books
    case .favorites:
      books.filter { isSavedBookState($0.localState, progress: progress($0)) }
    }
  }

  func books(
    for collection: LibraryCollection,
    progress: (LibraryBook) -> Double?,
    lastPlayedAt: (LibraryBook) -> Date
  ) -> [LibraryBook] {
    homeCollections(progress: progress, lastPlayedAt: lastPlayedAt)[collection] ?? []
  }

  func homeCollections(
    progress: (LibraryBook) -> Double?,
    lastPlayedAt: (LibraryBook) -> Date
  ) -> [LibraryCollection: [LibraryBook]] {
    var result: [LibraryCollection: [LibraryBook]] = Dictionary(
      uniqueKeysWithValues: LibraryCollection.allCases.map { ($0, [LibraryBook]()) }
    )
    var continueDates: [String: Date] = [:]

    for book in books {
      let playbackProgress = progress(book)
      let isRead = book.localState?.isRead == true
      let activity = activity(for: book.podibleId)

      if belongsInContinueReading(progress: playbackProgress, isRead: isRead) {
        result[.continueReading, default: []].append(book)
        continueDates[book.podibleId] = lastPlayedAt(book)
      }
      if belongsInTBR(
        isFavorite: book.localState?.isFavorite == true,
        isRead: isRead,
        progress: playbackProgress
      ) {
        result[.tbr, default: []].append(book)
      }
      if belongsInNewOnPodible(
        isFavorite: isSavedBookState(book.localState, progress: playbackProgress),
        isRead: isRead
      ) {
        result[.newOnPodible, default: []].append(book)
      }
      if activity?.lastViewedAt != nil {
        result[.recentlyViewed, default: []].append(book)
      }
      if isRead {
        result[.read, default: []].append(book)
      }
    }

    result[.continueReading]?.sort {
      (continueDates[$0.podibleId] ?? .distantPast)
        > (continueDates[$1.podibleId] ?? .distantPast)
    }
    result[.newOnPodible]?.sort {
      ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast)
    }
    result[.recentlyViewed]?.sort {
      (activity(for: $0.podibleId)?.lastViewedAt ?? .distantPast)
        > (activity(for: $1.podibleId)?.lastViewedAt ?? .distantPast)
    }
    result[.read]?.sort {
      (activity(for: $0.podibleId)?.readAt ?? .distantPast)
        > (activity(for: $1.podibleId)?.readAt ?? .distantPast)
    }
    return result
  }

  func activity(for bookID: String) -> BookActivityState? {
    activitiesByBookID[bookID]
  }

  func recordRecentlyViewed(
    bookID: String,
    at date: Date = Date(),
    context: ModelContext
  ) throws {
    ensureActivity(for: bookID, context: context).lastViewedAt = date
    try save(context)
  }

  func toggleRead(
    bookID: String,
    at date: Date = Date(),
    context: ModelContext
  ) throws {
    guard let book = book(for: bookID) else { return }
    let state = ensureLocalState(for: book, context: context)
    setReadState(!(state.isRead ?? false), on: state)
    ensureActivity(for: bookID, context: context).readAt = state.isRead == true ? date : nil
    try save(context)
  }

  func toggleFavorite(
    bookID: String,
    progress: Double?,
    context: ModelContext
  ) throws {
    guard let book = book(for: bookID) else { return }
    let state = ensureLocalState(for: book, context: context)
    guard state.isRead != true, (progress ?? 0) == 0 else { return }
    state.isFavorite = !(state.isFavorite ?? false)
    try save(context)
  }

  func markStarted(
    book: LibraryBook,
    at date: Date = Date(),
    context: ModelContext
  ) throws {
    let state = ensureLocalState(for: book, context: context)
    state.isFavorite = true
    state.lastPlayedAt = date
    try save(context)
  }

  func markDownloaded(
    book: LibraryBook,
    at date: Date = Date(),
    context: ModelContext
  ) throws {
    let state = ensureLocalState(for: book, context: context)
    state.isDownloaded = true
    state.lastPlayedAt = state.lastPlayedAt ?? date
    try save(context)
  }

  func markFinishedPlaybackRead(
    resumeID: String,
    identity: (LibraryBook) -> PlaybackIdentity,
    at date: Date = Date(),
    context: ModelContext
  ) throws {
    guard let book = books.first(where: { identity($0).matches(resumeID) }) else { return }
    let state = ensureLocalState(for: book, context: context)
    guard state.isRead != true else { return }
    setReadState(true, on: state)
    ensureActivity(for: book.podibleId, context: context).readAt = date
    try save(context)
  }

  func migrateLegacyActivityState(
    defaults: UserDefaults = .standard,
    now: Date = Date(),
    context: ModelContext
  ) throws {
    let key = "library.recentlyViewedBookIDs"
    let ids = defaults.string(forKey: key)?.split(separator: "\n").map(String.init) ?? []
    for (index, id) in ids.enumerated() {
      let activity = ensureActivity(for: id, context: context)
      if activity.lastViewedAt == nil {
        activity.lastViewedAt = now.addingTimeInterval(Double(-index))
      }
    }
    for book in books where book.localState?.isRead == true {
      let activity = ensureActivity(for: book.podibleId, context: context)
      activity.readAt = activity.readAt ?? book.localState?.lastPlayedAt ?? book.updatedAt ?? now
    }
    try save(context)
    if ids.isEmpty == false {
      defaults.removeObject(forKey: key)
    }
  }

  private func ensureLocalState(for book: LibraryBook, context: ModelContext) -> LocalBookState {
    if let state = book.localState { return state }
    let state = LocalBookState(bookPodibleId: book.podibleId, book: book)
    context.insert(state)
    book.localState = state
    return state
  }

  private func ensureActivity(for bookID: String, context: ModelContext) -> BookActivityState {
    if let activity = activity(for: bookID) { return activity }
    let activity = BookActivityState(bookPodibleID: bookID)
    context.insert(activity)
    activities.append(activity)
    activitiesByBookID[bookID] = activity
    return activity
  }

  private func save(_ context: ModelContext) throws {
    if context.hasChanges {
      try context.save()
    }
  }
}
