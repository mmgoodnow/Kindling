import Foundation

enum PodibleError: LocalizedError {
  case notConfigured
  case badURL
  case badResponse
  case server(String)
  case api(String)
  case unsupported(String)

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "Remote library backend is not configured."
    case .badURL:
      return "The backend URL looks invalid."
    case .badResponse:
      return "Could not parse the backend response."
    case .server(let message):
      return message
    case .api(let message):
      return message
    case .unsupported(let message):
      return message
    }
  }
}

enum PodibleLibraryItemStatus: String, Decodable {
  case requested = "Requested"
  case wanted = "Wanted"
  case snatched = "Snatched"
  case seeding = "Seeding"
  case downloaded = "Downloaded"
  case failed = "Failed"
  case have = "Have"
  case skipped = "Skipped"
  case open = "Open"
  case processed = "Processed"
  case ignored = "Ignored"
  case okay = "OK"
  case unknown = "Unknown"

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = PodibleLibraryItemStatus(rawValue: raw) ?? .unknown
  }

  var isComplete: Bool {
    switch self {
    case .downloaded, .have, .open, .processed:
      return true
    default:
      return false
    }
  }
}

struct PodibleBook: Identifiable, Hashable, Decodable {
  let id: String
  let title: String
  let author: String
  let status: PodibleLibraryItemStatus
  let audioStatus: PodibleLibraryItemStatus?
  let coverURL: URL?
  let coverImageURL: URL?
  let rating: Double?
  let ratingCount: Int?
  let published: String?
  let link: URL?

  init(
    id: String, title: String, author: String, status: PodibleLibraryItemStatus,
    audioStatus: PodibleLibraryItemStatus? = nil,
    coverURL: URL? = nil, coverImageURL: URL? = nil, rating: Double? = nil, ratingCount: Int? = nil,
    published: String? = nil, link: URL? = nil
  ) {
    self.id = id
    self.title = title
    self.author = author
    self.status = status
    self.audioStatus = audioStatus
    self.coverURL = coverURL
    self.coverImageURL = coverImageURL
    self.rating = rating
    self.ratingCount = ratingCount
    self.published = published
    self.link = link
  }

  private enum CodingKeys: String, CodingKey {
    case idLower = "bookid"
    case idUpper = "BookID"
    case idPlain = "id"
    case titleLower = "bookname"
    case titleUpper = "BookName"
    case authorLower = "authorname"
    case authorUpper = "AuthorName"
    case statusAlt = "Status"
    case status = "status"
    case audioStatus = "AudioStatus"
    case coverURL = "cover"
    case coverImageURL = "bookimg"
    case rating = "bookrate"
    case ratingCountLower = "bookrate_count"
    case ratingCountUpper = "BookRate"
    case publishedLower = "bookdate"
    case publishedUpper = "BookDate"
    case link = "booklink"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKeys: [.idLower, .idUpper, .idPlain])
    title = try container.decodeIfPresent(String.self, forKeys: [.titleLower, .titleUpper])
    author = try container.decodeIfPresent(String.self, forKeys: [.authorLower, .authorUpper])
    status =
      (try? container.decode(PodibleLibraryItemStatus.self, forKey: .status))
      ?? (try? container.decode(PodibleLibraryItemStatus.self, forKey: .statusAlt))
      ?? (try? container.decode(PodibleLibraryItemStatus.self, forKey: .audioStatus))
      ?? .unknown
    audioStatus = (try? container.decode(PodibleLibraryItemStatus.self, forKey: .audioStatus))
    coverURL = try? container.decodeIfPresent(URL.self, forKey: .coverURL)
    coverImageURL = try? container.decodeIfPresent(URL.self, forKey: .coverImageURL)
    rating = try? container.decodeIfPresent(Double.self, forKey: .rating)
    ratingCount =
      (try? container.decodeIfPresent(Int.self, forKey: .ratingCountLower))
      ?? (try? container.decodeIfPresent(Int.self, forKey: .ratingCountUpper))
    published =
      (try? container.decodeIfPresent(String.self, forKey: .publishedLower))
      ?? (try? container.decodeIfPresent(String.self, forKey: .publishedUpper))
    link = try? container.decodeIfPresent(URL.self, forKey: .link)
  }
}

struct PodibleLibraryItem: Identifiable, Hashable, Decodable {
  let id: String
  let title: String
  let author: String
  let status: PodibleLibraryItemStatus
  let audioStatus: PodibleLibraryItemStatus?
  let bookAdded: Date?
  let bookLibrary: Date?
  let audioLibrary: Date?
  let bookImagePath: String?

  init(
    id: String,
    title: String,
    author: String,
    status: PodibleLibraryItemStatus,
    audioStatus: PodibleLibraryItemStatus? = nil,
    bookAdded: Date? = nil,
    bookLibrary: Date? = nil,
    audioLibrary: Date? = nil,
    bookImagePath: String? = nil
  ) {
    self.id = id
    self.title = title
    self.author = author
    self.status = status
    self.audioStatus = audioStatus
    self.bookAdded = bookAdded
    self.bookLibrary = bookLibrary
    self.audioLibrary = audioLibrary
    self.bookImagePath = bookImagePath
  }

