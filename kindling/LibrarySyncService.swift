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

  func syncLibrary(using client: LazyLibrarianServing, modelContext: ModelContext) async throws
    -> Summary
  {
    let items = try await client.fetchLibraryItems()
    let existingAuthors = try modelContext.fetch(FetchDescriptor<Author>())
    let existingBooks = try modelContext.fetch(FetchDescriptor<LibraryBook>())

    var authorsById = Dictionary(
      uniqueKeysWithValues: existingAuthors.map { ($0.llId, $0) })
    var booksById = Dictionary(uniqueKeysWithValues: existingBooks.map { ($0.llId, $0) })

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
      } else {
        let created = LibraryBook(
          llId: item.id,
          title: item.title,
          summary: nil,
          coverURLString: item.bookImagePath,
          runtimeSeconds: nil,
          addedAt: item.bookAdded,
          updatedAt: latestLibraryDate(for: item),
          seriesIndex: nil,
          author: author,
          series: nil
        )
        modelContext.insert(created)
        booksById[item.id] = created
        book = created
        insertedBooks += 1
      }

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

  private func latestLibraryDate(for item: LazyLibrarianLibraryItem) -> Date? {
    [item.bookLibrary, item.audioLibrary].compactMap { $0 }.max()
  }

  private func updateBook(_ book: LibraryBook, with item: LazyLibrarianLibraryItem, author: Author)
    -> Int
  {
    var updated = 0
    if book.title != item.title {
      book.title = item.title
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
    return updated > 0 ? 1 : 0
  }
}
