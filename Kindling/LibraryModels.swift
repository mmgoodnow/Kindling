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
  @Attribute(.unique, originalName: "llId") var podibleId: String
  var name: String
  var sortName: String?
  @Relationship(deleteRule: .nullify, inverse: \LibraryBook.author) var books: [LibraryBook] = []

  init(podibleId: String, name: String, sortName: String? = nil) {
    self.podibleId = podibleId
    self.name = name
    self.sortName = sortName
  }
}

@Model
final class Series {
  @Attribute(.unique, originalName: "llId") var podibleId: String
  var title: String
  var sortTitle: String?
  @Relationship(deleteRule: .nullify, inverse: \LibraryBook.series) var books: [LibraryBook] = []

  init(podibleId: String, title: String, sortTitle: String? = nil) {
    self.podibleId = podibleId
    self.title = title
    self.sortTitle = sortTitle
  }
}

@Model
final class LibraryBook {
  @Attribute(.unique, originalName: "llId") var podibleId: String
  var openLibraryWorkID: String?
  var title: String
  var sortTitle: String?
  var summary: String?
  var descriptionHTML: String?
  var coverURLString: String?
  var runtimeSeconds: Int?
  var wordCount: Int?
  var publishedYear: Int?
  var narrator: String?
  var addedAt: Date?
  var updatedAt: Date?
  var fullPseudoProgress: Int?
  var seriesIndex: Double?
  var seriesMembershipsJSON: Data?
  var bookStatusRaw: String?
  var audioStatusRaw: String?
  var playbackJSON: Data?

  var author: Author?
  var series: Series?
  @Relationship(deleteRule: .nullify, inverse: \LibraryBookFile.book) var files: [LibraryBookFile] =
    []
  @Relationship(deleteRule: .cascade, inverse: \LocalBookState.book) var localState: LocalBookState?

  init(
    podibleId: String,
    openLibraryWorkID: String? = nil,
    title: String,
    sortTitle: String? = nil,
    summary: String? = nil,
    descriptionHTML: String? = nil,
    coverURLString: String? = nil,
    runtimeSeconds: Int? = nil,
    wordCount: Int? = nil,
    publishedYear: Int? = nil,
    narrator: String? = nil,
    addedAt: Date? = nil,
    updatedAt: Date? = nil,
    fullPseudoProgress: Int? = nil,
    seriesIndex: Double? = nil,
    seriesMembershipsJSON: Data? = nil,
    bookStatusRaw: String? = nil,
    audioStatusRaw: String? = nil,
    playbackJSON: Data? = nil,
    author: Author? = nil,
    series: Series? = nil
  ) {
    self.podibleId = podibleId
    self.openLibraryWorkID = openLibraryWorkID
    self.title = title
    self.sortTitle = sortTitle
    self.summary = summary
    self.descriptionHTML = descriptionHTML
    self.coverURLString = coverURLString
    self.runtimeSeconds = runtimeSeconds
    self.wordCount = wordCount
    self.publishedYear = publishedYear
    self.narrator = narrator
    self.addedAt = addedAt
    self.updatedAt = updatedAt
    self.fullPseudoProgress = fullPseudoProgress
    self.seriesIndex = seriesIndex
    self.seriesMembershipsJSON = seriesMembershipsJSON
    self.bookStatusRaw = bookStatusRaw
    self.audioStatusRaw = audioStatusRaw
    self.playbackJSON = playbackJSON
    self.author = author
    self.series = series
  }
}

@Model
final class LibraryBookFile {
  @Attribute(.unique, originalName: "llId") var podibleId: String
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
    podibleId: String,
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
    self.podibleId = podibleId
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
  @Attribute(.unique, originalName: "bookLlId") var bookPodibleId: String
  var isDownloaded: Bool
  var isFavorite: Bool?
  var isRead: Bool?
  var progressSeconds: Double
  var lastPlayedAt: Date?
  var playbackRate: Double

  var book: LibraryBook?

  init(
    bookPodibleId: String,
    isDownloaded: Bool = false,
    isFavorite: Bool = false,
    isRead: Bool = false,
    progressSeconds: Double = 0,
    lastPlayedAt: Date? = nil,
    playbackRate: Double = 1.0,
    book: LibraryBook? = nil
  ) {
    self.bookPodibleId = bookPodibleId
    self.isDownloaded = isDownloaded
    self.isFavorite = isFavorite
    self.isRead = isRead
    self.progressSeconds = progressSeconds
    self.lastPlayedAt = lastPlayedAt
    self.playbackRate = playbackRate
    self.book = book
  }
}

func setReadState(_ isRead: Bool, on state: LocalBookState) {
  state.isRead = isRead
  if isRead {
    state.isFavorite = true
  }
}

func isSavedBookState(_ state: LocalBookState?, progress: Double? = nil) -> Bool {
  state?.isFavorite == true || state?.isRead == true || (progress ?? 0) > 0
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