  private enum CodingKeys: String, CodingKey {
    case idLower = "bookid"
    case idUpper = "BookID"
    case idPlain = "id"
    case titleLower = "bookname"
    case titleUpper = "BookName"
    case authorLower = "authorname"
    case authorUpper = "AuthorName"
    case status = "status"
    case statusAlt = "Status"
    case audioStatus = "AudioStatus"
    case bookAdded = "BookAdded"
    case bookLibrary = "BookLibrary"
    case audioLibrary = "AudioLibrary"
    case bookImageUpper = "BookImg"
    case bookImageLower = "bookimg"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKeys: [.idLower, .idUpper, .idPlain])
    title = try container.decodeIfPresent(String.self, forKeys: [.titleLower, .titleUpper])
    author = try container.decodeIfPresent(String.self, forKeys: [.authorLower, .authorUpper])
    status =
      (try? container.decode(PodibleLibraryItemStatus.self, forKey: .status))
      ?? (try? container.decode(PodibleLibraryItemStatus.self, forKey: .statusAlt))
      ?? (try? container.decode(PodibleLibraryItemStatus.self, forKey: .audioStatus))
      ?? .unknown
    audioStatus = (try? container.decode(PodibleLibraryItemStatus.self, forKey: .audioStatus))
    bookImagePath = try? container.decodeIfPresent(
      String.self, forKeys: [.bookImageUpper, .bookImageLower])
    if let raw = try? container.decodeIfPresent(String.self, forKey: .bookLibrary) {
      bookLibrary = PodibleDateParser.parse(raw)
    } else {
      bookLibrary = nil
    }
    if let raw = try? container.decodeIfPresent(String.self, forKey: .audioLibrary) {
      audioLibrary = PodibleDateParser.parse(raw)
    } else {
      audioLibrary = nil
    }
    switch (bookLibrary, audioLibrary) {
    case let (b?, a?):
      bookAdded = min(b, a)
    case let (b?, nil):
      bookAdded = b
    case let (nil, a?):
      bookAdded = a
    case (nil, nil):
      if let raw = try? container.decodeIfPresent(String.self, forKey: .bookAdded) {
        if let parsed = PodibleDateParser.parse(raw) {
          bookAdded = PodibleDateParser.endOfDay(parsed)
        } else {
          bookAdded = nil
        }
      } else {
        bookAdded = nil
      }
    }
  }
}

private enum PodibleDateParser {
  private static let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
  }()

  private static let iso8601WithFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static func parse(_ string: String) -> Date? {
    if let date = iso8601WithFractional.date(from: string) { return date }
    if let date = iso8601.date(from: string) { return date }
    return nil
  }

  static func endOfDay(_ date: Date) -> Date {
    let start = utcCalendar.startOfDay(for: date)
    guard let nextDay = utcCalendar.date(byAdding: .day, value: 1, to: start),
      let end = utcCalendar.date(byAdding: .second, value: -1, to: nextDay)
    else {
      return date
    }
    return end
  }
}

extension KeyedDecodingContainer {
  fileprivate func decodeIfPresent(_ type: String.Type, forKeys keys: [Key]) throws -> String {
    for key in keys {
      if let value = try decodeIfPresent(type, forKey: key) {
        return value
      }
    }
    throw PodibleError.badResponse
  }
}

protocol PodibleLibraryServing {
  var supportsManualResultSelection: Bool { get }
  var supportsImportIssueReporting: Bool { get }
  func searchBooks(query: String) async throws -> [PodibleBook]
  func addLibraryBook(openLibraryKey: String, titleHint: String?, authorHint: String?) async throws
    -> PodibleLibraryItem
  func acquireLibraryMedia(bookID: String, library: PodibleLibraryMedia) async throws
  func fetchLibraryItems() async throws -> [PodibleLibraryItem]
  func reportImportIssue(bookID: String, library: PodibleLibraryMedia) async throws
  func searchItem(
    query: String,
    cat: PodibleSearchCategory?,
    bookID: String?
  ) async throws -> [PodibleSearchResult]
  func snatchResult(
    bookID: String,
    library: PodibleLibraryMedia,
    result: PodibleSearchResult
  ) async throws
  func fetchDownloadProgress(limit: Int?) async throws -> [PodibleDownloadProgressItem]
  func downloadEpub(bookID: String, progress: @escaping (Double) -> Void) async throws -> URL
  func downloadAudiobook(bookID: String, progress: @escaping (Double) -> Void) async throws -> URL
}

typealias RemoteLibraryServing = PodibleLibraryServing
extension PodibleLibraryServing {
  var supportsManualResultSelection: Bool { true }
  var supportsImportIssueReporting: Bool { false }

  func addLibraryBook(openLibraryKey: String, titleHint: String?, authorHint: String?) async throws
    -> PodibleLibraryItem
  {
    throw PodibleError.unsupported("This backend does not support adding library books.")
  }

  func acquireLibraryMedia(bookID: String, library: PodibleLibraryMedia) async throws {
    throw PodibleError.unsupported("This backend does not support media acquisition.")
  }

