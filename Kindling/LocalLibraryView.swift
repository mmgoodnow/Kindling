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
  @Query(filter: #Predicate<LibrarySyncState> { $0.scope == "library" })
  private var syncStates: [LibrarySyncState]

  let client: RemoteLibraryServing

  @State private var isSyncing = false
  @State private var errorMessage: String?
  @State private var downloadProgressByBookID: [String: Double] = [:]
  @State private var downloadingBookIDs: Set<String> = []
  @StateObject private var player = AudioPlayerController()
  @State private var isShowingPlayer = false
  @State private var activePlaybackBook: LibraryBook?

  private var syncState: LibrarySyncState? {
    syncStates.first
  }

  private var lastSync: Date? {
    syncState?.lastSync
  }

  private var lastSummary: LibrarySyncService.Summary? {
    guard let syncState else { return nil }
    return LibrarySyncService.Summary(
      insertedBooks: syncState.insertedBooks,
      updatedBooks: syncState.updatedBooks,
      insertedAuthors: syncState.insertedAuthors,
      updatedAuthors: syncState.updatedAuthors
    )
  }

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
          description: Text("Tap Sync to pull your remote library.")
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
        .help("Sync from remote library")
      }
    }
    .onAppear {
      if books.isEmpty {
        startSync()
      }
    }
    #if os(iOS)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if player.hasLoadedItem {
          MiniPlaybackBar(player: player) {
            isShowingPlayer = true
          }
          .padding(.horizontal, 24)
          .padding(.top, 10)
          .padding(.bottom, 8)
        }
      }
    #endif
    .sheet(isPresented: $isShowingPlayer) {
      LocalPlaybackView(player: player)
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
        updateSyncState(with: summary, syncedAt: Date())
      } catch {
        errorMessage = error.localizedDescription
      }
      isSyncing = false
    }
  }

  @MainActor
  private func updateSyncState(with summary: LibrarySyncService.Summary, syncedAt: Date) {
    let state = syncState ?? LibrarySyncState()
    if syncState == nil {
      modelContext.insert(state)
    }
    state.lastSync = syncedAt
    state.insertedBooks = summary.insertedBooks
    state.updatedBooks = summary.updatedBooks
    state.insertedAuthors = summary.insertedAuthors
    state.updatedAuthors = summary.updatedAuthors
    if modelContext.hasChanges {
      try? modelContext.save()
    }
  }

  @ViewBuilder
  private func libraryRow(_ book: LibraryBook) -> some View {
    let file = book.files.first
    let status = file?.downloadStatus ?? .notStarted
    let progress = downloadProgressByBookID[book.llId]
    let audioStatus = parseAudioStatus(from: book)
    let playbackURL = playbackURL(for: book)
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text(book.title)
        Text(book.author?.name ?? "Unknown Author")
          .foregroundStyle(.secondary)
          .font(.caption)
        statusLine(status: status, progress: progress, audioStatus: audioStatus)
      }
      Spacer()
      if let playbackURL {
        playButton(for: book, url: playbackURL)
      } else {
        downloadButton(for: book, status: status, audioStatus: audioStatus)
      }
    }
  }

  @ViewBuilder
  private func statusLine(
    status: DownloadStatus,
    progress: Double?,
    audioStatus: PodibleLibraryItemStatus
  ) -> some View {
    HStack(spacing: 6) {
      Text(statusLabel(for: status))
      Text("Audio: \(audioStatus.rawValue)")
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
  private func downloadButton(
    for book: LibraryBook,
    status: DownloadStatus,
    audioStatus: PodibleLibraryItemStatus
  ) -> some View {
    let isDownloading = downloadingBookIDs.contains(book.llId)
    let canDownload = audioStatus.isComplete
    Button(action: { startDownload(for: book) }) {
      switch status {
      case .completed:
        Image(systemName: "checkmark.circle.fill")
      case .failed:
        Text("Retry")
      case .downloading:
        ProgressView()
      default:
        Text(canDownload ? "Download" : "Unavailable")
      }
    }
    .disabled(
      isDownloading || status == .completed || status == .downloading || canDownload == false)
  }

  @ViewBuilder
  private func playButton(for book: LibraryBook, url: URL) -> some View {
    Button(action: { startPlayback(for: book, url: url) }) {
      Image(systemName: "play.circle.fill")
        .font(.title2)
    }
    .help("Play")
  }

  private func startDownload(for book: LibraryBook) {
    guard downloadingBookIDs.contains(book.llId) == false else { return }
    downloadingBookIDs.insert(book.llId)
    downloadProgressByBookID[book.llId] = 0
    errorMessage = nil

    let audioStatus = parseAudioStatus(from: book)
    guard audioStatus.isComplete else {
      errorMessage = "Audiobook not ready (AudioStatus: \(audioStatus.rawValue))."
      downloadingBookIDs.remove(book.llId)
      downloadProgressByBookID[book.llId] = nil
      return
    }

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
        errorMessage =
          "Download failed (AudioStatus: \(audioStatus.rawValue)): \(error.localizedDescription)"
      }

      downloadingBookIDs.remove(book.llId)
      downloadProgressByBookID[book.llId] = nil
    }
  }

  private func startPlayback(for book: LibraryBook, url: URL) {
    activePlaybackBook = book
    let localState = ensureLocalState(for: book)
    localState.lastPlayedAt = Date()
    try? modelContext.save()
    player.load(
      url: url,
      bookID: book.llId,
      title: book.title,
      author: book.author?.name,
      description: book.summary,
      artworkURL: book.coverURLString.flatMap(URL.init(string:))
    )
    player.play()
    isShowingPlayer = true
  }

  private func playbackURL(for book: LibraryBook) -> URL? {
    guard
      let file = book.files.first,
      file.downloadStatus == .completed,
      let relativePath = file.localRelativePath
    else {
      return nil
    }

    let url = try? LibraryStorage().url(forRelativePath: relativePath)
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }

    let format =
      file.format == .unknown ? BookFileFormat.fromFilename(url.lastPathComponent) : file.format
    switch format {
    case .m4b, .mp3, .m4a:
      return url
    default:
      return nil
    }
  }

  private func parseAudioStatus(from book: LibraryBook) -> PodibleLibraryItemStatus {
    guard let raw = book.audioStatusRaw else { return .unknown }
    return PodibleLibraryItemStatus(rawValue: raw) ?? .unknown
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
      LocalLibraryView(client: PreviewPodibleClient())
    }
    .modelContainer(
      for: [
        Author.self,
        Series.self,
        LibraryBook.self,
        LibraryBookFile.self,
        LocalBookState.self,
        LibrarySyncState.self,
      ],
      inMemory: true
    )
  }

  private struct PreviewPodibleClient: RemoteLibraryServing {
    func searchBooks(query: String) async throws -> [PodibleBook] {
      []
    }

    func addLibraryBook(
      openLibraryKey: String,
      titleHint: String?,
      authorHint: String?
    ) async throws -> PodibleLibraryItem {
      throw PodibleError.notConfigured
    }

    func fetchLibraryItems() async throws -> [PodibleLibraryItem] {
      [
        PodibleLibraryItem(
          id: "demo-1",
          title: "The Left Hand of Darkness",
          author: "Ursula K. Le Guin",
          status: .downloaded,
          audioStatus: .downloaded,
          bookAdded: Date().addingTimeInterval(-86400),
          updatedAt: Date().addingTimeInterval(-86400),
          bookImagePath: nil
        ),
        PodibleLibraryItem(
          id: "demo-2",
          title: "Ancillary Justice",
          author: "Ann Leckie",
          status: .downloaded,
          audioStatus: .downloaded,
          bookAdded: Date().addingTimeInterval(-172800),
          updatedAt: Date().addingTimeInterval(-172800),
          bookImagePath: nil
        ),
      ]
    }

    func acquireLibraryMedia(bookID: String, library: PodibleLibraryMedia) async throws {}

    func fetchDownloadProgress(limit: Int?) async throws -> [PodibleDownloadProgressItem] {
      []
    }

    func downloadEpub(bookID: String, progress: @escaping (Double) -> Void) async throws
      -> URL
    {
      throw PodibleError.notConfigured
    }

    func downloadAudiobook(bookID: String, progress: @escaping (Double) -> Void) async throws
      -> URL
    {
      throw PodibleError.notConfigured
    }
  }
#endif
