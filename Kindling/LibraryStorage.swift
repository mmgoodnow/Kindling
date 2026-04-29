import Foundation
import SwiftData

struct LibraryStorage {
  struct StoredFile {
    let filename: String
    let relativePath: String
    let fileSizeBytes: Int64?
  }

  private let fileManager = FileManager.default
  private let baseFolderName = "KindlingLibrary"

  func storeDownloadedFile(_ tempURL: URL, for book: LibraryBook, suggestedFilename: String)
    throws -> StoredFile
  {
    try storeFile(tempURL, for: book, suggestedFilename: suggestedFilename, shouldMove: true)
  }

  func storeCopiedFile(_ sourceURL: URL, for book: LibraryBook, suggestedFilename: String)
    throws -> StoredFile
  {
    try storeFile(sourceURL, for: book, suggestedFilename: suggestedFilename, shouldMove: false)
  }

  private func storeFile(
    _ sourceURL: URL,
    for book: LibraryBook,
    suggestedFilename: String,
    shouldMove: Bool
  ) throws -> StoredFile {
    let baseURL = try ensureBaseDirectory()
    let bookFolder = try ensureBookDirectory(baseURL: baseURL, book: book)
    let filename = sanitizeFilename(suggestedFilename)
    try removeExistingFiles(in: bookFolder)
    let destination = bookFolder.appendingPathComponent(filename, isDirectory: false)

    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    if shouldMove {
      try fileManager.moveItem(at: sourceURL, to: destination)
    } else {
      try fileManager.copyItem(at: sourceURL, to: destination)
    }

    let relativePath = makeRelativePath(destination, baseURL: baseURL)
    let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
    let fileSize = attributes?[.size] as? Int64
    return StoredFile(
      filename: destination.lastPathComponent, relativePath: relativePath, fileSizeBytes: fileSize)
  }

  func url(forRelativePath relativePath: String) throws -> URL {
    let baseURL = try ensureBaseDirectory()
    return baseURL.appendingPathComponent(relativePath, isDirectory: false)
  }

  func relativePath(forFileURL fileURL: URL) throws -> String {
    let baseURL = try ensureBaseDirectory()
    return makeRelativePath(fileURL, baseURL: baseURL)
  }

  private func ensureBaseDirectory() throws -> URL {
    let base = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let target = base.appendingPathComponent(baseFolderName, isDirectory: true)
    if fileManager.fileExists(atPath: target.path) == false {
      try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
    }
    return target
  }

  private func ensureBookDirectory(baseURL: URL, book: LibraryBook) throws -> URL {
    let folderName = sanitizeFilename(storageDirectoryName(for: book))
    let target = baseURL.appendingPathComponent(folderName, isDirectory: true)
    if fileManager.fileExists(atPath: target.path) == false {
      try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
    }
    return target
  }

  private func sanitizeFilename(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let replaced =
      trimmed
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    return replaced.isEmpty ? UUID().uuidString : replaced
  }

  private func storageDirectoryName(for book: LibraryBook) -> String {
    if let openLibraryWorkID = book.openLibraryWorkID, openLibraryWorkID.isEmpty == false {
      return openLibraryWorkID
    }
    return book.podibleId
  }

  private func removeExistingFiles(in folder: URL) throws {
    guard fileManager.fileExists(atPath: folder.path) else { return }
    let contents = try fileManager.contentsOfDirectory(
      at: folder,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    for url in contents {
      try fileManager.removeItem(at: url)
    }
  }

  private func makeRelativePath(_ fileURL: URL, baseURL: URL) -> String {
    let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
    return fileURL.path.replacingOccurrences(of: basePath, with: "")
  }
}

@MainActor
struct LocalAudiobookCache {
  static let maxDownloadedBooks = 3

  private let fileManager = FileManager.default

  func enforceLimit(modelContext: ModelContext, keeping protectedBookID: String) throws {
    let books = try modelContext.fetch(
      FetchDescriptor<LibraryBook>(
        sortBy: [SortDescriptor(\LibraryBook.addedAt, order: .forward)]
      ))

    let cachedBooks =
      books
      .filter(hasCachedAudiobook)
      .sorted { cacheSortDate(for: $0) < cacheSortDate(for: $1) }

    let overflowCount = cachedBooks.count - Self.maxDownloadedBooks
    guard overflowCount > 0 else { return }

    let evictionCandidates = cachedBooks.filter { $0.podibleId != protectedBookID }
    guard evictionCandidates.isEmpty == false else { return }

    for book in evictionCandidates.prefix(overflowCount) {
      evict(book)
    }

    if modelContext.hasChanges {
      try modelContext.save()
    }
  }

  private func hasCachedAudiobook(_ book: LibraryBook) -> Bool {
    if book.localState?.isDownloaded == true {
      return true
    }
    return book.files.contains { file in
      file.localRelativePath?.isEmpty == false && file.downloadStatus == .completed
    }
  }

  private func cacheSortDate(for book: LibraryBook) -> Date {
    book.localState?.lastPlayedAt ?? book.addedAt ?? .distantPast
  }

  private func evict(_ book: LibraryBook) {
    let localFileURLs: [URL] = book.files.compactMap { file in
      guard let relativePath = file.localRelativePath else { return nil }
      return try? LibraryStorage().url(forRelativePath: relativePath)
    }

    for url in localFileURLs where fileManager.fileExists(atPath: url.path) {
      try? fileManager.removeItem(at: url)
    }

    let parentFolders = Set(localFileURLs.map { $0.deletingLastPathComponent() })
    for folder in parentFolders {
      guard fileManager.fileExists(atPath: folder.path) else { continue }
      let contents =
        (try? fileManager.contentsOfDirectory(
          at: folder,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )) ?? []
      if contents.isEmpty {
        try? fileManager.removeItem(at: folder)
      }
    }

    for file in book.files {
      file.localRelativePath = nil
      file.downloadStatus = .notStarted
      file.bytesDownloaded = 0
      file.lastError = nil
      file.format = .unknown
    }

    if let localState = book.localState {
      localState.isDownloaded = false
    }
  }
}