  func downloadEpub(bookID: String) async throws -> URL {
    try await downloadEpub(bookID: bookID, progress: { _ in })
  }

  func downloadAudiobook(bookID: String) async throws -> URL {
    try await downloadAudiobook(bookID: bookID, progress: { _ in })
  }

  func searchItem(query: String) async throws -> [PodibleSearchResult] {
    try await searchItem(query: query, cat: nil, bookID: nil)
  }

  func reportImportIssue(bookID: String, library: PodibleLibraryMedia) async throws {
    throw PodibleError.unsupported(
      "This backend does not support reporting wrong imported files.")
  }
}

enum PodibleLibraryMedia: String {
  case ebook = "eBook"
  case audio = "AudioBook"
}

enum PodibleSearchCategory: String {
  case general
  case book
  case audio
}

extension PodibleLibraryMedia {
  var searchCategory: PodibleSearchCategory {
    self == .ebook ? .book : .audio
  }
}

struct PodibleDownloadProgressItem: Hashable, Decodable {
  let bookID: String?
  let auxInfo: String?
  let source: String?
  let downloadID: String?
  let progress: Int?
  let finished: Bool?

  init(
    bookID: String?, auxInfo: String?, source: String?, downloadID: String?, progress: Int?,
    finished: Bool?
  ) {
    self.bookID = bookID
    self.auxInfo = auxInfo
    self.source = source
    self.downloadID = downloadID
    self.progress = progress
    self.finished = finished
  }

  private enum CodingKeys: String, CodingKey {
    case bookIDUpper = "BookID"
    case bookIDLower = "bookid"
    case auxInfo = "AuxInfo"
    case sourceUpper = "Source"
    case sourceLower = "source"
    case downloadIDUpper = "DownloadID"
    case downloadIDLower = "downloadid"
    case progress
    case finished
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    bookID =
      (try? container.decodeIfPresent(String.self, forKey: .bookIDUpper))
      ?? (try? container.decodeIfPresent(String.self, forKey: .bookIDLower))
    auxInfo = try? container.decodeIfPresent(String.self, forKey: .auxInfo)
    source =
      (try? container.decodeIfPresent(String.self, forKey: .sourceUpper))
      ?? (try? container.decodeIfPresent(String.self, forKey: .sourceLower))
    downloadID =
      (try? container.decodeIfPresent(String.self, forKey: .downloadIDUpper))
      ?? (try? container.decodeIfPresent(String.self, forKey: .downloadIDLower))
    progress = try? container.decodeIfPresent(Int.self, forKey: .progress)
    finished = try? container.decodeIfPresent(Bool.self, forKey: .finished)
  }
}

struct PodibleSearchResult: Identifiable, Hashable {
  let id: String
  let title: String
  let provider: String
  let url: String
  let sizeRaw: String?
  let sizeBytes: Int64?
  let seeders: Int?
  let leechers: Int?
  let age: String?
  let mode: String
  let library: PodibleLibraryMedia?

  var canSnatch: Bool {
    title.isEmpty == false && provider.isEmpty == false && url.isEmpty == false
      && mode.isEmpty == false
  }

  var snatchURL: String {
    let plusFixed = url.replacingOccurrences(of: "+", with: " ")
    return plusFixed.removingPercentEncoding ?? url
  }

  var sizeParameter: String? {
    sizeRaw ?? sizeBytes.map(String.init)
  }

  var displaySize: String? {
    if let sizeRaw,
      let parsed = PodibleSearchResult.parseSizeBytes(from: sizeRaw)
    {
      return ByteCountFormatter.string(fromByteCount: parsed, countStyle: .file)
    }
    return sizeRaw
  }

  init?(
    dictionary: [String: Any]
  ) {
    let title =
      PodibleSearchResult.stringValue(
        dictionary,
        keys: [
          "title", "Title", "name", "Name", "bookname", "BookName", "filename", "Filename",
          "release", "Release",
        ]) ?? ""
    let provider =
      PodibleSearchResult.stringValue(
        dictionary,
        keys: [
          "provider", "Provider", "source", "Source", "indexer", "Indexer",
        ]) ?? ""
    let url =
      PodibleSearchResult.stringValue(
        dictionary,
        keys: [
          "url", "URL", "link", "Link", "download", "Download", "torrent", "Torrent", "magnet",
          "Magnet",
        ]) ?? ""
    let mode =
      PodibleSearchResult.stringValue(
        dictionary,
        keys: [
          "mode", "Mode", "downloadType", "DownloadType", "type", "Type",
        ]) ?? ""
    let sizeRaw =
      PodibleSearchResult.stringValue(
        dictionary,
        keys: [
          "size", "Size", "filesize", "FileSize",
        ])
    let seeders = PodibleSearchResult.intValue(
      dictionary,
      keys: [
        "seeders", "Seeders", "seeds", "Seeds",
      ])
    let leechers = PodibleSearchResult.intValue(
      dictionary,
      keys: [
        "leechers", "Leechers", "leeches", "Leeches",
      ])
    let age = PodibleSearchResult.stringValue(
      dictionary,
      keys: [
        "age", "Age", "published", "Published", "date", "Date",
      ])
    let library = PodibleSearchResult.parseLibrary(
      from: PodibleSearchResult.stringValue(
        dictionary,
        keys: [
          "library", "Library", "kind", "Kind", "booktype", "BookType", "media", "Media", "type",
          "Type",
        ]))

    if title.isEmpty && url.isEmpty {
      return nil
    }

    let idSeed = [title, provider, url, mode]
      .filter { $0.isEmpty == false }
      .joined(separator: "|")
    let id = idSeed.isEmpty ? UUID().uuidString : idSeed

    self.id = id
    self.title = title
    self.provider = provider
    self.url = url
    self.sizeRaw = sizeRaw
    self.sizeBytes = PodibleSearchResult.parseSizeBytes(from: sizeRaw)
    self.seeders = seeders
    self.leechers = leechers
    self.age = age
    self.mode = mode
    self.library = library
  }

