import Foundation
import SwiftData

enum DownloadStatus: String, Codable, CaseIterable {
  case notStarted
  case downloading
  case paused
  case failed
  case completed
}

enum BookFileFormat: String, Codable, CaseIterable {
  case m4b
  case mp3
  case m4a
  case flac
  case ogg
  case unknown
}

extension BookFileFormat {
  static func fromFilename(_ filename: String) -> BookFileFormat {
    let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
    switch ext {
    case "m4b":
      return .m4b
    case "mp3":
      return .mp3
    case "m4a":
      return .m4a
    case "flac":
      return .flac
    case "ogg", "oga":
      return .ogg
    default:
      return .unknown
    }
  }
}

@Model
final class Author {
  @Attribute(.unique) var llId: String
  var name: String
  var sortName: String?
  @Relationship(deleteRule: .nullify, inverse: \LibraryBook.author) var books: [LibraryBook] = []

  init(llId: String, name: String, sortName: String? = nil) {
    self.llId = llId
    self.name = name
    self.sortName = sortName
  }
}

@Model
final class Series {
  @Attribute(.unique) var llId: String
  var title: String
  var sortTitle: String?
  @Relationship(deleteRule: .nullify, inverse: \LibraryBook.series) var books: [LibraryBook] = []

  init(llId: String, title: String, sortTitle: String? = nil) {
    self.llId = llId
    self.title = title
    self.sortTitle = sortTitle
  }
}

@Model
final class LibraryBook {
  @Attribute(.unique) var llId: String
  var openLibraryWorkID: String?
  var title: String
  var sortTitle: String?
  var summary: String?
  var coverURLString: String?
  var runtimeSeconds: Int?
  var addedAt: Date?
  var updatedAt: Date?
  var seriesIndex: Double?
  var bookStatusRaw: String?
  var audioStatusRaw: String?

  var author: Author?
  var series: Series?
  @Relationship(deleteRule: .nullify, inverse: \LibraryBookFile.book) var files: [LibraryBookFile] =
    []
  @Relationship(deleteRule: .cascade, inverse: \LocalBookState.book) var localState: LocalBookState?

  init(
    llId: String,
    openLibraryWorkID: String? = nil,
    title: String,
    sortTitle: String? = nil,
    summary: String? = nil,
    coverURLString: String? = nil,
    runtimeSeconds: Int? = nil,
    addedAt: Date? = nil,
    updatedAt: Date? = nil,
    seriesIndex: Double? = nil,
    bookStatusRaw: String? = nil,
    audioStatusRaw: String? = nil,
    author: Author? = nil,
    series: Series? = nil
  ) {
    self.llId = llId
    self.openLibraryWorkID = openLibraryWorkID
    self.title = title
    self.sortTitle = sortTitle
    self.summary = summary
    self.coverURLString = coverURLString
    self.runtimeSeconds = runtimeSeconds
    self.addedAt = addedAt
    self.updatedAt = updatedAt
    self.seriesIndex = seriesIndex
    self.bookStatusRaw = bookStatusRaw
    self.audioStatusRaw = audioStatusRaw
    self.author = author
    self.series = series
  }
}

@Model
final class LibraryBookFile {
  @Attribute(.unique) var llId: String
  var filename: String
  var format: BookFileFormat
  var sizeBytes: Int64
  var checksum: String?
  var trackCount: Int?
  var chapterInfoJSON: Data?
  var downloadStatus: DownloadStatus
  var bytesDownloaded: Int64
  var lastError: String?
  var localRelativePath: String?

  var book: LibraryBook?

  init(
    llId: String,
    filename: String,
    format: BookFileFormat = .unknown,
    sizeBytes: Int64 = 0,
    checksum: String? = nil,
    trackCount: Int? = nil,
    chapterInfoJSON: Data? = nil,
    downloadStatus: DownloadStatus = .notStarted,
    bytesDownloaded: Int64 = 0,
    lastError: String? = nil,
    localRelativePath: String? = nil,
    book: LibraryBook? = nil
  ) {
    self.llId = llId
    self.filename = filename
    self.format = format
    self.sizeBytes = sizeBytes
    self.checksum = checksum
    self.trackCount = trackCount
    self.chapterInfoJSON = chapterInfoJSON
    self.downloadStatus = downloadStatus
    self.bytesDownloaded = bytesDownloaded
    self.lastError = lastError
    self.localRelativePath = localRelativePath
    self.book = book
  }
}

@Model
final class LocalBookState {
  @Attribute(.unique) var bookLlId: String
  var isDownloaded: Bool
  var progressSeconds: Double
  var lastPlayedAt: Date?
  var playbackRate: Double

  var book: LibraryBook?

  init(
    bookLlId: String,
    isDownloaded: Bool = false,
    progressSeconds: Double = 0,
    lastPlayedAt: Date? = nil,
    playbackRate: Double = 1.0,
    book: LibraryBook? = nil
  ) {
    self.bookLlId = bookLlId
    self.isDownloaded = isDownloaded
    self.progressSeconds = progressSeconds
    self.lastPlayedAt = lastPlayedAt
    self.playbackRate = playbackRate
    self.book = book
  }
}

@Model
final class LibrarySyncState {
  static let libraryScope = "library"

  @Attribute(.unique) var scope: String
  var lastSync: Date?
  var insertedBooks: Int
  var updatedBooks: Int
  var insertedAuthors: Int
  var updatedAuthors: Int

  init(
    scope: String = LibrarySyncState.libraryScope,
    lastSync: Date? = nil,
    insertedBooks: Int = 0,
    updatedBooks: Int = 0,
    insertedAuthors: Int = 0,
    updatedAuthors: Int = 0
  ) {
    self.scope = scope
    self.lastSync = lastSync
    self.insertedBooks = insertedBooks
    self.updatedBooks = updatedBooks
    self.insertedAuthors = insertedAuthors
    self.updatedAuthors = updatedAuthors
  }
}
