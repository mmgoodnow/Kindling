import Foundation
import SwiftData

@MainActor
struct LibrarySyncService {
  struct Summary {
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
    let existingBooks = try modelContext.fetch(FetchDescriptor<LibraryBook>())
    let remoteIDs = Set(items.map(\.id))

    var authorsById = Dictionary(
      uniqueKeysWithValues: existingAuthors.map { ($0.llId, $0) })
    var booksById = Dictionary(uniqueKeysWithValues: existingBooks.map { ($0.llId, $0) })
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
        let created = Author(llId: authorKey, name: item.author)
        modelContext.insert(created)
        authorsById[authorKey] = created
        author = created
        insertedAuthors += 1
      }

      let book: LibraryBook
      if let existing = booksById[item.id] {
        book = existing
        updatedBooks += updateBook(book, with: item, author: author)
      } else if let workID = item.openLibraryWorkID,
        let existing = booksByOpenLibraryWorkID[workID]
      {
        booksById[existing.llId] = nil
        existing.llId = item.id
        booksById[item.id] = existing
        book = existing
        updatedBooks += updateBook(book, with: item, author: author)
      } else if let identityKey = bookIdentityKey(title: item.title, author: item.author),
        let existing = booksByIdentity[identityKey]
      {
        booksById[existing.llId] = nil
        existing.llId = item.id
        booksById[item.id] = existing
        book = existing
        updatedBooks += updateBook(book, with: item, author: author)
      } else {
        let created = LibraryBook(
          llId: item.id,
          openLibraryWorkID: item.openLibraryWorkID,
          title: item.title,
          summary: item.summary,
          coverURLString: item.bookImagePath,
          runtimeSeconds: nil,
          addedAt: item.bookAdded,
          updatedAt: latestLibraryDate(for: item),
          seriesIndex: nil,
          bookStatusRaw: (item.ebookStatus ?? item.status).rawValue,
          audioStatusRaw: item.audioStatus?.rawValue,
          author: author,
          series: nil
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

    for book in existingBooks where remoteIDs.contains(book.llId) == false {
      guard shouldDeleteLocalMirror(book) else { continue }
      deleteLocalMirror(book, modelContext: modelContext)
      booksById[book.llId] = nil
    }

    for author in existingAuthors where author.books.isEmpty {
      modelContext.delete(author)
    }

    if modelContext.hasChanges {
      try modelContext.save()
    }

    return Summary(
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

  private func latestLibraryDate(for item: PodibleLibraryItem) -> Date? {
    item.updatedAt
  }

  private func updateBook(_ book: LibraryBook, with item: PodibleLibraryItem, author: Author)
    -> Int
  {
    var updated = 0
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
    if book.coverURLString != item.bookImagePath {
      book.coverURLString = item.bookImagePath
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
    let ebookRaw = (item.ebookStatus ?? item.status).rawValue
    if book.bookStatusRaw != ebookRaw {
      book.bookStatusRaw = ebookRaw
      updated += 1
    }
    if book.audioStatusRaw != item.audioStatus?.rawValue {
      book.audioStatusRaw = item.audioStatus?.rawValue
      updated += 1
    }
    return updated > 0 ? 1 : 0
  }

  private func shouldDeleteLocalMirror(_ book: LibraryBook) -> Bool {
    if let localState = book.localState, localState.isDownloaded {
      return false
    }
    for file in book.files {
      if file.localRelativePath?.isEmpty == false { return false }
      if file.downloadStatus == .completed { return false }
    }
    return true
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