  private static func stringValue(_ dict: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = dict[key] {
        if let string = value as? String {
          let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
          if trimmed.isEmpty == false { return trimmed }
        } else if let number = value as? NSNumber {
          return number.stringValue
        }
      }
    }
    return nil
  }

  private static func intValue(_ dict: [String: Any], keys: [String]) -> Int? {
    for key in keys {
      if let value = dict[key] {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let int = Int(string) { return int }
      }
    }
    return nil
  }

  private static func parseLibrary(from raw: String?) -> PodibleLibraryMedia? {
    guard let raw else { return nil }
    let lowered = raw.lowercased()
    if lowered.contains("audio") {
      return .audio
    }
    if lowered.contains("ebook") || lowered.contains("e-book") {
      return .ebook
    }
    return nil
  }

  private static func parseSizeBytes(from raw: String?) -> Int64? {
    guard let raw else { return nil }
    let lowered = raw.lowercased()
    let scanner = Scanner(string: lowered)
    scanner.charactersToBeSkipped = .whitespacesAndNewlines
    guard let value = scanner.scanDouble() else { return nil }
    let unit = scanner.scanCharacters(from: .letters) ?? ""
    let multiplier: Double
    if unit.contains("tb") {
      multiplier = 1024 * 1024 * 1024 * 1024
    } else if unit.contains("gb") {
      multiplier = 1024 * 1024 * 1024
    } else if unit.contains("mb") {
      multiplier = 1024 * 1024
    } else if unit.contains("kb") {
      multiplier = 1024
    } else {
      multiplier = 1
    }
    return Int64(value * multiplier)
  }
}

