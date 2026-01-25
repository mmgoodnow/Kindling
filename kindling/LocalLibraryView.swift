import SwiftData
import SwiftUI

struct LocalLibraryView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(
    sort: [
      SortDescriptor(\LibraryBook.addedAt, order: .reverse),
      SortDescriptor(\LibraryBook.title, order: .forward),
    ]
  )
  private var books: [LibraryBook]

  let client: LazyLibrarianServing

  @State private var isSyncing = false
  @State private var errorMessage: String?
  @State private var lastSync: Date?
  @State private var lastSummary: LibrarySyncService.Summary?
  @State private var downloadProgressByBookID: [String: Double] = [:]
  @State private var downloadingBookIDs: Set<String> = []

  var body: some View {
    List {
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.caption)
      }

      if let lastSync {
        HStack(spacing: 8) {
          Text("Last sync")
          Text(lastSync, style: .time)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
      }

      if let lastSummary {
        summaryRow(lastSummary)
      }

      if books.isEmpty {
        ContentUnavailableView(
          "No Local Books",
          systemImage: "tray",
          description: Text("Tap Sync to pull your LazyLibrarian library.")
        )
      } else {
        ForEach(books) { book in
          libraryRow(book)
        }
      }
    }
    .navigationTitle("Local Library")
    .toolbar {
      ToolbarItem {
        Button(action: startSync) {
          if isSyncing {
            ProgressView()
          } else {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
        }
        .disabled(isSyncing)
        .help("Sync from LazyLibrarian")
      }
    }
    .onAppear {
      if books.isEmpty {
        startSync()
      }
    }
  }

  @ViewBuilder
  private func summaryRow(_ summary: LibrarySyncService.Summary) -> some View {
    let totalAdded = summary.insertedBooks + summary.insertedAuthors
    let totalUpdated = summary.updatedBooks + summary.updatedAuthors
    HStack(spacing: 8) {
      Text("Last sync result")
      Text("\(totalAdded) added, \(totalUpdated) updated")
        .foregroundStyle(.secondary)
    }
    .font(.caption)
  }

  private func startSync() {
    guard isSyncing == false else { return }
    isSyncing = true
    errorMessage = nil
    Task {
      do {
        let summary = try await LibrarySyncService().syncLibrary(
          using: client,
          modelContext: modelContext
        )
        lastSummary = summary
        lastSync = Date()
      } catch {
        errorMessage = error.localizedDescription
      }
      isSyncing = false
    }
  }

  @ViewBuilder
  private func libraryRow(_ book: LibraryBook) -> some View {
    let file = book.files.first
    let status = file?.downloadStatus ?? .notStarted
    let progress = downloadProgressByBookID[book.llId]
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text(book.title)
        Text(book.author?.name ?? "Unknown Author")
          .foregroundStyle(.secondary)
          .font(.caption)
        statusLine(status: status, progress: progress)
      }
      Spacer()
      downloadButton(for: book, status: status)
    }
  }

  @ViewBuilder
  private func statusLine(status: DownloadStatus, progress: Double?) -> some View {
    HStack(spacing: 6) {
      Text(statusLabel(for: status))
      if let progress {
        ProgressView(value: progress)
          .frame(maxWidth: 120)
      }
    }
    .foregroundStyle(.secondary)
    .font(.caption)
  }

  private func statusLabel(for status: DownloadStatus) -> String {
    switch status {
    case .notStarted:
      return "Not downloaded"
    case .downloading:
      return "Downloading"
    case .paused:
      return "Paused"
    case .failed:
      return "Failed"
    case .completed:
      return "Downloaded"
    }
  }

  @ViewBuilder
  private func downloadButton(for book: LibraryBook, status: DownloadStatus) -> some View {
    let isDownloading = downloadingBookIDs.contains(book.llId)
    Button(action: { startDownload(for: book) }) {
      switch status {
      case .completed:
        Image(systemName: "checkmark.circle.fill")
      case .failed:
        Text("Retry")
      case .downloading:
        ProgressView()
      default:
        Text("Download")
      }
    }
    .disabled(isDownloading || status == .completed || status == .downloading)
  }

  private func startDownload(for book: LibraryBook) {
    guard downloadingBookIDs.contains(book.llId) == false else { return }
    downloadingBookIDs.insert(book.llId)
    downloadProgressByBookID[book.llId] = 0
    errorMessage = nil

    Task {
      let fileRecord = ensureFileRecord(for: book)
      fileRecord.downloadStatus = .downloading
      fileRecord.lastError = nil
      fileRecord.bytesDownloaded = 0

      do {
        let tempURL = try await client.downloadAudiobook(bookID: book.llId) { value in
          Task { @MainActor in
            downloadProgressByBookID[book.llId] = value
          }
        }
        let stored = try LibraryStorage().storeDownloadedFile(
          tempURL,
          for: book,
          suggestedFilename: tempURL.lastPathComponent
        )
        let fileSize = stored.fileSizeBytes ?? 0
        fileRecord.filename = stored.filename
        fileRecord.localRelativePath = stored.relativePath
        fileRecord.sizeBytes = fileSize
        fileRecord.bytesDownloaded = fileSize
        fileRecord.format = BookFileFormat.fromFilename(stored.filename)
        fileRecord.downloadStatus = .completed

        let localState = ensureLocalState(for: book)
        localState.isDownloaded = true
        localState.lastPlayedAt = localState.lastPlayedAt ?? Date()

        try modelContext.save()
      } catch {
        fileRecord.downloadStatus = .failed
        fileRecord.lastError = error.localizedDescription
        try? modelContext.save()
        errorMessage = "Download failed: \(error.localizedDescription)"
      }

      downloadingBookIDs.remove(book.llId)
      downloadProgressByBookID[book.llId] = nil
    }
  }

  private func ensureFileRecord(for book: LibraryBook) -> LibraryBookFile {
    if let existing = book.files.first {
      return existing
    }
    let record = LibraryBookFile(
      llId: "\(book.llId):audio",
      filename: book.title,
      format: .unknown,
      sizeBytes: 0,
      checksum: nil,
      trackCount: nil,
      chapterInfoJSON: nil,
      downloadStatus: .notStarted,
      bytesDownloaded: 0,
      lastError: nil,
      localRelativePath: nil,
      book: book
    )
    modelContext.insert(record)
    book.files.append(record)
    return record
  }

  private func ensureLocalState(for book: LibraryBook) -> LocalBookState {
    if let existing = book.localState {
      return existing
    }
    let state = LocalBookState(bookLlId: book.llId, book: book)
    modelContext.insert(state)
    book.localState = state
    return state
  }
}

