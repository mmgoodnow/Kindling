import Foundation

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
    let baseURL = try ensureBaseDirectory()
    let bookFolder = try ensureBookDirectory(baseURL: baseURL, book: book)
    let filename = sanitizeFilename(suggestedFilename)
    let destination = uniqueDestinationURL(in: bookFolder, filename: filename)

    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.moveItem(at: tempURL, to: destination)

    let relativePath = makeRelativePath(destination, baseURL: baseURL)
    let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
    let fileSize = attributes?[.size] as? Int64
    return StoredFile(
      filename: destination.lastPathComponent, relativePath: relativePath, fileSizeBytes: fileSize)
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
    let folderName = sanitizeFilename(book.llId)
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

  private func uniqueDestinationURL(in folder: URL, filename: String) -> URL {
    let base = folder.appendingPathComponent(filename)
    if fileManager.fileExists(atPath: base.path) == false {
      return base
    }
    let stem = base.deletingPathExtension().lastPathComponent
    let ext = base.pathExtension
    let suffix = UUID().uuidString.prefix(8)
    let uniqueName = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
    return folder.appendingPathComponent(uniqueName)
  }

  private func makeRelativePath(_ fileURL: URL, baseURL: URL) -> String {
    let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
    return fileURL.path.replacingOccurrences(of: basePath, with: "")
  }
}