// Preview/testing helper that simulates the podible backend without network calls.
final actor PodibleMockClient: PodibleLibraryServing {
  private var libraryItems: [PodibleLibraryItem] = [
    PodibleLibraryItem(
      id: "1", title: "Project Hail Mary", author: "Andy Weir", status: .downloaded,
      bookAdded: Date().addingTimeInterval(-86_400 * 3)),
    PodibleLibraryItem(
      id: "2", title: "The City We Became", author: "N. K. Jemisin", status: .requested,
      bookAdded: Date().addingTimeInterval(-86_400 * 12)),
  ]
  private var progress: [String: (ebook: Int, audio: Int)] = [:]

  func searchBooks(query: String) async throws -> [PodibleBook] {
    let canned = [
      PodibleBook(
        id: "1", title: "Project Hail Mary", author: "Andy Weir", status: .downloaded),
      PodibleBook(
        id: "2", title: "The City We Became", author: "N. K. Jemisin", status: .requested),
      PodibleBook(
        id: "3", title: "The House in the Cerulean Sea", author: "T. J. Klune", status: .wanted),
    ]
    if query.isEmpty { return canned }
    return canned.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || $0.author.localizedCaseInsensitiveContains(query)
    }
  }

  func addLibraryBook(
    openLibraryKey: String,
    titleHint: String? = nil,
    authorHint: String? = nil
  ) async throws
    -> PodibleLibraryItem
  {
    if let existing = libraryItems.first(where: { $0.id == openLibraryKey }) {
      return existing
    }
    let new = PodibleLibraryItem(
      id: openLibraryKey,
      title: titleHint ?? "Requested \(openLibraryKey)",
      author: authorHint ?? "Unknown",
      status: .requested
    )
    libraryItems.append(new)
    progress[openLibraryKey] = (ebook: 0, audio: 0)
    return new
  }

  func fetchLibraryItems() async throws -> [PodibleLibraryItem] {
    return libraryItems
  }

  func acquireLibraryMedia(bookID: String, library: PodibleLibraryMedia) async throws {
    // no-op for mock
  }

  func searchItem(
    query: String,
    cat: PodibleSearchCategory?,
    bookID: String?
  ) async throws -> [PodibleSearchResult] {
    let results = [
      PodibleSearchResult(
        dictionary: [
          "title": "\(query) (Mock eBook)",
          "provider": "MockProvider",
          "url": "https://example.com/mock-ebook",
          "size": "12.4 MB",
          "mode": "torznab",
          "seeders": 42,
          "leechers": 3,
          "age": "1d",
          "library": "eBook",
        ]
      )!,
      PodibleSearchResult(
        dictionary: [
          "title": "\(query) (Mock Audio)",
          "provider": "MockProvider",
          "url": "https://example.com/mock-audio",
          "size": "420 MB",
          "mode": "torznab",
          "seeders": 12,
          "leechers": 1,
          "age": "2d",
          "library": "AudioBook",
        ]
      )!,
    ]
    guard let cat else { return results }
    switch cat {
    case .book:
      return results.filter { $0.library == .ebook }
    case .audio:
      return results.filter { $0.library == .audio }
    case .general:
      return results
    }
  }

  func snatchResult(
    bookID: String,
    library: PodibleLibraryMedia,
    result: PodibleSearchResult
  ) async throws {
    if let index = libraryItems.firstIndex(where: { $0.id == bookID }) {
      let existing = libraryItems[index]
      let updated = PodibleLibraryItem(
        id: existing.id,
        title: existing.title,
        author: existing.author,
        status: library == .ebook ? .snatched : existing.status,
        audioStatus: library == .audio ? .snatched : existing.audioStatus,
        bookAdded: existing.bookAdded,
        bookLibrary: existing.bookLibrary,
        audioLibrary: existing.audioLibrary,
        bookImagePath: existing.bookImagePath
      )
      libraryItems[index] = updated
    }
  }

  func fetchDownloadProgress(limit: Int? = nil) async throws -> [PodibleDownloadProgressItem] {
    var items: [PodibleDownloadProgressItem] = []
    for (bookID, p) in progress {
      let ebook = min(100, p.ebook + 7)
      let audio = min(100, p.audio + 5)
      progress[bookID] = (ebook: ebook, audio: audio)

      items.append(
        PodibleDownloadProgressItem(
          bookID: bookID,
          auxInfo: "eBook",
          source: "SABNZBD",
          downloadID: "mock-\(bookID)-ebook",
          progress: ebook,
          finished: ebook >= 100
        )
      )
      items.append(
        PodibleDownloadProgressItem(
          bookID: bookID,
          auxInfo: "AudioBook",
          source: "SABNZBD",
          downloadID: "mock-\(bookID)-audio",
          progress: audio,
          finished: audio >= 100
        )
      )
    }
    return items
  }

  func downloadEpub(bookID: String, progress: @escaping (Double) -> Void) async throws -> URL {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("lazy-librarian", isDirectory: true)
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent("\(bookID)-mock").appendingPathExtension("epub")
    let data = Data("mock-ebook-\(bookID)".utf8)
    try data.write(to: destination, options: .atomic)
    progress(1.0)
    return destination
  }

  func downloadAudiobook(
    bookID: String,
    progress: @escaping (Double) -> Void
  ) async throws -> URL {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("lazy-librarian", isDirectory: true)
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent("\(bookID)-mock").appendingPathExtension("m4b")
    let data = Data("mock-audio-\(bookID)".utf8)
    try data.write(to: destination, options: .atomic)
    progress(1.0)
    return destination
  }
}

private struct PodibleRPCEnvelope<Result: Decodable>: Decodable {
  struct RPCError: Decodable {
    let code: Int
    let message: String
  }

  let result: Result?
  let error: RPCError?
}

private struct PodibleEmptyResult: Decodable {}

private struct PodibleLibraryListResult: Decodable {
  let items: [PodibleLibraryBook]
  let nextCursor: Int?
}

private struct PodibleLibraryCreateResult: Decodable {
  let book: PodibleLibraryBook?
}

private struct PodibleOpenLibrarySearchResult: Decodable {
  let results: [PodibleOpenLibraryCandidate]
}

private struct PodibleOpenLibraryCandidate: Decodable {
  let openLibraryKey: String
  let title: String
  let author: String
  let publishedAt: String?
  let coverId: Int?
}

private struct PodibleLibraryBook: Decodable {
  let id: Int
  let title: String
  let author: String
  let coverUrl: String?
  let addedAt: String
  let updatedAt: String
  let publishedAt: String?
  let audioStatus: String
  let ebookStatus: String
  let status: String
}

private struct PodibleSearchRunResult: Decodable {
  let results: [PodibleTorznabResult]
}

private struct PodibleTorznabResult: Decodable {
  let title: String
  let provider: String
  let mediaType: String
  let sizeBytes: Int64?
  let url: String
  let guid: String?
  let infoHash: String?
  let seeders: Int?
  let leechers: Int?
}

private struct PodibleDownloadsListResult: Decodable {
  let downloads: [PodibleDownload]
}

private struct PodibleDownloadProgress: Decodable {
  let percent: Int?
}

private struct PodibleDownload: Decodable {
  let jobId: Int
  let releaseStatus: String?
  let mediaType: String?
  let infoHash: String?
  let bookId: Int?
  let fullPseudoProgress: Double?
  let downloadProgress: PodibleDownloadProgress?
}

private struct PodibleAssetsResult: Decodable {
  let assets: [PodibleAsset]
}

private struct PodibleAsset: Decodable {
  let id: Int
  let kind: String
  let mime: String
  let files: [PodibleAssetFile]
  let streamExt: String
}

private struct PodibleAssetFile: Decodable {
  let path: String
}

struct PodibleClient: PodibleLibraryServing {
  let rpcURL: URL
  let apiKey: String
  var session: URLSession = .shared

