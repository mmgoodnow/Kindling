import Foundation
import Kingfisher
import SwiftData
import SwiftUI

struct PodibleLibraryView: View {
  @EnvironmentObject var userSettings: UserSettings
  @Environment(\.modelContext) private var modelContext
  @Query(
    sort: [
      SortDescriptor(\LibraryBook.addedAt, order: .reverse),
      SortDescriptor(\LibraryBook.title, order: .forward),
    ]
  )
  private var localBooks: [LibraryBook]
  @Query(filter: #Predicate<LibrarySyncState> { $0.scope == "library" })
  private var syncStates: [LibrarySyncState]
  @StateObject private var viewModel = RemoteLibraryViewModel()
  @State private var isShowingShareSheet = false
  @State private var shareURL: URL?
  @State private var isShowingKindleExporter = false
  @State private var kindleExportFile: BookFile?
  @State private var isKindleExported = false
  @State private var downloadErrorMessage: String?
  @State private var downloadingBookID: String?
  @State private var downloadProgress: Double?
  @State private var downloadKind: DownloadKind?
  @State private var pendingSearchItemIDs: Set<String> = []
  @State private var searchTask: Task<Void, Never>?
  @State private var isSyncing = false
  @State private var syncErrorMessage: String?
  @State private var localDownloadProgressByBookID: [String: Double] = [:]
  @State private var localDownloadingBookIDs: Set<String> = []
  @StateObject private var player = AudioPlayerController()
  @State private var isShowingPlayer = false
  @State private var snatchContext: SnatchContext?

  let clientOverride: RemoteLibraryServing?

  init(client: RemoteLibraryServing? = nil) {
    self.clientOverride = client
  }

  private enum DownloadKind {
    case ebook
    case audiobook
  }

  private struct SnatchContext: Identifiable {
    let id = UUID()
    let item: PodibleLibraryItem
    let libraries: [PodibleLibraryMedia]
  }

  private var configuredClient: RemoteLibraryServing? {
    if let clientOverride {
      return clientOverride
    }
    if let url = URL(string: userSettings.podibleRPCURL),
      userSettings.podibleRPCURL.isEmpty == false,
      userSettings.podibleAPIKey.isEmpty == false
    {
      return PodibleClient(
        rpcURL: url,
        apiKey: userSettings.podibleAPIKey
      )
    }
    return nil
  }

  private var remoteAssetBaseURLString: String {
    userSettings.podibleRPCURL
  }

  var body: some View {
    content(client: configuredClient)
      .sheet(isPresented: $isShowingPlayer) {
        LocalPlaybackView(player: player)
      }
      .sheet(item: $snatchContext) { context in
        if let client = configuredClient {
          PodibleSnatchResultPicker(
            book: context.item,
            libraries: context.libraries,
            client: client
          ) { library in
            viewModel.noteSearchTriggered(bookID: context.item.id, library: library)
            await viewModel.loadLibraryItems(using: client)
          }
        } else {
          Text("Remote library backend is not configured.")
        }
      }
  }

  @ViewBuilder
  private func content(client: RemoteLibraryServing?) -> some View {
    List {
      if client == nil {
        Text(
          "Remote library backend not configured. Sync is disabled, but you can still play downloaded audiobooks."
        )
        .foregroundStyle(.secondary)
        .font(.caption)
      }

      if let error = viewModel.errorMessage {
        Text(error)
          .foregroundStyle(.red)
          .font(.caption)
      }

      if let downloadError = downloadErrorMessage {
        Text(downloadError)
          .foregroundStyle(.red)
          .font(.caption)
      }

      if let syncErrorMessage {
        Text(syncErrorMessage)
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

      let trimmedQuery = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedQuery.isEmpty {
        libraryListing(client: client)
      } else {
        searchListing(query: trimmedQuery, client: client)
      }
    }
    #if os(iOS)
      .listStyle(.grouped)
    #endif
    .navigationTitle("Library")
    .toolbar {
      ToolbarItem {
        Button(action: { startSync(using: client) }) {
          if isSyncing {
            ProgressView()
          } else {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
        }
        .disabled(client == nil || isSyncing)
        .help("Sync from backend")
      }
    }
    .onAppear {
      guard let client else { return }
      Task {
        if localBooks.isEmpty || lastSync == nil {
          await syncFromRemote(using: client)
        }
        await viewModel.loadLibraryItems(using: client)
      }
    }
    .refreshable {
      guard let client else { return }
      await refresh(using: client)
    }
    .searchable(text: $viewModel.query, prompt: "Search")
    .onSubmit(of: .search) {
      guard let client else { return }
      Task {
        await viewModel.search(using: client)
      }
    }
    .onChange(of: viewModel.query) { _, newValue in
      searchTask?.cancel()
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        viewModel.searchResults = []
        pendingSearchItemIDs.removeAll()
        return
      }
      searchTask = Task {
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard Task.isCancelled == false else { return }
        guard let client else { return }
        await viewModel.search(using: client, query: trimmed)
      }
    }
    #if os(iOS)
      .sheet(isPresented: $isShowingShareSheet) {
        if let shareURL {
          ActivityShareSheet(items: [shareURL])
        }
      }
    #else
      .background(
        ShareSheetPresenter(
          isPresented: $isShowingShareSheet,
          items: shareURL.map { [$0] } ?? []
        )
      )
    #endif
    .exporter(
      downloadedFile: kindleExportFile,
      kindleEmailAddress: userSettings.kindleEmailAddress,
      isExportModalOpen: $isShowingKindleExporter,
      isExported: $isKindleExported
    )
  }

  private var localBooksById: [String: LibraryBook] {
    Dictionary(uniqueKeysWithValues: localBooks.map { ($0.llId, $0) })
  }

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

  @ViewBuilder
  private func libraryListing(client: RemoteLibraryServing?) -> some View {
    let remoteItems = viewModel.libraryItems
    let remoteIds = Set(remoteItems.map(\.id))
    let localOnly = localBooks.filter { remoteIds.contains($0.llId) == false }

    if remoteItems.isEmpty && localBooks.isEmpty {
      ContentUnavailableView(
        "No Books",
        systemImage: "tray",
        description: Text(
          client == nil
            ? "Add audiobooks to your local library to get started."
            : "Tap Sync to pull your remote library."
        )
      )
    } else if remoteItems.isEmpty {
      ForEach(localBooks) { book in
        localLibraryRow(book, client: client)
      }
    } else {
      ForEach(remoteItems) { item in
        libraryRow(item, localBook: localBooksById[item.id], client: client)
      }
      if localOnly.isEmpty == false {
        Section("Local Only") {
          ForEach(localOnly) { book in
            localLibraryRow(book, client: client)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func searchListing(query: String, client: RemoteLibraryServing?) -> some View {
    let localMatches = filteredLocalBooks(query: query)
    let localIds = Set(localMatches.map(\.llId))
    let remoteResults = viewModel.searchResults.filter { localIds.contains($0.id) == false }

    if localMatches.isEmpty && remoteResults.isEmpty {
      ContentUnavailableView("No Results", systemImage: "magnifyingglass")
    } else {
      ForEach(localMatches) { book in
        localLibraryRow(book, client: client)
      }
      if let client {
        ForEach(remoteResults) { book in
          PodibleSearchResultRow(
            viewModel: viewModel,
            book: book,
            client: client,
            pendingItemIDs: $pendingSearchItemIDs
          )
        }
      }
    }
  }

  private func filteredLocalBooks(query: String) -> [LibraryBook] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return localBooks }
    let needle = trimmed.lowercased()
    return localBooks.filter { book in
      book.title.lowercased().contains(needle)
        || (book.author?.name.lowercased().contains(needle) ?? false)
    }
  }

  private func startSync(using client: RemoteLibraryServing?) {
    guard let client else { return }
    guard isSyncing == false else { return }
    Task {
      await syncFromRemote(using: client)
    }
  }

  @MainActor
  private func syncFromRemote(using client: RemoteLibraryServing) async {
    guard isSyncing == false else { return }
    isSyncing = true
    syncErrorMessage = nil
    do {
      let summary = try await LibrarySyncService().syncLibrary(
        using: client,
        modelContext: modelContext
      )
      updateSyncState(with: summary, syncedAt: Date())
    } catch {
      syncErrorMessage = error.localizedDescription
    }
    isSyncing = false
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

  @MainActor
  private func refresh(using client: RemoteLibraryServing) async {
    await syncFromRemote(using: client)
    await viewModel.loadLibraryItems(using: client)
  }

  private func presentSnatchPicker(
    for item: PodibleLibraryItem,
    libraries: [PodibleLibraryMedia]
  ) {
    guard libraries.isEmpty == false else { return }
    snatchContext = SnatchContext(item: item, libraries: libraries)
  }

  @MainActor
  private func reportWrongImportedFile(
    bookID: String,
    library: PodibleLibraryMedia,
    client: RemoteLibraryServing
  ) async {
    downloadErrorMessage = nil
    do {
      try await client.reportImportIssue(bookID: bookID, library: library)
      await viewModel.loadLibraryItems(using: client)
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
  }

  private func snatchLibraries(
    canTriggerEbookSearch: Bool,
    canTriggerAudioSearch: Bool
  ) -> [PodibleLibraryMedia] {
    var libraries: [PodibleLibraryMedia] = []
    if canTriggerEbookSearch {
      libraries.append(.ebook)
    }
    if canTriggerAudioSearch {
      libraries.append(.audio)
    }
    return libraries
  }

  private func startEbookDownload(
    bookID: String,
    title: String,
    client: RemoteLibraryServing
  ) async {
    if let cachedURL = cachedEbookURL(title: title) {
      let filename = sanitizeFilename(title).appending(".\(cachedURL.pathExtension)")
      shareURL = makeShareableCopy(of: cachedURL, filename: filename) ?? cachedURL
      isShowingShareSheet = true
      return
    }
    downloadingBookID = bookID
    downloadKind = .ebook
    downloadProgress = 0
    downloadErrorMessage = nil
    do {
      let localURL = try await client.downloadEpub(bookID: bookID) { value in
        Task { @MainActor in
          downloadProgress = value
        }
      }
      let filename = sanitizeFilename(title).appending(".\(localURL.pathExtension)")
      shareURL = makeShareableCopy(of: localURL, filename: filename) ?? localURL
      isShowingShareSheet = true
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
    downloadingBookID = nil
    downloadKind = nil
    downloadProgress = nil
  }

  private func startKindleExport(
    bookID: String,
    title: String,
    client: RemoteLibraryServing
  ) async {
    if let cachedURL = cachedEbookURL(title: title) {
      let filename = sanitizeFilename(title).appending(".\(cachedURL.pathExtension)")
      do {
        let data = try Data(contentsOf: cachedURL)
        kindleExportFile = BookFile(filename: filename, data: data)
        isShowingKindleExporter = true
      } catch {
        downloadErrorMessage = error.localizedDescription
      }
      return
    }
    downloadingBookID = bookID
    downloadKind = .ebook
    downloadProgress = 0
    downloadErrorMessage = nil
    do {
      let localURL = try await client.downloadEpub(bookID: bookID) { value in
        Task { @MainActor in
          downloadProgress = value
        }
      }
      let filename = sanitizeFilename(title).appending(".\(localURL.pathExtension)")
      let data = try Data(contentsOf: localURL)
      kindleExportFile = BookFile(filename: filename, data: data)
      isShowingKindleExporter = true
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
    downloadingBookID = nil
    downloadKind = nil
    downloadProgress = nil
  }

  private func startAudiobookDownload(
    bookID: String,
    title: String,
    client: RemoteLibraryServing
  ) async {
    downloadingBookID = bookID
    downloadKind = .audiobook
    downloadProgress = 0
    downloadErrorMessage = nil
    do {
      let localURL = try await client.downloadAudiobook(bookID: bookID) { value in
        Task { @MainActor in
          downloadProgress = value
        }
      }
      let filename = localURL.lastPathComponent
      shareURL = makeShareableCopy(of: localURL, filename: filename) ?? localURL
      isShowingShareSheet = true
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
    downloadingBookID = nil
    downloadKind = nil
    downloadProgress = nil
  }

  private func sanitizeFilename(_ value: String) -> String {
    let sanitized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "[\\\\/:*?\"<>|]", with: "-", options: .regularExpression)
    return sanitized.isEmpty ? "untitled" : sanitized
  }

  private func makeShareableCopy(of url: URL, filename: String) -> URL? {
    guard url.lastPathComponent != filename else { return url }
    let destination = url.deletingLastPathComponent().appendingPathComponent(filename)
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: url, to: destination)
      return destination
    } catch {
      return nil
    }
  }

  private func cachedEbookURL(title: String) -> URL? {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("lazy-librarian", isDirectory: true)
    let prefix = sanitizeFilename(title).appending(".")
    guard
      let contents = try? fm.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }
    let matches = contents.filter { $0.lastPathComponent.hasPrefix(prefix) }
    guard matches.isEmpty == false else { return nil }
    return matches.max { lhs, rhs in
      let lhsDate =
        (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      let rhsDate =
        (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return lhsDate < rhsDate
    }
  }

  private func libraryRow(
    _ item: PodibleLibraryItem,
    localBook: LibraryBook?,
    client: RemoteLibraryServing?
  ) -> some View {
    let progress = viewModel.progressForBookID(item.id)
    let isDownloadingThisBook = downloadingBookID == item.id

    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        bookCoverView(
          title: item.title,
          author: item.author,
          url: remoteLibraryAssetURL(
            baseURLString: remoteAssetBaseURLString,
            path: item.bookImagePath
          )
        )
        VStack(alignment: .leading, spacing: 6) {
          Text(item.title)
            .font(.headline)
            .lineLimit(2)
          Text(item.author)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if let client {
            rowControls(
              item: item,
              client: client,
              isDownloadingThisBook: isDownloadingThisBook
            )
          }
          localAudioControls(
            item: item,
            localBook: localBook,
            client: client
          )
        }
        Spacer(minLength: 0)
        remoteLibraryStatusCluster(
          item: item,
          progress: progress,
          shouldOfferSearch: { status in
            viewModel.shouldOfferSearch(status: status)
          }
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func rowControls(
    item: PodibleLibraryItem,
    client: RemoteLibraryServing,
    isDownloadingThisBook: Bool
  ) -> some View {
    let canEbookSearch = viewModel.shouldOfferSearch(status: item.status)
    let canAudioSearch = viewModel.shouldOfferSearch(status: item.audioStatus)
    let canTriggerEbookSearch =
      canEbookSearch
      && viewModel.canTriggerSearch(bookID: item.id, library: .ebook)
    let canTriggerAudioSearch =
      canAudioSearch
      && viewModel.canTriggerSearch(bookID: item.id, library: .audio)
    let canDownload = isDownloadingThisBook == false
    let canExport = item.status == .open && canDownload
    let canAudioExport = item.audioStatus == .open && canDownload
    let canKindleExport =
      canExport && userSettings.kindleEmailAddress.isEmpty == false
    let wrongFileLibrary: PodibleLibraryMedia? = {
      guard client.supportsImportIssueReporting else { return nil }
      if item.audioStatus?.isComplete == true { return .audio }
      if item.status.isComplete { return .ebook }
      return nil
    }()

    let canRefresh = canEbookSearch || canAudioSearch
    let canTriggerRefresh = canTriggerEbookSearch || canTriggerAudioSearch
    let snatchLibraries = snatchLibraries(
      canTriggerEbookSearch: canTriggerEbookSearch,
      canTriggerAudioSearch: canTriggerAudioSearch
    )
    let canChooseResult = client.supportsManualResultSelection && snatchLibraries.isEmpty == false
    let controls = HStack(spacing: 8) {
      trailingControlButton(
        label: "Download & Export",
        systemName: "square.and.arrow.up",
        isEnabled: canExport,
        action: {
          Task {
            await startEbookDownload(
              bookID: item.id,
              title: item.title,
              client: client
            )
          }
        }
      )
      if item.audioStatus == .open {
        trailingControlButton(
          label: "Download Audiobook",
          systemName: "waveform",
          isEnabled: canAudioExport,
          action: {
            Task {
              await startAudiobookDownload(
                bookID: item.id,
                title: item.title,
                client: client
              )
            }
          }
        )
      }
      trailingControlButton(
        label: "Email to Kindle",
        systemName: "paperplane",
        isEnabled: canKindleExport,
        action: {
          Task {
            await startKindleExport(
              bookID: item.id,
              title: item.title,
              client: client
            )
          }
        }
      )
      if let wrongFileLibrary {
        trailingControlButton(
          label: "Wrong File",
          systemName: "exclamationmark.triangle",
          action: {
            Task {
              await reportWrongImportedFile(
                bookID: item.id,
                library: wrongFileLibrary,
                client: client
              )
            }
          }
        )
      }
      if canChooseResult {
        trailingControlButton(
          label: "Choose Result",
          systemName: "list.bullet.rectangle",
          action: {
            presentSnatchPicker(for: item, libraries: snatchLibraries)
          }
        )
      }
      if isDownloadingThisBook, let progress = downloadProgress, let kind = downloadKind {
        remoteLibraryProgressCircle(
          value: Int(progress * 100),
          tint: .secondary,
          icon: kind == .ebook ? "book" : "waveform.mid",
          snoring: false
        )
      }
      if canRefresh {
        trailingControlButton(
          label: "Refresh",
          systemName: "arrow.clockwise",
          isEnabled: canTriggerRefresh,
          action: {
            Task {
              if canTriggerEbookSearch {
                await viewModel.triggerAcquire(
                  bookID: item.id,
                  library: .ebook,
                  using: client
                )
              }
              if canTriggerAudioSearch {
                await viewModel.triggerAcquire(
                  bookID: item.id,
                  library: .audio,
                  using: client
                )
              }
              await viewModel.loadLibraryItems(using: client)
            }
          }
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: 44)
    controls
  }

  private func trailingControlButton(
    label: String,
    systemName: String,
    isEnabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.title3.weight(.medium))
        .foregroundStyle(.accent)
        .imageScale(.large)
        .frame(width: 44, height: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .disabled(!isEnabled)
    .accessibilityLabel(label)
  }

  private func trailingControlButton(
    label: String,
    isEnabled: Bool = true,
    @ViewBuilder content: () -> some View,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      content()
        .foregroundStyle(.accent)
        .frame(width: 44, height: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .disabled(!isEnabled)
    .accessibilityLabel(label)
  }

  private func searchActionIcon(base: String) -> some View {
    ZStack {
      Image(systemName: base)
        .font(.title3.weight(.medium))
      Image(systemName: "magnifyingglass")
        .font(.system(size: 9, weight: .bold))
        .offset(x: 10, y: 10)
    }
  }

  private func localAudioControls(
    item: PodibleLibraryItem,
    localBook: LibraryBook?,
    client: RemoteLibraryServing?
  ) -> some View {
    let audioStatus = audioStatus(for: localBook, fallback: item.audioStatus)
    let status = localBook?.files.first?.downloadStatus ?? .notStarted
    let progress = localDownloadProgressByBookID[item.id]
    let localPlaybackURL = localBook.flatMap { playbackURL(for: $0) }

    let actionView: AnyView
    if let localBook, let localPlaybackURL {
      actionView = AnyView(playButton(for: localBook, url: localPlaybackURL))
    } else {
      actionView = AnyView(
        localDownloadButton(
          for: item,
          status: status,
          audioStatus: audioStatus,
          client: client
        )
      )
    }

    let progressView = ProgressView(value: progress ?? 0)
      .frame(maxWidth: 120)
      .opacity(progress == nil ? 0 : 1)

    return HStack(spacing: 8) {
      actionView
      progressView
      Text(statusLabel(for: status))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func localLibraryRow(_ book: LibraryBook, client: RemoteLibraryServing?) -> some View {
    let file = book.files.first
    let status = file?.downloadStatus ?? .notStarted
    let progress = localDownloadProgressByBookID[book.llId]
    let audioStatus = parseAudioStatus(from: book)
    let playbackURL = playbackURL(for: book)
    let coverURL = remoteLibraryAssetURL(
      baseURLString: remoteAssetBaseURLString,
      path: book.coverURLString
    )

    HStack(alignment: .top, spacing: 12) {
      bookCoverView(
        title: book.title,
        author: book.author?.name ?? "Unknown Author",
        url: coverURL
      )
      VStack(alignment: .leading, spacing: 6) {
        Text(book.title)
          .font(.headline)
          .lineLimit(2)
        Text(book.author?.name ?? "Unknown Author")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        statusLine(status: status, progress: progress, audioStatus: audioStatus)
        if let playbackURL {
          playButton(for: book, url: playbackURL)
        } else {
          localDownloadButton(
            for: book,
            status: status,
            audioStatus: audioStatus,
            client: client
          )
        }
      }
      Spacer(minLength: 0)
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
  private func localDownloadButton(
    for book: LibraryBook,
    status: DownloadStatus,
    audioStatus: PodibleLibraryItemStatus,
    client: RemoteLibraryServing?
  ) -> some View {
    let isDownloading = localDownloadingBookIDs.contains(book.llId)
    let canDownload = audioStatus.isComplete && client != nil
    Button(action: {
      guard let client else { return }
      startLocalDownload(for: book, client: client)
    }) {
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
      isDownloading || status == .completed || status == .downloading || canDownload == false
    )
  }

  @ViewBuilder
  private func localDownloadButton(
    for item: PodibleLibraryItem,
    status: DownloadStatus,
    audioStatus: PodibleLibraryItemStatus,
    client: RemoteLibraryServing?
  ) -> some View {
    let isDownloading = localDownloadingBookIDs.contains(item.id)
    let canDownload = audioStatus.isComplete && client != nil
    Button(action: {
      guard let client else { return }
      startLocalDownload(for: item, client: client)
    }) {
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
      isDownloading || status == .completed || status == .downloading || canDownload == false
    )
  }

  @ViewBuilder
  private func playButton(for book: LibraryBook, url: URL) -> some View {
    Button(action: { startPlayback(for: book, url: url) }) {
      Image(systemName: "play.circle.fill")
        .font(.title2)
    }
    .help("Play")
  }

  @MainActor
  private func startPlayback(for book: LibraryBook, url: URL) {
    let localState = ensureLocalState(for: book)
    localState.lastPlayedAt = Date()
    try? modelContext.save()
    player.load(url: url, title: book.title)
    player.play()
    isShowingPlayer = true
  }

  @MainActor
  private func startLocalDownload(for book: LibraryBook, client: RemoteLibraryServing) {
    guard localDownloadingBookIDs.contains(book.llId) == false else { return }
    localDownloadingBookIDs.insert(book.llId)
    localDownloadProgressByBookID[book.llId] = 0
    downloadErrorMessage = nil

    let audioStatus = parseAudioStatus(from: book)
    guard audioStatus.isComplete else {
      downloadErrorMessage = "Audiobook not ready (AudioStatus: \(audioStatus.rawValue))."
      localDownloadingBookIDs.remove(book.llId)
      localDownloadProgressByBookID[book.llId] = nil
      return
    }

    Task { @MainActor in
      let fileRecord = ensureFileRecord(for: book)
      fileRecord.downloadStatus = .downloading
      fileRecord.lastError = nil
      fileRecord.bytesDownloaded = 0

      do {
        let tempURL = try await client.downloadAudiobook(bookID: book.llId) { value in
          Task { @MainActor in
            localDownloadProgressByBookID[book.llId] = value
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
        downloadErrorMessage =
          "Download failed (AudioStatus: \(audioStatus.rawValue)): \(error.localizedDescription)"
      }

      localDownloadingBookIDs.remove(book.llId)
      localDownloadProgressByBookID[book.llId] = nil
    }
  }

  @MainActor
  private func startLocalDownload(for item: PodibleLibraryItem, client: RemoteLibraryServing) {
    let book = ensureLocalBook(for: item)
    startLocalDownload(for: book, client: client)
  }

  private func audioStatus(
    for book: LibraryBook?,
    fallback: PodibleLibraryItemStatus?
  ) -> PodibleLibraryItemStatus {
    if let book, let raw = book.audioStatusRaw,
      let status = PodibleLibraryItemStatus(rawValue: raw)
    {
      return status
    }
    return fallback ?? .unknown
  }

  private func parseAudioStatus(from book: LibraryBook) -> PodibleLibraryItemStatus {
    audioStatus(for: book, fallback: nil)
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

  @MainActor
  private func ensureLocalBook(for item: PodibleLibraryItem) -> LibraryBook {
    if let existing = localBooksById[item.id] {
      let author = fetchOrCreateAuthor(name: item.author)
      updateLocalBook(existing, with: item, author: author)
      return existing
    }

    let author = fetchOrCreateAuthor(name: item.author)
    let book = LibraryBook(
      llId: item.id,
      title: item.title,
      summary: nil,
      coverURLString: item.bookImagePath,
      runtimeSeconds: nil,
      addedAt: item.bookAdded,
      updatedAt: latestLibraryDate(for: item),
      seriesIndex: nil,
      bookStatusRaw: item.status.rawValue,
      audioStatusRaw: item.audioStatus?.rawValue,
      author: author,
      series: nil
    )
    modelContext.insert(book)
    if modelContext.hasChanges {
      try? modelContext.save()
    }
    return book
  }

  @MainActor
  private func fetchOrCreateAuthor(name: String) -> Author {
    let key = normalizeAuthorKey(name)
    let descriptor = FetchDescriptor<Author>(
      predicate: #Predicate { $0.llId == key }
    )
    if let existing = (try? modelContext.fetch(descriptor))?.first {
      if existing.name != name {
        existing.name = name
      }
      return existing
    }
    let author = Author(llId: key, name: name)
    modelContext.insert(author)
    return author
  }

  @MainActor
  private func updateLocalBook(
    _ book: LibraryBook,
    with item: PodibleLibraryItem,
    author: Author
  ) {
    var updated = false
    if book.title != item.title {
      book.title = item.title
      updated = true
    }
    if book.coverURLString != item.bookImagePath {
      book.coverURLString = item.bookImagePath
      updated = true
    }
    let nextAddedAt = item.bookAdded
    if book.addedAt != nextAddedAt {
      book.addedAt = nextAddedAt
      updated = true
    }
    let nextUpdatedAt = latestLibraryDate(for: item)
    if book.updatedAt != nextUpdatedAt {
      book.updatedAt = nextUpdatedAt
      updated = true
    }
    if book.author !== author {
      book.author = author
      updated = true
    }
    if book.bookStatusRaw != item.status.rawValue {
      book.bookStatusRaw = item.status.rawValue
      updated = true
    }
    if book.audioStatusRaw != item.audioStatus?.rawValue {
      book.audioStatusRaw = item.audioStatus?.rawValue
      updated = true
    }
    if updated, modelContext.hasChanges {
      try? modelContext.save()
    }
  }

  private func normalizeAuthorKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func latestLibraryDate(for item: PodibleLibraryItem) -> Date? {
    [item.bookLibrary, item.audioLibrary].compactMap { $0 }.max()
  }
}

typealias RemoteLibraryView = PodibleLibraryView

private struct PodibleSnatchResultPicker: View {
  let book: PodibleLibraryItem
  let libraries: [PodibleLibraryMedia]
  let client: RemoteLibraryServing
  let onSnatchComplete: (PodibleLibraryMedia) async -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selectedLibrary: PodibleLibraryMedia
  @State private var results: [PodibleSearchResult] = []
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var snatchError: String?
  @State private var activeSnatchID: String?

  init(
    book: PodibleLibraryItem,
    libraries: [PodibleLibraryMedia],
    client: RemoteLibraryServing,
    onSnatchComplete: @escaping (PodibleLibraryMedia) async -> Void
  ) {
    self.book = book
    self.libraries = libraries
    self.client = client
    self.onSnatchComplete = onSnatchComplete
    _selectedLibrary = State(initialValue: libraries.first ?? .ebook)
  }

  var body: some View {
    NavigationStack {
      List {
        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .font(.caption)
        }

        if let snatchError {
          Text(snatchError)
            .foregroundStyle(.red)
            .font(.caption)
        }

        if libraries.count > 1 {
          Picker("Library", selection: $selectedLibrary) {
            ForEach(libraries, id: \.self) { library in
              Text(library.rawValue)
                .tag(library)
            }
          }
          .pickerStyle(.segmented)
        }

        if isLoading {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
        } else if filteredResults.isEmpty {
          ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("Try refreshing or adjusting your query.")
          )
        } else {
          ForEach(filteredResults) { result in
            snatchRow(result)
          }
        }
      }
      .navigationTitle("Choose Result")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task {
        await loadResults()
      }
    }
  }

  private var filteredResults: [PodibleSearchResult] {
    results.filter { result in
      guard let library = result.library else { return true }
      return library == selectedLibrary
    }
  }

  @ViewBuilder
  private func snatchRow(_ result: PodibleSearchResult) -> some View {
    let title = result.title.isEmpty ? result.url : result.title
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
          .lineLimit(2)
        Text(result.provider.isEmpty ? "Unknown Provider" : result.provider)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          if let size = result.displaySize {
            Text(size)
          }
          if let seeders = result.seeders {
            Text("S \(seeders)")
          }
          if let leechers = result.leechers {
            Text("L \(leechers)")
          }
          if let age = result.age {
            Text(age)
          }
          if result.mode.isEmpty == false {
            Text(result.mode)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      if activeSnatchID == result.id {
        ProgressView()
          .controlSize(.small)
      } else {
        Button("Snatch") {
          snatch(result)
        }
        .disabled(result.canSnatch == false || activeSnatchID != nil)
      }
    }
    .padding(.vertical, 4)
  }

  @MainActor
  private func loadResults() async {
    guard isLoading == false else { return }
    isLoading = true
    errorMessage = nil
    let query = [book.title, book.author]
      .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
      .joined(separator: " ")
    do {
      let category = selectedLibrary.searchCategory
      let bookID = book.id.isEmpty ? nil : book.id
      results = try await client.searchItem(query: query, cat: category, bookID: bookID)
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  private func snatch(_ result: PodibleSearchResult) {
    snatchError = nil
    activeSnatchID = result.id
    Task { @MainActor in
      do {
        try await client.snatchResult(
          bookID: book.id,
          library: selectedLibrary,
          result: result
        )
        await onSnatchComplete(selectedLibrary)
        dismiss()
      } catch {
        snatchError = error.localizedDescription
      }
      activeSnatchID = nil
    }
  }
}

@ViewBuilder
func remoteLibraryEbookStatusRow(
  status: PodibleLibraryItemStatus?,
  progressValue: Int?,
  progressFinished: Bool,
  progressSeen: Bool,
  shouldOfferSearch: Bool
) -> some View {
  let isComplete = status?.isComplete ?? false
  Group {
    if isComplete == false {
      if progressSeen {
        remoteLibraryProgressCircle(
          value: progressValue ?? 0,
          tint: progressFinished ? .green : .blue,
          icon: "book",
          snoring: false
        )
      } else {
        remoteLibraryProgressCircle(
          value: 0,
          tint: .blue,
          icon: "book",
          snoring: true
        )
        .opacity(shouldOfferSearch ? 1 : 0)
      }
    }
  }
  .transition(.opacity)
  .animation(.easeInOut(duration: 0.2), value: isComplete)
}

@ViewBuilder
func remoteLibraryAudioStatusRow(
  status: PodibleLibraryItemStatus?,
  progressValue: Int?,
  progressFinished: Bool,
  progressSeen: Bool,
  shouldOfferSearch: Bool
) -> some View {
  let isComplete = status?.isComplete ?? false
  Group {
    if isComplete == false {
      if progressSeen {
        remoteLibraryProgressCircle(
          value: progressValue ?? 0,
          tint: progressFinished ? .green : .blue,
          icon: "waveform.mid",
          snoring: false
        )
      } else {
        remoteLibraryProgressCircle(
          value: 0,
          tint: .blue,
          icon: "waveform.mid",
          snoring: true
        )
        .opacity(shouldOfferSearch ? 1 : 0)
      }
    }
  }
  .transition(.opacity)
  .animation(.easeInOut(duration: 0.2), value: isComplete)
}

@ViewBuilder
func remoteLibraryProgressCircles(
  progress: PodibleLibraryDownloadProgress
) -> some View {
  VStack(alignment: .trailing, spacing: 6) {
    HStack(spacing: 6) {
      remoteLibraryProgressCircle(
        value: progress.ebook,
        tint: progress.ebookFinished ? .green : .blue,
        icon: "book",
        snoring: false
      )
    }
    HStack(spacing: 6) {
      remoteLibraryProgressCircle(
        value: progress.audiobook,
        tint: progress.audiobookFinished ? .green : .blue,
        icon: "waveform.mid",
        snoring: false
      )
    }
  }
}

@ViewBuilder
func remoteLibraryStatusCluster(
  item: PodibleLibraryItem,
  progress: PodibleLibraryDownloadProgress?,
  shouldOfferSearch: (PodibleLibraryItemStatus?) -> Bool
) -> some View {
  let showEbook = item.status.isComplete == false
  let showAudio = item.audioStatus?.isComplete == false
  HStack(spacing: 10) {
    if showEbook {
      remoteLibraryEbookStatusRow(
        status: item.status,
        progressValue: progress?.ebook,
        progressFinished: progress?.ebookFinished ?? false,
        progressSeen: progress?.ebookSeen ?? false,
        shouldOfferSearch: shouldOfferSearch(item.status)
      )
    }
    if showAudio {
      remoteLibraryAudioStatusRow(
        status: item.audioStatus,
        progressValue: progress?.audiobook,
        progressFinished: progress?.audiobookFinished ?? false,
        progressSeen: progress?.audiobookSeen ?? false,
        shouldOfferSearch: shouldOfferSearch(item.audioStatus)
      )
    }
  }
}

@ViewBuilder
func remoteLibraryProgressCircle(
  value: Int,
  tint: Color,
  icon: String?,
  snoring: Bool
) -> some View {
  let clamped = max(0, min(100, value))
  let progress = Double(clamped) / 100.0
  let base = ZStack {
    Circle()
      .stroke(.tertiary, lineWidth: 1.5)
    Circle()
      .trim(from: 0, to: progress)
      .stroke(
        .secondary,
        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
      )
      .rotationEffect(.degrees(-90))
      .animation(.easeInOut(duration: 0.25), value: clamped)
    if let icon {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.secondary)
    }
  }
  .frame(width: 22, height: 22)

  if snoring {
    TimelineView(.animation) { context in
      let phase = context.date.timeIntervalSinceReferenceDate * 2.0
      let opacity = 0.35 + 0.65 * (sin(phase) + 1.0) / 2.0
      base.opacity(opacity)
    }
  } else {
    base
  }
}

@MainActor
@ViewBuilder
func bookCoverView(title: String, author: String, url: URL?) -> some View {
  if let url {
    KFImage(url)
      .placeholder {
        bookCoverPlaceholder(title: title, author: author)
      }
      .resizable()
      .scaledToFill()
      .frame(width: 88, height: 128)
      .clipShape(RoundedRectangle(cornerRadius: 6))
  } else {
    bookCoverPlaceholder(title: title, author: author)
  }
}

func bookCoverPlaceholder(title: String, author: String) -> some View {
  RoundedRectangle(cornerRadius: 6)
    .fill(coverPlaceholderColor(title: title, author: author))
    .frame(width: 88, height: 128)
    .overlay(
      VStack(spacing: 6) {
        Text(title)
          .font(.caption.weight(.semibold))
          .multilineTextAlignment(.center)
          .lineLimit(3)
        Text(author)
          .font(.caption2)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
      .padding(8)
      .foregroundStyle(.white.opacity(0.9))
    )
}

func coverPlaceholderColor(title: String, author: String) -> Color {
  let palette: [Color] = [
    Color(red: 0.36, green: 0.25, blue: 0.20),
    Color(red: 0.16, green: 0.33, blue: 0.52),
    Color(red: 0.46, green: 0.22, blue: 0.28),
    Color(red: 0.18, green: 0.43, blue: 0.36),
    Color(red: 0.42, green: 0.36, blue: 0.18),
    Color(red: 0.28, green: 0.28, blue: 0.48),
  ]
  var hash = 5381
  for scalar in (title + "|" + author).unicodeScalars {
    hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
  }
  let index = abs(hash) % palette.count
  return palette[index]
}

func remoteLibraryAssetURL(baseURLString: String, path: String?) -> URL? {
  guard let path else { return nil }
  let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.lowercased().hasSuffix("nocover.png") {
    return nil
  }
  if let absolute = URL(string: trimmed), absolute.scheme != nil {
    return absolute
  }
  guard let baseURL = URL(string: baseURLString) else { return nil }
  var base = baseURL
  if base.path.hasSuffix("/api") {
    base.deleteLastPathComponent()
  } else if base.path.hasSuffix("/rpc") {
    base.deleteLastPathComponent()
  }
  if base.path.hasSuffix("/") == false {
    base.appendPathComponent("")
  }
  guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
    return nil
  }
  return url
}

struct ActivityShareSheet: View {
  let items: [Any]

  var body: some View {
    ActivityShareSheetController(items: items)
  }
}

#if os(iOS)
  struct ActivityShareSheetController: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
      UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
  }
#else
  struct ActivityShareSheetController: NSViewRepresentable {
    let items: [Any]

    func makeNSView(context: Context) -> NSView {
      NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
    }
  }

  struct ShareSheetPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let items: [Any]

    func makeNSView(context: Context) -> NSView {
      NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
      guard isPresented, items.isEmpty == false else { return }
      DispatchQueue.main.async {
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
        isPresented = false
      }
    }
  }
#endif

#Preview {
  NavigationStack {
    RemoteLibraryView(client: PodibleMockClient())
      .environmentObject(UserSettings())
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