#if DEBUG
  #Preview {
    NavigationStack {
      LocalLibraryView(client: PreviewLazyLibrarianClient())
    }
    .modelContainer(
      for: [Author.self, Series.self, LibraryBook.self, LibraryBookFile.self, LocalBookState.self],
      inMemory: true
    )
  }

  private struct PreviewLazyLibrarianClient: LazyLibrarianServing {
    func searchBooks(query: String) async throws -> [LazyLibrarianBook] {
      []
    }

    func requestBook(id: String, titleHint: String?, authorHint: String?) async throws
      -> LazyLibrarianLibraryItem
    {
      throw LazyLibrarianError.notConfigured
    }

    func fetchLibraryItems() async throws -> [LazyLibrarianLibraryItem] {
      [
        LazyLibrarianLibraryItem(
          id: "demo-1",
          title: "The Left Hand of Darkness",
          author: "Ursula K. Le Guin",
          status: .downloaded,
          audioStatus: .downloaded,
          bookAdded: Date().addingTimeInterval(-86400),
          bookLibrary: Date().addingTimeInterval(-86400),
          audioLibrary: Date().addingTimeInterval(-86400),
          bookImagePath: nil
        ),
        LazyLibrarianLibraryItem(
          id: "demo-2",
          title: "Ancillary Justice",
          author: "Ann Leckie",
          status: .downloaded,
          audioStatus: .downloaded,
          bookAdded: Date().addingTimeInterval(-172800),
          bookLibrary: Date().addingTimeInterval(-172800),
          audioLibrary: Date().addingTimeInterval(-172800),
          bookImagePath: nil
        ),
      ]
    }

    func fetchBookCovers(wait: Bool) async throws {}

    func searchBook(id: String, library: LazyLibrarianLibrary) async throws {}

    func fetchDownloadProgress(limit: Int?) async throws -> [LazyLibrarianDownloadProgressItem] {
      []
    }

    func downloadEpub(bookID: String, progress: @escaping (Double) -> Void) async throws
      -> URL
    {
      throw LazyLibrarianError.notConfigured
    }

    func downloadAudiobook(bookID: String, progress: @escaping (Double) -> Void) async throws
      -> URL
    {
      throw LazyLibrarianError.notConfigured
    }
  }
#endif