  var supportsImportIssueReporting: Bool { true }

  func searchBooks(query: String) async throws -> [PodibleBook] {
    let response: PodibleOpenLibrarySearchResult = try await rpcCall(
      method: "openlibrary.search",
      params: ["q": query, "limit": 50]
    )
    return response.results.map { candidate in
      PodibleBook(
        id: candidate.openLibraryKey,
        title: candidate.title,
        author: candidate.author,
        status: .unknown,
        coverImageURL: podibleOpenLibraryCoverURL(coverID: candidate.coverId),
        published: candidate.publishedAt
      )
    }
  }

  func addLibraryBook(
    openLibraryKey: String,
    titleHint: String? = nil,
    authorHint: String? = nil
  ) async throws
    -> PodibleLibraryItem
  {
    _ = titleHint
    _ = authorHint
    let response: PodibleLibraryCreateResult = try await rpcCall(
      method: "library.create",
      params: ["openLibraryKey": openLibraryKey]
    )
    guard let book = response.book else {
      throw PodibleError.badResponse
    }
    return toLibraryItem(book)
  }

  func fetchLibraryItems() async throws -> [PodibleLibraryItem] {
    var cursor: Int?
    var collected: [PodibleLibraryBook] = []

    while true {
      var params: [String: Any] = ["limit": 200]
      if let cursor {
        params["cursor"] = cursor
      }
      let page: PodibleLibraryListResult = try await rpcCall(method: "library.list", params: params)
      collected.append(contentsOf: page.items)
      guard let next = page.nextCursor else { break }
      cursor = next
    }

    return collected.map(toLibraryItem(_:))
  }

  func acquireLibraryMedia(bookID: String, library: PodibleLibraryMedia) async throws {
    let numericBookID = try parseBookID(bookID)
    _ =
      try await rpcCall(
        method: "library.acquire",
        params: ["bookId": numericBookID, "media": podibleMediaValue(for: library)]
      ) as PodibleEmptyResult
  }

  func reportImportIssue(bookID: String, library: PodibleLibraryMedia) async throws {
    let numericBookID = try parseBookID(bookID)
    _ =
      try await rpcCall(
        method: "library.reportImportIssue",
        params: [
          "bookId": numericBookID,
          "mediaType": podibleMediaValue(for: library),
        ]
      ) as PodibleEmptyResult
  }

  func searchItem(
    query: String,
    cat: PodibleSearchCategory?,
    bookID: String?
  ) async throws -> [PodibleSearchResult] {
    _ = bookID
    let libraries: [PodibleLibraryMedia]
    switch cat {
    case .book:
      libraries = [.ebook]
    case .audio:
      libraries = [.audio]
    case .general, .none:
      libraries = [.audio, .ebook]
    }

    var results: [PodibleSearchResult] = []
    for library in libraries {
      let response: PodibleSearchRunResult = try await rpcCall(
        method: "search.run",
        params: [
          "query": query,
          "media": podibleMediaValue(for: library),
        ]
      )
      results.append(
        contentsOf: response.results.compactMap { toSearchResult($0, library: library) })
    }
    return results
  }

  func snatchResult(
    bookID: String,
    library: PodibleLibraryMedia,
    result: PodibleSearchResult
  ) async throws {
    let numericBookID = try parseBookID(bookID)
    var params: [String: Any] = [
      "bookId": numericBookID,
      "provider": result.provider,
      "title": result.title,
      "mediaType": podibleMediaValue(for: library),
      "url": result.snatchURL,
    ]
    if let sizeBytes = result.sizeBytes {
      params["sizeBytes"] = sizeBytes
    }
    _ = try await rpcCall(method: "snatch.create", params: params) as PodibleEmptyResult
  }

  func fetchDownloadProgress(limit: Int? = nil) async throws -> [PodibleDownloadProgressItem] {
    let response: PodibleDownloadsListResult = try await rpcCall(
      method: "downloads.list",
      params: [:]
    )
    var mapped: [PodibleDownloadProgressItem] = []
    for download in response.downloads {
      guard let bookID = download.bookId else { continue }
      guard let mediaType = download.mediaType else { continue }
      let auxInfo: String
      switch mediaType {
      case "audio":
        auxInfo = PodibleLibraryMedia.audio.rawValue
      case "ebook":
        auxInfo = PodibleLibraryMedia.ebook.rawValue
      default:
        continue
      }
      let percent =
        download.downloadProgress?.percent
        ?? download.fullPseudoProgress.map { Int($0.rounded()) }
        ?? 0
      let finished =
        download.releaseStatus == "downloaded"
        || download.releaseStatus == "imported"
        || percent >= 100
      mapped.append(
        PodibleDownloadProgressItem(
          bookID: String(bookID),
          auxInfo: auxInfo,
          source: "podible",
          downloadID: download.infoHash ?? "job-\(download.jobId)",
          progress: max(0, min(100, percent)),
          finished: finished
        )
      )
    }
    if let limit {
      return Array(mapped.prefix(limit))
    }
    return mapped
  }

