import Foundation
import SwiftData

@MainActor
struct LocalLibraryResetService {
  func wipeLocalLibrary(modelContext: ModelContext, fileManager: FileManager = .default) throws {
    try removeLocalLibraryFiles(fileManager: fileManager)
    try deleteLocalLibraryRows(modelContext: modelContext)
    try modelContext.save()
  }

  private func deleteLocalLibraryRows(modelContext: ModelContext) throws {
    try deleteAll(LibrarySyncState.self, modelContext: modelContext)
    try deleteAll(LibraryBook.self, modelContext: modelContext)
    try deleteAll(LibraryBookFile.self, modelContext: modelContext)
    try deleteAll(LocalBookState.self, modelContext: modelContext)
    try deleteAll(Series.self, modelContext: modelContext)
    try deleteAll(Author.self, modelContext: modelContext)
  }

  private func deleteAll<T: PersistentModel>(_ type: T.Type, modelContext: ModelContext) throws {
    let rows = try modelContext.fetch(FetchDescriptor<T>())
    for row in rows {
      modelContext.delete(row)
    }
  }

  private func removeLocalLibraryFiles(fileManager: FileManager) throws {
    for url in localLibraryWipeTargets(fileManager: fileManager) {
      if fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
      }
    }
  }

  private func localLibraryWipeTargets(fileManager: FileManager) -> [URL] {
    var urls: [URL] = []
    if let appSupport = try? fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: false
    ) {
      urls.append(appSupport.appendingPathComponent("KindlingLibrary", isDirectory: true))
    }
    let temp = fileManager.temporaryDirectory
    urls.append(temp.appendingPathComponent("lazy-librarian", isDirectory: true))
    urls.append(temp.appendingPathComponent("podible-backend", isDirectory: true))
    return urls
  }
}
