import Foundation
import SwiftData

@MainActor
struct LibrarySyncService {
  struct Summary {
    let items: [PodibleLibraryItem]
    let insertedBooks: Int
    let updatedBooks: Int
    let insertedAuthors: Int
    let updatedAuthors: Int
  }

  func syncLibrary(using client: RemoteLibraryServing, modelContext: ModelContext) async throws
    -> Summary
  {
    let items = try await client.fetchLibraryItems()
    let existingAuthors = try modelContext.fetch(FetchDescriptor<Author>())
    let existingSeries = try modelContext.fetch(FetchDescriptor<Series>())
    let existingBooks = try modelContext.fetch(FetchDescriptor<LibraryBook>())
    let remoteIDs = Set(items.map(\.id))

    var authorsById = Dictionary(
      uniqueKeysWithValues: existingAuthors.map { ($0.podibleId, $0) })
    var seriesById = Dictionary(uniqueKeysWithValues: existingSeries.map { ($0.podibleId, $0) })
    var booksById = Dictionary(uniqueKeysWithValues: existingBooks.map { ($0.podibleId, $0) })
    var booksByOpenLibraryWorkID: [String: LibraryBook] = [:]
    var booksByIdentity: [String: LibraryBook] = [:]
    for book in existingBooks {
      if let workID = book.openLibraryWorkID, workID.isEmpty == false {
        booksByOpenLibraryWorkID[workID] = booksByOpenLibraryWorkID[workID] ?? book
      }
      guard let key = bookIdentityKey(title: book.title, author: book.author?.name) else {
        continue
      }
      booksByIdentity[key] = booksByIdentity[key] ?? book
    }

    var insertedAuthors = 0
    var updatedAuthors = 0
    var insertedBooks = 0
    var updatedBooks = 0

    for item in items {
      let authorKey = normalizeAuthorKey(item.author)
      let author: Author
      if let existing = authorsById[authorKey] {
        author = existing
        if existing.name != item.author {
          existing.name = item.author
          updatedAuthors += 1
        }
      } else {
        let created = Author(podibleId: authorKey, name: item.author)
        modelContext.insert(created)
        authorsById[authorKey] = created
        author = created
        insertedAuthors += 1
      }
      let series = series(for: item, seriesById: &seriesById, modelContext: modelContext)

      let book: LibraryBook
      if let existing = booksById[item.id] {
        book = existing
        updatedBooks += updateBook(book, with: item, author: author, series: series)
      } else if let workID = item.openLibraryWorkID,
        let existing = booksByOpenLibraryWorkID[workID]
      {
        booksById[existing.podibleId] = nil
        existing.podibleId = item.id
        booksById[item.id] = existing
        book = existing
        updatedBooks += updateBook(book, with: item, author: author, series: series)
      } else if let identityKey = bookIdentityKey(title: item.title, author: item.author),
        let existing = booksByIdentity[identityKey]
      {
        booksById[existing.podibleId] = nil
        existing.podibleId = item.id
        booksById[item.id] = existing
        book = existing
        updatedBooks += updateBook(book, with: item, author: author, series: series)
      } else {
        let created = LibraryBook(
          podibleId: item.id,
          openLibraryWorkID: item.openLibraryWorkID,
          title: item.title,
          summary: item.summary,
          descriptionHTML: item.descriptionHTML,
          coverURLString: item.bookImagePath,
          runtimeSeconds: item.runtimeSeconds,
          wordCount: item.wordCount,
          publishedYear: item.publishedYear,
          narrator: item.narrator,
          addedAt: item.bookAdded,
          updatedAt: latestLibraryDate(for: item),
          fullPseudoProgress: item.fullPseudoProgress,
          seriesIndex: item.seriesPosition,
          seriesMembershipsJSON: podibleSeriesMembershipsData(item.series),
          bookStatusRaw: (item.ebookStatus ?? item.status).rawValue,
          audioStatusRaw: item.audioStatus?.rawValue,
          playbackJSON: playbackData(for: item.playback),
          author: author,
          series: series
        )
        modelContext.insert(created)
        booksById[item.id] = created
        if let workID = item.openLibraryWorkID, workID.isEmpty == false {
          booksByOpenLibraryWorkID[workID] = created
        }
        if let identityKey = bookIdentityKey(title: item.title, author: item.author) {
          booksByIdentity[identityKey] = created
        }
        book = created
        insertedBooks += 1
      }

    }

    for book in existingBooks where remoteIDs.contains(book.podibleId) == false {
      let shouldDelete = shouldDeleteLocalMirror(book)
      guard shouldDelete else { continue }
      deleteLocalMirror(book, modelContext: modelContext)
      booksById[book.podibleId] = nil
    }

    for author in existingAuthors where author.books.isEmpty {
      modelContext.delete(author)
    }
    for series in existingSeries where series.books.isEmpty {
      modelContext.delete(series)
    }

    if modelContext.hasChanges {
      try modelContext.save()
    }

    return Summary(
      items: items,
      insertedBooks: insertedBooks,
      updatedBooks: updatedBooks,
      insertedAuthors: insertedAuthors,
      updatedAuthors: updatedAuthors
    )
  }