  func downloadEpub(bookID: String, progress: @escaping (Double) -> Void) async throws -> URL {
    let numericBookID = try parseBookID(bookID)
    let assets = try await fetchAssets(bookID: numericBookID)
    guard let asset = assets.first(where: { $0.kind == "ebook" }) else {
      throw PodibleError.server("No ebook asset available.")
    }
    let fallbackFilename: String = {
      if let path = asset.files.first?.path, path.isEmpty == false {
        return URL(fileURLWithPath: path).lastPathComponent
      }
      return "\(bookID)-ebook-\(asset.id).\(fileExtensionForEbookMime(asset.mime) ?? "epub")"
    }()
    let url = try authorizedWebURL(path: "/ebook/\(asset.id)")
    return try await downloadHTTPFile(
      url: url, fallbackFilename: fallbackFilename, progress: progress)
  }

  func downloadAudiobook(
    bookID: String,
    progress: @escaping (Double) -> Void
  ) async throws -> URL {
    let numericBookID = try parseBookID(bookID)
    let assets = try await fetchAssets(bookID: numericBookID)
    guard let asset = preferredAudioAsset(from: assets) else {
      throw PodibleError.server("No audiobook asset available.")
    }
    let ext = asset.streamExt.isEmpty ? "mp3" : asset.streamExt
    let fallbackFilename = "\(bookID)-audio-\(asset.id).\(ext)"
    let url = try authorizedWebURL(path: "/stream/\(asset.id).\(ext)")
    return try await downloadHTTPFile(
      url: url, fallbackFilename: fallbackFilename, progress: progress)
  }

  private func toSearchResult(
    _ result: PodibleTorznabResult,
    library: PodibleLibraryMedia
  ) -> PodibleSearchResult? {
    var dict: [String: Any] = [
      "title": result.title,
      "provider": result.provider,
      "url": result.url,
      "mode": "torznab",
      "library": library.rawValue,
    ]
    if let sizeBytes = result.sizeBytes {
      dict["size"] = String(sizeBytes)
    }
    if let seeders = result.seeders {
      dict["seeders"] = seeders
    }
    if let leechers = result.leechers {
      dict["leechers"] = leechers
    }
    return PodibleSearchResult(dictionary: dict)
  }

  private func preferredAudioAsset(from assets: [PodibleAsset]) -> PodibleAsset? {
    if let single = assets.first(where: { $0.kind == "single" }) { return single }
    if let multi = assets.first(where: { $0.kind == "multi" }) { return multi }
    return nil
  }

  private func fetchAssets(bookID: Int) async throws -> [PodibleAsset] {
    let url = try authorizedWebURL(
      path: "/assets",
      queryItems: [URLQueryItem(name: "bookId", value: String(bookID))]
    )
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw PodibleError.server("Failed to fetch backend assets.")
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(PodibleAssetsResult.self, from: data).assets
  }

  private func parseBookID(_ raw: String) throws -> Int {
    guard let value = Int(raw), value > 0 else {
      throw PodibleError.badResponse
    }
    return value
  }

  private func toLibraryItem(_ book: PodibleLibraryBook) -> PodibleLibraryItem {
    let ebookStatus = mapPodibleStatus(book.ebookStatus)
    let audioStatus = mapPodibleStatus(book.audioStatus)
    let addedAt = PodibleDateParser.parse(book.addedAt)
    let updatedAt = PodibleDateParser.parse(book.updatedAt)
    return PodibleLibraryItem(
      id: String(book.id),
      title: book.title,
      author: book.author,
      status: mapPodibleStatus(book.status),
      audioStatus: audioStatus,
      bookAdded: addedAt,
      bookLibrary: ebookStatus.isComplete ? updatedAt : nil,
      audioLibrary: audioStatus.isComplete ? updatedAt : nil,
      bookImagePath: absoluteAssetURLString(from: book.coverUrl)
    )
  }

  private func mapPodibleStatus(_ raw: String) -> PodibleLibraryItemStatus {
    switch raw.lowercased() {
    case "wanted":
      return .wanted
    case "snatched":
      return .snatched
    case "downloading":
      return .snatched
    case "downloaded":
      return .downloaded
    case "imported":
      return .have
    case "error":
      return .failed
    case "partial":
      return .open
    default:
      return .unknown
    }
  }

  private func podibleMediaValue(for library: PodibleLibraryMedia) -> String {
    library == .audio ? "audio" : "ebook"
  }

  private func podibleOpenLibraryCoverURL(coverID: Int?) -> URL? {
    guard let coverID, coverID > 0 else { return nil }
    return URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg")
  }

  private func absoluteAssetURLString(from path: String?) -> String? {
    guard let path, path.isEmpty == false else { return nil }
    if let absolute = URL(string: path), absolute.scheme != nil {
      return absolute.absoluteString
    }
    return (try? authorizedWebURL(path: path))?.absoluteString
  }

  private func fileExtensionForEbookMime(_ mime: String) -> String? {
    let lowered = mime.lowercased()
    if lowered.contains("epub") { return "epub" }
    if lowered.contains("pdf") { return "pdf" }
    if lowered.contains("mobi") { return "mobi" }
    return nil
  }

