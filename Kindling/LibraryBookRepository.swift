import Foundation
import SwiftData

enum LibraryBookPersistenceMapper {
  static func make(
    item: PodibleLibraryItem,
    author: Author,
    series: Series?
  ) -> LibraryBook {
    LibraryBook(
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
      updatedAt: item.updatedAt,
      fullPseudoProgress: item.fullPseudoProgress,
      seriesIndex: item.seriesPosition,
      seriesMembershipsJSON: podibleSeriesMembershipsData(item.series),
      bookStatusRaw: (item.ebookStatus ?? item.status).rawValue,
      audioStatusRaw: item.audioStatus?.rawValue,
      playbackJSON: playbackData(for: item.playback),
      author: author,
      series: series
    )
  }

  @discardableResult
  static func update(
    _ book: LibraryBook,
    with item: PodibleLibraryItem,
    author: Author,
    series: Series?
  ) -> Bool {
    var updated = false
    if let localState = book.localState, localState.bookPodibleId != item.id {
      localState.bookPodibleId = item.id
      updated = true
    }
    updated = assign(\.openLibraryWorkID, on: book, value: item.openLibraryWorkID) || updated
    updated = assign(\.title, on: book, value: item.title) || updated
    updated = assign(\.summary, on: book, value: item.summary) || updated
    updated = assign(\.descriptionHTML, on: book, value: item.descriptionHTML) || updated
    updated = assign(\.coverURLString, on: book, value: item.bookImagePath) || updated
    updated = assign(\.runtimeSeconds, on: book, value: item.runtimeSeconds) || updated
    updated = assign(\.wordCount, on: book, value: item.wordCount) || updated
    updated = assign(\.publishedYear, on: book, value: item.publishedYear) || updated
    updated = assign(\.narrator, on: book, value: item.narrator) || updated
    updated = assign(\.addedAt, on: book, value: item.bookAdded) || updated
    updated = assign(\.updatedAt, on: book, value: item.updatedAt) || updated
    if book.author !== author {
      book.author = author
      updated = true
    }
    if book.series !== series {
      book.series = series
      updated = true
    }
    updated = assign(\.seriesIndex, on: book, value: item.seriesPosition) || updated
    updated =
      assign(
        \.seriesMembershipsJSON,
        on: book,
        value: podibleSeriesMembershipsData(item.series)
      ) || updated
    updated = assign(\.fullPseudoProgress, on: book, value: item.fullPseudoProgress) || updated
    updated =
      assign(\.bookStatusRaw, on: book, value: (item.ebookStatus ?? item.status).rawValue)
      || updated
    updated = assign(\.audioStatusRaw, on: book, value: item.audioStatus?.rawValue) || updated
    if let playback = item.playback {
      updated = assign(\.playbackJSON, on: book, value: playbackData(for: playback)) || updated
    }
    return updated
  }

  static func seriesKey(for item: PodibleLibraryItem) -> String? {
    if let raw = item.seriesKey?.trimmingCharacters(in: .whitespacesAndNewlines),
      raw.isEmpty == false
    {
      return raw
    }
    guard let title = item.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      title.isEmpty == false
    else { return nil }
    return title.lowercased()
  }

  private static func playbackData(for playback: PodiblePlayback?) -> Data? {
    guard let playback else { return nil }
    return try? JSONEncoder().encode(playback)
  }

  private static func assign<Value: Equatable>(
    _ keyPath: ReferenceWritableKeyPath<LibraryBook, Value>,
    on book: LibraryBook,
    value: Value
  ) -> Bool {
    guard book[keyPath: keyPath] != value else { return false }
    book[keyPath: keyPath] = value
    return true
  }
}

@MainActor
struct LibraryBookRepository {
  let modelContext: ModelContext

  func upsert(_ item: PodibleLibraryItem, existing: LibraryBook?) -> LibraryBook {
    let author = fetchOrCreateAuthor(name: item.author)
    let series = fetchOrCreateSeries(for: item)
    if let existing {
      LibraryBookPersistenceMapper.update(existing, with: item, author: author, series: series)
      return existing
    }

    let book = LibraryBookPersistenceMapper.make(item: item, author: author, series: series)
    modelContext.insert(book)
    return book
  }

  private func fetchOrCreateAuthor(name: String) -> Author {
    let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let descriptor = FetchDescriptor<Author>(predicate: #Predicate { $0.podibleId == key })
    if let existing = (try? modelContext.fetch(descriptor))?.first {
      if existing.name != name {
        existing.name = name
      }
      return existing
    }
    let author = Author(podibleId: key, name: name)
    modelContext.insert(author)
    return author
  }

  private func fetchOrCreateSeries(for item: PodibleLibraryItem) -> Series? {
    guard let key = LibraryBookPersistenceMapper.seriesKey(for: item) else { return nil }
    let title = item.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayTitle = title?.isEmpty == false ? title! : key
    let descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.podibleId == key })
    if let existing = (try? modelContext.fetch(descriptor))?.first {
      if existing.title != displayTitle {
        existing.title = displayTitle
      }
      return existing
    }
    let series = Series(podibleId: key, title: displayTitle)
    modelContext.insert(series)
    return series
  }
}
