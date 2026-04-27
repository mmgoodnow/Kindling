import Foundation
import Kingfisher
import SwiftData
import SwiftUI

struct PodibleLibraryView: View {
  @EnvironmentObject var userSettings: UserSettings
  @EnvironmentObject var podibleAuth: PodibleAuthController
  @EnvironmentObject var player: AudioPlayerController
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.modelContext) private var modelContext
  @Environment(\.colorScheme) private var colorScheme
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
  @State private var isSyncSpinnerVisible = false
  @State private var syncSpinnerTask: Task<Void, Never>?
  @State private var syncErrorMessage: String?
  @State private var localDownloadProgressByBookID: [String: Double] = [:]
  @State private var localDownloadingBookIDs: Set<String> = []

  let clientOverride: RemoteLibraryServing?
  @Binding var isShowingPlayer: Bool

  init(client: RemoteLibraryServing? = nil, isShowingPlayer: Binding<Bool> = .constant(false)) {
    self.clientOverride = client
    self._isShowingPlayer = isShowingPlayer
  }

  private enum DownloadKind {
    case ebook
    case audiobook
  }

  private var configuredClient: RemoteLibraryServing? {
    if let clientOverride {
      return clientOverride
    }
    if let url = URL(string: userSettings.podibleRPCURL),
      userSettings.podibleRPCURL.isEmpty == false,
      let accessToken = podibleAuth.accessToken,
      accessToken.isEmpty == false
    {
      return PodibleClient(
        rpcURL: url,
        accessToken: accessToken
      )
    }
    return nil
  }

  private var remoteAssetBaseURLString: String {
    userSettings.podibleRPCURL
  }

  var body: some View {
    content(client: configuredClient)
      .miniPlaybackBarInset(player: player, isShowingPlayer: $isShowingPlayer)
      .navigationDestination(for: PodibleLibraryItem.self) { item in
        BookDetailView(
          item: item,
          localBook: localBooksById[item.id],
          actions: detailActions(item: item, client: configuredClient),
          isStreamOnly: isStreamOnly(item: item, localBook: localBooksById[item.id]),
          isShowingPlayer: $isShowingPlayer
        )
      }
  }

  private func detailActions(
    item: PodibleLibraryItem,
    client: RemoteLibraryServing?
  ) -> BookDetailActions {
    let localBook = localBooksById[item.id]
    let ebookStatus = item.ebookStatus ?? item.status
    let localEbookStatus = localEbookStatus(for: localBook, fallback: nil)
    let playback = item.playback ?? localBook.flatMap { self.playback(from: $0.playbackJSON) }
    let hasEbookAvailable =
      playback?.ebook != nil || isImportedMediaStatus(ebookStatus)
      || isImportedMediaStatus(localEbookStatus)
    let hasAudioPlayback = playback?.audio != nil
    let localPlaybackURL = localBook.flatMap { playbackURL(for: $0) }
    let localFileStatus = localBook?.files.first?.downloadStatus ?? .notStarted
    let isLocalDownloading = localDownloadingBookIDs.contains(localBook?.podibleId ?? item.id)
    let canStartLocalAudioDownload =
      localPlaybackURL == nil
      && hasAudioPlayback
      && localFileStatus != .completed
      && localFileStatus != .downloading
      && client != nil
      && isLocalDownloading == false

    var actions = BookDetailActions()

    if isLocalDownloading {
      let key = localBook?.podibleId ?? item.id
      let value = localDownloadProgressByBookID[key]
      actions.audioDownload = .inProgress(value)
    }

    if let localBook, let url = localPlaybackURL {
      actions.play = { startPlayback(for: localBook, url: url) }
    } else if hasAudioPlayback, let client {
      // No local file yet — stream over HTTP. The detail-view "Play"
      // button doesn't distinguish between local + streamed; this is an
      // implementation detail.
      actions.play = { startStreamingPlayback(for: item, client: client) }
    }
    if canStartLocalAudioDownload, let client {
      actions.downloadAudio = { startLocalDownload(for: item, client: client) }
    }

    if let client {
      actions.fetchAlternateCovers = {
        try await client.fetchAlternateCovers(bookID: item.id, limit: 50)
      }
      actions.setAlternateCover = { cover in
        let updated = try await client.setAlternateCover(bookID: item.id, coverID: cover.coverID)
        await MainActor.run {
          applyLibraryItemUpdate(updated)
        }
        return updated
      }
    }

    if hasEbookAvailable, let ebookPlayback = playback?.ebook, let client {
      actions.shareEbook = {
        Task {
          await startEbookDownload(
            playback: ebookPlayback, bookID: item.id, title: item.title, client: client)
        }
      }
      if userSettings.kindleEmailAddress.isEmpty == false {
        actions.emailToKindle = {
          Task {
            await startKindleExport(
              playback: ebookPlayback, bookID: item.id, title: item.title, client: client)
          }
        }
      }
    }

    if let client, client.supportsImportIssueReporting {
      actions.reportAudioIssue = {
        Task {
          await reportWrongImportedFile(bookID: item.id, library: .audio, client: client)
        }
      }
      actions.reportEbookIssue = {
        Task {
          await reportWrongImportedFile(bookID: item.id, library: .ebook, client: client)
        }
      }
    }

    if let client, client.supportsLibraryDelete {
      actions.deleteRemote = {
        Task {
          await deleteRemoteBook(item, using: client)
        }
      }
    }

    return actions
  }

  @MainActor
  private func applyLibraryItemUpdate(_ item: PodibleLibraryItem) {
    if let index = viewModel.libraryItems.firstIndex(where: { $0.id == item.id }) {
      viewModel.libraryItems[index] = item
    } else {
      viewModel.libraryItems.append(item)
    }

    let book = ensureLocalBook(for: item)
    let author = fetchOrCreateAuthor(name: item.author)
    updateLocalBook(book, with: item, author: author)
    if modelContext.hasChanges {
      saveModelContext()
    }
  }

  @MainActor
  private func persistRequestedBook(_ item: PodibleLibraryItem) {
    let book = ensureLocalBook(for: item)
    let author = fetchOrCreateAuthor(name: item.author)
    updateLocalBook(book, with: item, author: author)
    if modelContext.hasChanges {
      saveModelContext()
    }
  }

  @ViewBuilder
  private func content(client: RemoteLibraryServing?) -> some View {
    List {
      if client == nil {
        Text(
          "Sign in to Podible in Settings to access your remote library. Downloaded local audiobooks still work."
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

      let trimmedQuery = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedQuery.isEmpty {
        libraryListing(client: client)
      } else {
        searchListing(query: trimmedQuery, client: client)
      }

      if let syncFooterText {
        HStack {
          Spacer(minLength: 0)
          Text(syncFooterText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
          Spacer(minLength: 0)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
      }
    }
    #if os(iOS)
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(listBackgroundColor)
    #endif
    .navigationTitle("Library")
    .toolbar {
      #if os(macOS)
        ToolbarItem {
          Button(action: { startSync(using: client) }) {
            if isSyncSpinnerVisible {
              ProgressView()
            } else {
              Image(systemName: "arrow.triangle.2.circlepath")
            }
          }
          .disabled(client == nil || isSyncing)
          .help("Sync from backend")
        }
      #endif
    }
    .task(id: podibleAuth.accessToken ?? "") {
      guard let client else {
        viewModel.reset()
        return
      }
      await refresh(using: client)
      let remoteOnly = self.viewModel.libraryItems.filter { self.localBooksById[$0.id] == nil }
      if remoteOnly.isEmpty == false {
        for item in remoteOnly {
          applyLibraryItemUpdate(item)
        }
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else { return }
      guard let client else { return }
      Task {
        await refresh(using: client)
      }
    }
    .refreshable {
      guard let client else { return }
      await refresh(using: client)
    }
    .searchable(text: $viewModel.query, prompt: "Search")
    #if os(macOS)
      .onSubmit(of: .search) {
        guard let client else { return }
        Task {
          await viewModel.search(using: client)
        }
      }
    #else
      .onSubmit(of: .search) {
        guard let client else { return }
        Task {
          await viewModel.search(using: client)
        }
      }
    #endif
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
    Dictionary(uniqueKeysWithValues: localBooks.map { ($0.podibleId, $0) })
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

  private var syncFooterText: String? {
    let summary = lastSummary
    let added = summary.map { $0.insertedBooks + $0.insertedAuthors }
    let updated = summary.map { $0.updatedBooks + $0.updatedAuthors }

    var parts: [String] = []
    if let lastSync {
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .short
      let relative = formatter.localizedString(for: lastSync, relativeTo: .now)
      parts.append("Synced \(relative)")
    }
    if let added, let updated {
      parts.append("\(added) added")
      parts.append("\(updated) updated")
    }
    return parts.isEmpty ? nil : parts.joined(separator: "  •  ")
  }

  private var listBackgroundColor: Color {
    if colorScheme == .dark {
      return .black
    }
    #if os(iOS)
      return Color(uiColor: .systemBackground)
    #else
      return Color(nsColor: .windowBackgroundColor)
    #endif
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
    if localBooks.isEmpty {
      centeredListEmptyState {
        ContentUnavailableView(
          "No Books",
          systemImage: "tray",
          description: Text(
            client == nil
              ? "Add audiobooks to your local library to get started."
              : "Tap Sync to pull your remote library."
          )
        )
      }
    } else {
      ForEach(localBooks) { book in
        localLibraryRow(book, client: client)
      }
    }
  }

  @ViewBuilder
  private func searchListing(query: String, client: RemoteLibraryServing?) -> some View {
    let localMatches = filteredLocalBooks(query: query)
    let localIds = Set(localMatches.map(\.podibleId))
    let remoteResults = viewModel.searchResults.filter { localIds.contains($0.id) == false }

    if localMatches.isEmpty && remoteResults.isEmpty {
      centeredListEmptyState {
        ContentUnavailableView("No Results", systemImage: "magnifyingglass")
      }
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
            onRequested: { requested in
              persistRequestedBook(requested)
            },
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

  @ViewBuilder
  private func centeredListEmptyState<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack {
      Spacer(minLength: 0)
      HStack {
        Spacer(minLength: 0)
        content()
        Spacer(minLength: 0)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: 260)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  private func startSync(using client: RemoteLibraryServing?) {
    guard let client else { return }
    guard isSyncing == false else { return }
    Task {
      await refresh(using: client)
    }
  }

  @MainActor
  private func syncFromRemote(using client: RemoteLibraryServing) async {
    guard isSyncing == false else { return }
    isSyncing = true
    scheduleSyncSpinner()
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
    cancelSyncSpinner()
    isSyncing = false
  }

  @MainActor
  private func scheduleSyncSpinner() {
    syncSpinnerTask?.cancel()
    isSyncSpinnerVisible = false
    syncSpinnerTask = Task {
      try? await Task.sleep(nanoseconds: 200_000_000)
      guard Task.isCancelled == false else { return }
      await MainActor.run {
        guard isSyncing else { return }
        isSyncSpinnerVisible = true
      }
    }
  }

  @MainActor
  private func cancelSyncSpinner() {
    syncSpinnerTask?.cancel()
    syncSpinnerTask = nil
    isSyncSpinnerVisible = false
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

  @MainActor
  private func reportWrongImportedFile(
    bookID: String,
    library: PodibleLibraryMedia,
    client: RemoteLibraryServing
  ) async {
    downloadErrorMessage = nil
    do {
      purgeLocalDownloadedAssets(forBookID: bookID)
      try await client.reportImportIssue(bookID: bookID, library: library)
      viewModel.watchBookStatus(bookID: bookID, using: client)
      await refresh(using: client)
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func purgeLocalDownloadedAssets(forBookID bookID: String) {
    localDownloadingBookIDs.remove(bookID)
    localDownloadProgressByBookID[bookID] = nil

    guard let book = localBooksById[bookID] else { return }

    let localFileURLs: [URL] = book.files.compactMap { file in
      guard let relativePath = file.localRelativePath else { return nil }
      return try? LibraryStorage().url(forRelativePath: relativePath)
    }

    for url in localFileURLs where FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }

    let parentFolders = Set(localFileURLs.map { $0.deletingLastPathComponent() })
    for folder in parentFolders {
      guard FileManager.default.fileExists(atPath: folder.path) else { continue }
      let contents =
        (try? FileManager.default.contentsOfDirectory(
          at: folder,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )) ?? []
      if contents.isEmpty {
        try? FileManager.default.removeItem(at: folder)
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

    if modelContext.hasChanges {
      try? modelContext.save()
    }
  }

  @MainActor
  private func deleteRemoteBook(_ item: PodibleLibraryItem, using client: RemoteLibraryServing)
    async
  {
    downloadErrorMessage = nil
    do {
      try await client.deleteLibraryBook(bookID: item.id)
    } catch {
      guard shouldTreatMissingRemoteDeleteAsSuccess(error) else {
        downloadErrorMessage = error.localizedDescription
        return
      }
    }
    do {
      viewModel.forgetBook(bookID: item.id)
      try deleteLocalMirror(forBookID: item.id)
      await refresh(using: client)
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func deleteLocalMirror(forBookID bookID: String) throws {
    localDownloadingBookIDs.remove(bookID)
    localDownloadProgressByBookID[bookID] = nil

    guard let book = localBooksById[bookID] else { return }

    let fileRows = book.files
    let localFileURLs: [URL] = fileRows.compactMap { file in
      guard let relativePath = file.localRelativePath else { return nil }
      return try? LibraryStorage().url(forRelativePath: relativePath)
    }

    // Best-effort local file cleanup; the database is the source of truth for what is shown.
    for url in localFileURLs where FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }

    // Remove now-empty parent folders (usually KindlingLibrary/<bookId>/).
    let parentFolders = Set(localFileURLs.map { $0.deletingLastPathComponent() })
    for folder in parentFolders {
      guard FileManager.default.fileExists(atPath: folder.path) else { continue }
      let contents =
        (try? FileManager.default.contentsOfDirectory(
          at: folder,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )) ?? []
      if contents.isEmpty {
        try? FileManager.default.removeItem(at: folder)
      }
    }

    if let localState = book.localState {
      modelContext.delete(localState)
    }
    for file in fileRows {
      modelContext.delete(file)
    }
    modelContext.delete(book)

    if modelContext.hasChanges {
      try modelContext.save()
    }
  }

  private func shouldTreatMissingRemoteDeleteAsSuccess(_ error: Error) -> Bool {
    let message = error.localizedDescription.lowercased()
    return message.contains("not found") || message.contains("id not found")
  }

  private func startEbookDownload(
    playback: PodiblePlaybackEbook,
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
      let localURL = try await client.downloadEpub(playback: playback) { value in
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
    playback: PodiblePlaybackEbook,
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
      let localURL = try await client.downloadEpub(playback: playback) { value in
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
    playback: PodiblePlaybackAudio,
    bookID: String,
    title: String,
    client: RemoteLibraryServing
  ) async {
    downloadingBookID = bookID
    downloadKind = .audiobook
    downloadProgress = 0
    downloadErrorMessage = nil
    do {
      let localURL = try await client.downloadAudiobook(playback: playback) { value in
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

  private func rowSummary(item: PodibleLibraryItem, localBook: LibraryBook?) -> String? {
    let raw = item.summary?.isEmpty == false ? item.summary : localBook?.summary
    guard let raw, raw.isEmpty == false else { return nil }
    let lines =
      raw
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.isEmpty == false }
      .map(compactMarkdownExcerptLine(_:))

    let summary =
      lines
      .filter { $0.isEmpty == false }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return summary.isEmpty ? nil : summary
  }

  private func compactMarkdownExcerptLine(_ line: String) -> String {
    var value = line

    // Trim common markdown prefixes that waste horizontal space in compact rows.
    value = value.replacingOccurrences(
      of: #"^\s{0,3}(#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s+)"#,
      with: "",
      options: .regularExpression
    )

    // Remove emphasis and inline-code fences while keeping the text.
    value = value.replacingOccurrences(of: "**", with: "")
    value = value.replacingOccurrences(of: "__", with: "")
    value = value.replacingOccurrences(of: "*", with: "")
    value = value.replacingOccurrences(of: "_", with: "")
    value = value.replacingOccurrences(of: "`", with: "")

    // Flatten markdown links to just their visible labels.
    value = value.replacingOccurrences(
      of: #"\[([^\]]+)\]\([^)]+\)"#,
      with: "$1",
      options: .regularExpression
    )

    // Collapse extra whitespace introduced by stripping markdown markers.
    value = value.replacingOccurrences(
      of: #"\s+"#,
      with: " ",
      options: .regularExpression
    )

    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func bookMetricsText(item: PodibleLibraryItem, localBook: LibraryBook?) -> String? {
    let runtimeSeconds = item.runtimeSeconds ?? localBook?.runtimeSeconds
    let wordCount = item.wordCount ?? localBook?.wordCount
    var parts: [String] = []
    if let runtimeSeconds, runtimeSeconds > 0 {
      parts.append(formatRuntime(seconds: runtimeSeconds))
    }
    if let wordCount, wordCount > 0 {
      parts.append("\(formatWordCount(wordCount)) words")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " • ")
  }

  private func formatRuntime(seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 {
      return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    return "\(minutes)m"
  }

  private func formatWordCount(_ count: Int) -> String {
    if count >= 1000 {
      let thousands = Double(count) / 1000.0
      return String(format: thousands >= 100 ? "%.0fk" : "%.1fk", thousands)
    }
    return "\(count)"
  }

  private func libraryRow(
    _ item: PodibleLibraryItem,
    localBook: LibraryBook?,
    client: RemoteLibraryServing?
  ) -> some View {
    let rowProgressPercent = item.fullPseudoProgress
    let rowIsAcquiring = rowProgressPercent.map { $0 < 100 } ?? false

    return ZStack {
      // Invisible NavigationLink provides the value-based push but no visual
      // chevron — that lives inside the row's HStack below so the divider can
      // extend past it.
      NavigationLink(value: item) {
        EmptyView()
      }
      .opacity(0)

      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 12) {
          bookCoverView(
            title: item.title,
            author: item.author,
            url: remoteLibraryAssetURL(
              baseURLString: remoteAssetBaseURLString,
              path: item.bookImagePath,
              versionToken: item.updatedAt.map { String(Int($0.timeIntervalSince1970)) }
            ),
            rpcURLString: userSettings.podibleRPCURL,
            accessToken: podibleAuth.accessToken
          )
          VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
              .font(.title3.weight(.semibold))
              .lineLimit(2)
            Text(item.author)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            HStack(spacing: 6) {
              if let metricsText = bookMetricsText(item: item, localBook: localBook) {
                Text(metricsText)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .monospacedDigit()
              }
              if isStreamOnly(item: item, localBook: localBook) {
                Image(systemName: "cloud")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .accessibilityLabel("Not downloaded")
              }
            }
            if let summary = rowSummary(item: item, localBook: localBook) {
              Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.top, 2)
            }
          }
          Spacer(minLength: 0)
          remoteLibraryStatusCluster(
            item: item
          )
          Image(systemName: "chevron.forward")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.trailing, 4)
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
      .background {
        remoteLibraryRowProgressBackground(
          percent: rowProgressPercent,
          isAcquiring: rowIsAcquiring
        )
      }
    }
    .listRowInsets(EdgeInsets())
    // Cover (88pt) + leading row inset (16pt) + spacing (12pt) = 116pt
    // Aligns the divider's leading edge with the title text. The trailing
    // edge runs to the row's content edge, with the manually-drawn chevron
    // sitting inside the row's HStack so it falls under the divider span.
    .alignmentGuide(.listRowSeparatorLeading) { _ in 116 }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if let client, client.supportsLibraryDelete {
        Button(role: .destructive) {
          Task {
            await deleteRemoteBook(item, using: client)
          }
        } label: {
          Label("Delete", systemImage: "trash")
        }
      }
      if let client, client.supportsImportIssueReporting {
        Button {
          Task {
            await reportWrongImportedFile(bookID: item.id, library: .audio, client: client)
          }
        } label: {
          Label("Audio Issue", systemImage: "exclamationmark.triangle")
        }
        .tint(.orange)

        Button {
          Task {
            await reportWrongImportedFile(bookID: item.id, library: .ebook, client: client)
          }
        } label: {
          Label("eBook Issue", systemImage: "exclamationmark.triangle")
        }
        .tint(.orange)
      }
    }
    .contextMenu {
      libraryRowContextMenu(item: item, client: client)
    }
  }

  /// Long-press menu on a library row. Mirrors the action set in the
  /// detail view so the row and `BookDetailView` stay in sync.
  @ViewBuilder
  private func libraryRowContextMenu(
    item: PodibleLibraryItem,
    client: RemoteLibraryServing?
  ) -> some View {
    let menuActions = detailActions(item: item, client: client)
    if let play = menuActions.play {
      Button(action: play) {
        Label("Play", systemImage: "play.fill")
      }
    } else if let downloadAudio = menuActions.downloadAudio {
      Button(action: downloadAudio) {
        Label("Download Audiobook", systemImage: "arrow.down.circle")
      }
    }
    if let shareEbook = menuActions.shareEbook {
      Button(action: shareEbook) {
        Label("Share eBook", systemImage: "square.and.arrow.up")
      }
    }
    if let emailToKindle = menuActions.emailToKindle {
      Button(action: emailToKindle) {
        Label("Send to Kindle", systemImage: "paperplane")
      }
    }
    if let reportAudioIssue = menuActions.reportAudioIssue {
      Button(action: reportAudioIssue) {
        Label("Report Audio Issue", systemImage: "exclamationmark.triangle")
      }
    }
    if let reportEbookIssue = menuActions.reportEbookIssue {
      Button(action: reportEbookIssue) {
        Label("Report eBook Issue", systemImage: "exclamationmark.triangle")
      }
    }
    if let deleteRemote = menuActions.deleteRemote {
      Button(role: .destructive, action: deleteRemote) {
        Label("Delete", systemImage: "trash")
      }
    }
  }

  @ViewBuilder
  private func localLibraryRow(_ book: LibraryBook, client: RemoteLibraryServing?) -> some View {
    libraryRow(localProxyItem(for: book), localBook: book, client: client)
  }

  private func localProxyItem(for book: LibraryBook) -> PodibleLibraryItem {
    let ebookStatus = localEbookStatus(for: book, fallback: nil)
    let audioStatus = parseAudioStatus(from: book)
    let overallStatus = ebookStatus ?? audioStatus
    return PodibleLibraryItem(
      id: book.podibleId,
      openLibraryWorkID: book.openLibraryWorkID,
      title: book.title,
      author: book.author?.name ?? "Unknown Author",
      summary: book.summary,
      status: overallStatus,
      ebookStatus: ebookStatus,
      audioStatus: audioStatus,
      bookAdded: book.addedAt,
      updatedAt: book.updatedAt,
      fullPseudoProgress: nil,
      bookImagePath: book.coverURLString,
      wordCount: book.wordCount,
      runtimeSeconds: book.runtimeSeconds,
      playback: playback(from: book.playbackJSON)
    )
  }

  @ViewBuilder
  private func statusLine(
    status: DownloadStatus,
    progress: Double?,
    audioStatus: PodibleLibraryItemStatus
  ) -> some View {
    HStack(spacing: 6) {
      Text("Audio: \(audioStatus.rawValue)")
      if let progress {
        ProgressView(value: progress)
          .frame(maxWidth: 120)
      }
    }
    .foregroundStyle(.secondary)
    .font(.caption)
  }

  @ViewBuilder
  private func localDownloadButton(
    for book: LibraryBook,
    status: DownloadStatus,
    audioStatus: PodibleLibraryItemStatus,
    client: RemoteLibraryServing?
  ) -> some View {
    let isDownloading = localDownloadingBookIDs.contains(book.podibleId)
    let canDownload = playback(from: book.playbackJSON)?.audio != nil && client != nil
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
    let canDownload = isImportedMediaStatus(audioStatus) && client != nil
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
    let resumeID = playbackResumeID(for: book)
    player.load(
      url: url,
      resumeID: resumeID,
      title: book.title,
      author: book.author?.name,
      description: book.summary,
      artworkURL: remoteLibraryAssetURL(
        baseURLString: remoteAssetBaseURLString,
        path: book.coverURLString,
        versionToken: book.updatedAt.map { String(Int($0.timeIntervalSince1970)) }
      ),
      artworkAccessToken: podibleAuth.accessToken
    )
    if let client = configuredClient {
      let playbackAudio = playback(from: book.playbackJSON)?.audio
      Task {
        await loadPlaybackMetadata(playback: playbackAudio, resumeID: resumeID, client: client)
      }
    }
    player.play()
    isShowingPlayer = true
  }

  @MainActor
  private func startStreamingPlayback(
    for item: PodibleLibraryItem,
    client: RemoteLibraryServing
  ) {
    isShowingPlayer = true
    let resumeID = streamingResumeID(for: item)
    Task {
      do {
        guard
          let playbackAudio =
            item.playback?.audio
            ?? localBooksById[item.id].flatMap({ self.playback(from: $0.playbackJSON)?.audio })
        else {
          downloadErrorMessage = "Audiobook not available for streaming."
          return
        }
        let httpURL = try client.audiobookStreamURL(playback: playbackAudio)
        await MainActor.run {
          player.loadStreaming(
            httpURL: httpURL,
            accessToken: podibleAuth.accessToken,
            resumeID: resumeID,
            title: item.title,
            author: item.author,
            description: item.summary,
            artworkURL: remoteLibraryAssetURL(
              baseURLString: remoteAssetBaseURLString,
              path: item.bookImagePath,
              versionToken: item.updatedAt.map { String(Int($0.timeIntervalSince1970)) }),
            artworkAccessToken: podibleAuth.accessToken
          )
          player.play()
          // Server-side chapters/transcript still available — fire and forget.
          Task {
            await loadPlaybackMetadata(playback: playbackAudio, resumeID: resumeID, client: client)
          }
        }
      } catch {
        downloadErrorMessage = "Streaming failed: \(error.localizedDescription)"
      }
    }
  }

  private func streamingResumeID(for item: PodibleLibraryItem) -> String {
    let manifestationID =
      item.playback?.audio?.manifestationId
      ?? localBooksById[item.id].flatMap {
        self.playback(from: $0.playbackJSON)?.audio?.manifestationId
      }
    return manifestationResumeID(
      bookIdentity: item.openLibraryWorkID,
      fallback: item.id,
      manifestationID: manifestationID
    )
  }

  @MainActor
  private func loadPlaybackMetadata(
    playback: PodiblePlaybackAudio?,
    resumeID: String,
    client: RemoteLibraryServing
  ) async {
    guard let playback else {
      player.applyRemoteTranscript(nil, for: resumeID)
      player.applyRemoteChapters([], for: resumeID)
      return
    }
    do {
      async let transcript = client.fetchTranscript(playback: playback)
      async let chapters = client.fetchChapters(playback: playback)
      let (resolvedTranscript, resolvedChapters) = try await (transcript, chapters)
      player.applyRemoteTranscript(resolvedTranscript, for: resumeID)
      player.applyRemoteChapters(resolvedChapters, for: resumeID)
    } catch {
      player.applyRemoteTranscript(nil, for: resumeID)
    }
  }

  private func playbackResumeID(for book: LibraryBook) -> String {
    return manifestationResumeID(
      bookIdentity: book.openLibraryWorkID,
      fallback: book.podibleId,
      manifestationID: playback(from: book.playbackJSON)?.audio?.manifestationId
    )
  }

  private func manifestationResumeID(
    bookIdentity: String?,
    fallback: String,
    manifestationID: Int?
  ) -> String {
    let base: String
    if let bookIdentity, bookIdentity.isEmpty == false {
      base = bookIdentity
    } else {
      base = fallback
    }
    guard let manifestationID else { return base }
    return "\(base)#manifestation-\(manifestationID)"
  }

  @MainActor
  private func startLocalDownload(for book: LibraryBook, client: RemoteLibraryServing) {
    guard localDownloadingBookIDs.contains(book.podibleId) == false else { return }
    localDownloadingBookIDs.insert(book.podibleId)
    localDownloadProgressByBookID[book.podibleId] = 0
    downloadErrorMessage = nil

    let audioStatus = parseAudioStatus(from: book)
    guard let playbackAudio = playback(from: book.playbackJSON)?.audio else {
      downloadErrorMessage = "Audiobook playback URL unavailable."
      localDownloadingBookIDs.remove(book.podibleId)
      localDownloadProgressByBookID[book.podibleId] = nil
      return
    }

    Task { @MainActor in
      let fileRecord = ensureFileRecord(for: book)
      fileRecord.downloadStatus = .downloading
      fileRecord.lastError = nil
      fileRecord.bytesDownloaded = 0

      do {
        let tempURL = try await client.downloadAudiobook(playback: playbackAudio) { value in
          Task { @MainActor in
            localDownloadProgressByBookID[book.podibleId] = value
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
        try LocalAudiobookCache().enforceLimit(modelContext: modelContext, keeping: book.podibleId)
      } catch {
        fileRecord.downloadStatus = .failed
        fileRecord.lastError = error.localizedDescription
        try? modelContext.save()
        downloadErrorMessage =
          "Download failed (AudioStatus: \(audioStatus.rawValue)): \(error.localizedDescription)"
      }

      localDownloadingBookIDs.remove(book.podibleId)
      localDownloadProgressByBookID[book.podibleId] = nil
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

  private func localEbookStatus(
    for book: LibraryBook?,
    fallback: PodibleLibraryItemStatus?
  ) -> PodibleLibraryItemStatus? {
    if let book, let raw = book.bookStatusRaw,
      let status = PodibleLibraryItemStatus(rawValue: raw)
    {
      return status
    }
    return fallback
  }

  private func parseAudioStatus(from book: LibraryBook) -> PodibleLibraryItemStatus {
    audioStatus(for: book, fallback: nil)
  }

  private func isImportedMediaStatus(_ status: PodibleLibraryItemStatus?) -> Bool {
    status == .have
  }

  /// True if the book is available on the server (audio importable) but
  /// not yet present locally. Used to surface a cloud indicator on rows
  /// and the detail page so users can tell stream-only from downloaded.
  private func isStreamOnly(item: PodibleLibraryItem, localBook: LibraryBook?) -> Bool {
    let playback = item.playback ?? localBook.flatMap { self.playback(from: $0.playbackJSON) }
    guard playback?.audio != nil else { return false }
    return localBook.flatMap { playbackURL(for: $0) } == nil
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
      podibleId: "\(book.podibleId):audio",
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
    let state = LocalBookState(bookPodibleId: book.podibleId, book: book)
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
      podibleId: item.id,
      openLibraryWorkID: item.openLibraryWorkID,
      title: item.title,
      summary: item.summary,
      coverURLString: item.bookImagePath,
      runtimeSeconds: item.runtimeSeconds,
      wordCount: item.wordCount,
      addedAt: item.bookAdded,
      updatedAt: latestLibraryDate(for: item),
      seriesIndex: nil,
      bookStatusRaw: (item.ebookStatus ?? item.status).rawValue,
      audioStatusRaw: item.audioStatus?.rawValue,
      playbackJSON: playbackData(for: item.playback),
      author: author,
      series: nil
    )
    modelContext.insert(book)
    if modelContext.hasChanges {
      saveModelContext()
    }
    return book
  }

  @MainActor
  private func fetchOrCreateAuthor(name: String) -> Author {
    let key = normalizeAuthorKey(name)
    let descriptor = FetchDescriptor<Author>(
      predicate: #Predicate { $0.podibleId == key }
    )
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

  @MainActor
  private func updateLocalBook(
    _ book: LibraryBook,
    with item: PodibleLibraryItem,
    author: Author
  ) {
    var updated = false
    if book.openLibraryWorkID != item.openLibraryWorkID {
      book.openLibraryWorkID = item.openLibraryWorkID
      updated = true
    }
    if book.title != item.title {
      book.title = item.title
      updated = true
    }
    if book.summary != item.summary {
      book.summary = item.summary
      updated = true
    }
    if book.coverURLString != item.bookImagePath {
      book.coverURLString = item.bookImagePath
      updated = true
    }
    if book.runtimeSeconds != item.runtimeSeconds {
      book.runtimeSeconds = item.runtimeSeconds
      updated = true
    }
    if book.wordCount != item.wordCount {
      book.wordCount = item.wordCount
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
    let ebookRaw = (item.ebookStatus ?? item.status).rawValue
    if book.bookStatusRaw != ebookRaw {
      book.bookStatusRaw = ebookRaw
      updated = true
    }
    if book.audioStatusRaw != item.audioStatus?.rawValue {
      book.audioStatusRaw = item.audioStatus?.rawValue
      updated = true
    }
    if let itemPlayback = item.playback {
      let nextPlaybackJSON = playbackData(for: itemPlayback)
      if book.playbackJSON != nextPlaybackJSON {
        book.playbackJSON = nextPlaybackJSON
        updated = true
      }
    }
    if updated, modelContext.hasChanges {
      saveModelContext()
    }
  }

  private func playbackData(for playback: PodiblePlayback?) -> Data? {
    guard let playback else { return nil }
    return try? JSONEncoder().encode(playback)
  }

  private func playback(from data: Data?) -> PodiblePlayback? {
    guard let data else { return nil }
    return try? JSONDecoder().decode(PodiblePlayback.self, from: data)
  }

  @MainActor
  private func saveModelContext() {
    do {
      try modelContext.save()
    } catch {
      syncErrorMessage = "Failed to save library cache: \(error.localizedDescription)"
    }
  }

  private func normalizeAuthorKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func latestLibraryDate(for item: PodibleLibraryItem) -> Date? {
    item.updatedAt
  }
}

typealias RemoteLibraryView = PodibleLibraryView

extension PodibleLibraryDownloadProgress {
  var combinedProgressPercent: Int? {
    var values: [Int] = []
    if ebookSeen || ebookFinished {
      values.append(ebookFinished ? 100 : ebook)
    }
    if audiobookSeen || audiobookFinished {
      values.append(audiobookFinished ? 100 : audiobook)
    }
    guard values.isEmpty == false else { return nil }
    let total = values.reduce(0, +)
    return Int((Double(total) / Double(values.count)).rounded())
  }

  var hasCombinedProgress: Bool {
    combinedProgressPercent != nil
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
  item: PodibleLibraryItem
) -> some View {
  let isProgressIncomplete = (item.fullPseudoProgress ?? 100) < 100

  Group {
    if isProgressIncomplete {
      remoteLibraryPendingIndicator()
    }
  }
}

@ViewBuilder
func remoteLibraryCombinedProgressBar(percent: Int) -> some View {
  let clamped = max(0, min(100, percent))
  HStack(spacing: 6) {
    Image(systemName: "arrow.down.circle")
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.secondary)
    ProgressView(value: Double(clamped), total: 100)
      .frame(width: 64)
      .controlSize(.small)
    Text("\(clamped)%")
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.secondary)
  }
}

@ViewBuilder
func remoteLibraryRowProgressBackground(
  percent: Int?,
  isAcquiring: Bool
) -> some View {
  let clamped = percent.map { max(0, min(100, $0)) }
  GeometryReader { proxy in
    let width = proxy.size.width
    let fillWidth = clamped.map { width * CGFloat($0) / 100.0 } ?? 0
    ZStack(alignment: .leading) {
      if let clamped, isAcquiring {
        Rectangle()
          .fill(.blue.opacity(0.14))
          .frame(width: fillWidth, alignment: .leading)
          .animation(.easeInOut(duration: 0.5), value: clamped)
      }
    }
  }
  .allowsHitTesting(false)
}

@ViewBuilder
func remoteLibraryPendingIndicator() -> some View {
  HStack(spacing: 6) {
    Image(systemName: "arrow.triangle.2.circlepath")
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.secondary)
      .symbolEffect(.pulse.byLayer, options: .repeating)
    Text("Acquiring")
      .font(.caption2)
      .foregroundStyle(.secondary)
  }
  .padding(4)
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
func bookCoverView(
  title: String,
  author: String,
  url: URL?,
  rpcURLString: String,
  accessToken: String?
) -> some View {
  if let url {
    AuthenticatedRemoteImage(
      url: url,
      rpcURLString: rpcURLString,
      accessToken: accessToken
    ) {
      bookCoverPlaceholder(title: title, author: author)
    }
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
  remoteLibraryAssetURL(baseURLString: baseURLString, path: path, versionToken: nil)
}

func remoteLibraryAssetURL(baseURLString: String, path: String?, versionToken: String?) -> URL? {
  guard let path else { return nil }
  let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.lowercased().hasSuffix("nocover.png") {
    return nil
  }
  if let absolute = URL(string: trimmed), absolute.scheme != nil {
    return versionedAssetURL(absolute, versionToken: versionToken)
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
  return versionedAssetURL(url, versionToken: versionToken)
}

private func versionedAssetURL(_ url: URL, versionToken: String?) -> URL {
  guard let versionToken, versionToken.isEmpty == false else { return url }
  guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
  var items = components.queryItems ?? []
  items.removeAll { $0.name == "v" }
  items.append(URLQueryItem(name: "v", value: versionToken))
  components.queryItems = items
  return components.url ?? url
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
      .environmentObject(AudioPlayerController())
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