  private func normalizedRPCURL() -> URL {
    let trimmed = rpcURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var url = URL(string: trimmed), trimmed.isEmpty == false else { return rpcURL }
    if url.path.isEmpty || url.path == "/" {
      url.appendPathComponent("rpc")
      return url
    }
    if url.path.hasSuffix("/rpc") {
      return url
    }
    url.appendPathComponent("rpc")
    return url
  }

  private func baseWebURL() -> URL {
    var url = normalizedRPCURL()
    if url.path.hasSuffix("/rpc") {
      url.deleteLastPathComponent()
    }
    return url
  }

  private func authorizedRPCURL() throws -> URL {
    guard var components = URLComponents(url: normalizedRPCURL(), resolvingAgainstBaseURL: false)
    else {
      throw PodibleError.badURL
    }
    var items = components.queryItems ?? []
    items.append(URLQueryItem(name: "api_key", value: apiKey))
    components.queryItems = items
    guard let url = components.url else {
      throw PodibleError.badURL
    }
    return url
  }

  private func authorizedWebURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
    guard let base = URL(string: "/", relativeTo: baseWebURL())?.absoluteURL else {
      throw PodibleError.badURL
    }
    guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
      throw PodibleError.badURL
    }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw PodibleError.badURL
    }
    var items = components.queryItems ?? []
    items.append(URLQueryItem(name: "api_key", value: apiKey))
    items.append(contentsOf: queryItems)
    components.queryItems = items
    guard let final = components.url else {
      throw PodibleError.badURL
    }
    return final
  }

  private func rpcCall<Result: Decodable>(method: String, params: [String: Any]) async throws
    -> Result
  {
    var request = URLRequest(url: try authorizedRPCURL())
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": 1,
      "method": method,
      "params": params,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw PodibleError.server("Backend returned an error for \(method).")
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let envelope = try decoder.decode(PodibleRPCEnvelope<Result>.self, from: data)
    if let error = envelope.error {
      throw PodibleError.server(error.message)
    }
    guard let result = envelope.result else {
      throw PodibleError.badResponse
    }
    return result
  }

  private func contentDispositionFilename(from response: HTTPURLResponse) -> String? {
    let raw =
      response.allHeaderFields.first { key, _ in
        (key as? String)?.lowercased() == "content-disposition"
      }?.value as? String
    guard let value = raw else { return nil }
    let parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    if let filenameStar = parts.first(where: { $0.lowercased().hasPrefix("filename*=") }) {
      let rawValue = filenameStar.dropFirst("filename*=".count).replacingOccurrences(
        of: "\"", with: "")
      if let range = rawValue.range(of: "''") {
        let encoded = String(rawValue[range.upperBound...])
        return encoded.removingPercentEncoding ?? encoded
      }
      return rawValue
    }
    if let filename = parts.first(where: { $0.lowercased().hasPrefix("filename=") }) {
      return filename.dropFirst("filename=".count).replacingOccurrences(of: "\"", with: "")
    }
    return nil
  }

  private func downloadHTTPFile(
    url: URL,
    fallbackFilename: String,
    progress: @escaping (Double) -> Void
  ) async throws -> URL {
    let (tempURL, response) = try await downloadFile(url: url, progress: progress)
    let filename = contentDispositionFilename(from: response) ?? fallbackFilename
    return try moveDownloadedFile(from: tempURL, filename: filename)
  }

  private func moveDownloadedFile(from tempURL: URL, filename: String) throws -> URL {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("podible-backend", isDirectory: true)
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let safeName =
      filename
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    let destinationName = safeName.isEmpty ? UUID().uuidString : safeName
    let destination = folder.appendingPathComponent(destinationName)
    try? fm.removeItem(at: destination)
    try fm.moveItem(at: tempURL, to: destination)
    return destination
  }

  private func downloadFile(
    url: URL,
    progress: @escaping (Double) -> Void
  ) async throws -> (URL, HTTPURLResponse) {
    final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
      var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
      var progressHandler: ((Double) -> Void)?
      private var tempURL: URL?
      private var moveError: Error?
      private var didFinish = false

      func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
      ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler?(min(1, max(0, fraction)))
      }

      func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
      ) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(
          "podible-backend", isDirectory: true)
        do {
          try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
          let destination = folder.appendingPathComponent(UUID().uuidString)
          try? fm.removeItem(at: destination)
          try fm.moveItem(at: location, to: destination)
          tempURL = destination
        } catch {
          moveError = error
        }
      }

      func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
      ) {
        guard didFinish == false else { return }
        didFinish = true
        session.finishTasksAndInvalidate()
        if let error {
          continuation?.resume(throwing: error)
          return
        }
        if let moveError {
          continuation?.resume(throwing: moveError)
          return
        }
        guard let tempURL, let http = task.response as? HTTPURLResponse else {
          continuation?.resume(throwing: PodibleError.badResponse)
          return
        }
        continuation?.resume(returning: (tempURL, http))
      }
    }

    return try await withCheckedThrowingContinuation { continuation in
      let delegate = DownloadDelegate()
      delegate.continuation = continuation
      delegate.progressHandler = progress
      let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
      let task = session.downloadTask(with: url)
      task.resume()
    }
  }
}
