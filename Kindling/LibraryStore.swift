import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class LibraryStore {
  private(set) var books: [LibraryBook] = []
  private(set) var activities: [BookActivityState] = []
  private(set) var syncStates: [LibrarySyncState] = []

  func update(
    books: [LibraryBook],
    activities: [BookActivityState],
    syncStates: [LibrarySyncState]
  ) {
    self.books = books
    self.activities = activities
    self.syncStates = syncStates
  }

  func book(for id: String) -> LibraryBook? {
    books.first { $0.podibleId == id }
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
    switch collection {
    case .continueReading:
      books
        .filter {
          belongsInContinueReading(
            progress: progress($0),
            isRead: $0.localState?.isRead == true
          )
        }
        .sorted { lastPlayedAt($0) > lastPlayedAt($1) }
    case .tbr:
      books.filter {
        belongsInTBR(
          isFavorite: $0.localState?.isFavorite == true,
          isRead: $0.localState?.isRead == true,
          progress: progress($0)
        )
      }
    case .newOnPodible:
      books
        .filter {
          belongsInNewOnPodible(
            isFavorite: isSavedBookState($0.localState, progress: progress($0)),
            isRead: $0.localState?.isRead == true
          )
        }
        .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    case .recentlyViewed:
      books.filter { activity(for: $0.podibleId)?.lastViewedAt != nil }
        .sorted {
          (activity(for: $0.podibleId)?.lastViewedAt ?? .distantPast)
            > (activity(for: $1.podibleId)?.lastViewedAt ?? .distantPast)
        }
    case .read:
      books
        .filter { $0.localState?.isRead == true }
        .sorted {
          (activity(for: $0.podibleId)?.readAt ?? .distantPast)
            > (activity(for: $1.podibleId)?.readAt ?? .distantPast)
        }
    }
  }

  func activity(for bookID: String) -> BookActivityState? {
    activities.first { $0.bookPodibleID == bookID }
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
    return activity
  }

  private func save(_ context: ModelContext) throws {
    if context.hasChanges {
      try context.save()
    }
  }
}