  private func normalizeAuthorKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func normalizeBookKey(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func bookIdentityKey(title: String, author: String?) -> String? {
    guard let author, author.isEmpty == false else { return nil }
    return "\(normalizeAuthorKey(author))::\(normalizeBookKey(title))"
  }

  private func series(
    for item: PodibleLibraryItem,
    seriesById: inout [String: Series],
    modelContext: ModelContext
  ) -> Series? {
    guard let key = seriesKey(for: item) else { return nil }
    let title = item.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayTitle = title?.isEmpty == false ? title! : key
    if let existing = seriesById[key] {
      if existing.title != displayTitle {
        existing.title = displayTitle
      }
      return existing
    }
    let created = Series(podibleId: key, title: displayTitle)
    modelContext.insert(created)
    seriesById[key] = created
    return created
  }

  private func seriesKey(for item: PodibleLibraryItem) -> String? {
    if let raw = item.seriesKey?.trimmingCharacters(in: .whitespacesAndNewlines),
      raw.isEmpty == false
    {
      return raw
    }
    guard let title = item.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      title.isEmpty == false
    else {
      return nil
    }
    return title.lowercased()
  }

  private func latestLibraryDate(for item: PodibleLibraryItem) -> Date? {
    item.updatedAt
  }

  private func updateBook(
    _ book: LibraryBook,
    with item: PodibleLibraryItem,
    author: Author,
    series: Series?
  )
    -> Int
  {
    var updated = 0
    if let localState = book.localState, localState.bookPodibleId != item.id {
      localState.bookPodibleId = item.id
      updated += 1
    }
    if book.openLibraryWorkID != item.openLibraryWorkID {
      book.openLibraryWorkID = item.openLibraryWorkID
      updated += 1
    }
    if book.title != item.title {
      book.title = item.title
      updated += 1
    }
    if book.summary != item.summary {
      book.summary = item.summary
      updated += 1
    }
    if book.descriptionHTML != item.descriptionHTML {
      book.descriptionHTML = item.descriptionHTML
      updated += 1
    }
    if book.coverURLString != item.bookImagePath {
      book.coverURLString = item.bookImagePath
      updated += 1
    }
    if book.runtimeSeconds != item.runtimeSeconds {
      book.runtimeSeconds = item.runtimeSeconds
      updated += 1
    }
    if book.wordCount != item.wordCount {
      book.wordCount = item.wordCount
      updated += 1
    }
    if book.publishedYear != item.publishedYear {
      book.publishedYear = item.publishedYear
      updated += 1
    }
    if book.narrator != item.narrator {
      book.narrator = item.narrator
      updated += 1
    }
    let nextAddedAt = item.bookAdded
    if book.addedAt != nextAddedAt {
      book.addedAt = nextAddedAt
      updated += 1
    }
    let nextUpdatedAt = latestLibraryDate(for: item)
    if book.updatedAt != nextUpdatedAt {
      book.updatedAt = nextUpdatedAt
      updated += 1
    }
    if book.author !== author {
      book.author = author
      updated += 1
    }
    if book.series !== series {
      book.series = series
      updated += 1
    }
    if book.seriesIndex != item.seriesPosition {
      book.seriesIndex = item.seriesPosition
      updated += 1
    }
    let nextSeriesMembershipsJSON = podibleSeriesMembershipsData(item.series)
    if book.seriesMembershipsJSON != nextSeriesMembershipsJSON {
      book.seriesMembershipsJSON = nextSeriesMembershipsJSON
      updated += 1
    }
    if book.fullPseudoProgress != item.fullPseudoProgress {
      book.fullPseudoProgress = item.fullPseudoProgress
      updated += 1
    }
    let ebookRaw = (item.ebookStatus ?? item.status).rawValue
    if book.bookStatusRaw != ebookRaw {
      book.bookStatusRaw = ebookRaw
      updated += 1
    }
    if book.audioStatusRaw != item.audioStatus?.rawValue {
      book.audioStatusRaw = item.audioStatus?.rawValue
      updated += 1
    }
    if let playback = item.playback {
      let nextPlaybackJSON = playbackData(for: playback)
      if book.playbackJSON != nextPlaybackJSON {
        book.playbackJSON = nextPlaybackJSON
        updated += 1
      }
    }
    return updated > 0 ? 1 : 0
  }

  private func playbackData(for playback: PodiblePlayback?) -> Data? {
    guard let playback else { return nil }
    return try? JSONEncoder().encode(playback)
  }

  private func shouldDeleteLocalMirror(_ book: LibraryBook) -> Bool {
    if let localState = book.localState, localState.isDownloaded {
      return false
    }
    if let localState = book.localState,
      localState.isFavorite == true || localState.isRead == true
    {
      return false
    }
    for file in book.files {
      if file.localRelativePath?.isEmpty == false { return false }
      if file.downloadStatus == .completed { return false }
    }
    if shouldPreservePendingMirror(book) {
      return false
    }
    return true
  }

  private func shouldPreservePendingMirror(_ book: LibraryBook) -> Bool {
    let statuses = [book.bookStatusRaw, book.audioStatusRaw].compactMap {
      $0.flatMap(PodibleLibraryItemStatus.init(rawValue:))
    }
    for status in statuses {
      switch status {
      case .requested, .wanted, .snatched, .seeding:
        return true
      default:
        continue
      }
    }
    return false
  }

  private func deleteLocalMirror(_ book: LibraryBook, modelContext: ModelContext) {
    if let localState = book.localState {
      modelContext.delete(localState)
    }
    for file in book.files {
      modelContext.delete(file)
    }
    modelContext.delete(book)
  }
}
