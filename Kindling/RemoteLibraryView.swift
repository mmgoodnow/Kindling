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
  @State private var isSyncSpinnerVisible = false
  @State private var syncSpinnerTask: Task<Void, Never>?
  @State private var syncErrorMessage: String?
  @State private var localDownloadProgressByBookID: [String: Double] = [:]
  @State private var localDownloadingBookIDs: Set<String> = []
  @StateObject private var player = AudioPlayerController()
  @State private var isShowingPlayer = false
  @State private var isShowingWipeLocalLibraryConfirmation = false
  @State private var isWipingLocalLibrary = false
  @State private var pendingReportIssueBook: PendingReportIssueBook?

  let clientOverride: RemoteLibraryServing?

  init(client: RemoteLibraryServing? = nil) {
    self.clientOverride = client
  }

  private enum DownloadKind {
    case ebook
    case audiobook
  }

  private struct PendingReportIssueBook {
    let id: String
    let title: String
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

      if isWipingLocalLibrary {
        HStack(spacing: 8) {
          ProgressView()
          Text("Wiping local library…")
            .foregroundStyle(.secondary)
        }
      } else {
        let trimmedQuery = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
          libraryListing(client: client)
        } else {
          searchListing(query: trimmedQuery, client: client)
        }
      }

      if let syncFooterText, isWipingLocalLibrary == false {
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
      .listStyle(.grouped)
    #endif
    .navigationTitle("Library")
    .toolbar {
      ToolbarItem {
        Button(action: { startSync(using: client) }) {
          if isSyncSpinnerVisible {
            ProgressView()
          } else {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
        }
        .disabled(client == nil || isSyncing || isWipingLocalLibrary)
        .help("Sync from backend")
      }
      ToolbarItem {
        Button(role: .destructive) {
          isShowingWipeLocalLibraryConfirmation = true
        } label: {
          Image(systemName: "trash")
        }
        .disabled(
          isSyncing || isWipingLocalLibrary || downloadingBookID != nil
            || localDownloadingBookIDs.isEmpty == false
        )
        .help("Wipe local library cache and downloads")
      }
    }
    .confirmationDialog(
      "Wipe Local Library?",
      isPresented: $isShowingWipeLocalLibraryConfirmation,
      titleVisibility: .visible
    ) {
      Button("Wipe Local Library", role: .destructive) {
        wipeLocalLibrary()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Removes local SwiftData library records, sync state, and downloaded local files. The remote podible library is not changed."
      )
    }
    .confirmationDialog(
      "Report Issue",
      isPresented: Binding(
        get: { pendingReportIssueBook != nil },
        set: { isPresented in
          if isPresented == false {
            pendingReportIssueBook = nil
          }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Audio Issue") {
        submitReportIssue(library: .audio)
      }
      Button("eBook Issue") {
        submitReportIssue(library: .ebook)
      }
      Button("Cancel", role: .cancel) {
        pendingReportIssueBook = nil
      }
    } message: {
      if let pendingReportIssueBook {
        Text("What kind of issue is wrong for “\(pendingReportIssueBook.title)”?")
      }
    }
    .onAppear {
      guard let client, isWipingLocalLibrary == false else { return }
      Task {
        if localBooks.isEmpty || lastSync == nil {
          await syncFromRemote(using: client)
        }
        await viewModel.loadLibraryItems(using: client)
      }
    }
    .refreshable {
      guard let client, isWipingLocalLibrary == false else { return }
      await refresh(using: client)
    }
    .searchable(text: $viewModel.query, prompt: "Search")
    #if os(macOS)
      .onSubmit(of: .search) {
        guard let client, isWipingLocalLibrary == false else { return }
        Task {
          await viewModel.search(using: client)
        }
      }
    #else
      .onSubmit(of: .search) {
        guard let client, isWipingLocalLibrary == false else { return }
        Task {
          await viewModel.search(using: client)
        }
      }
    #endif
    .onChange(of: viewModel.query) { _, newValue in
      searchTask?.cancel()
      guard isWipingLocalLibrary == false else { return }
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
      await viewModel.loadLibraryItems(using: client)
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func submitReportIssue(library: PodibleLibraryMedia) {
    guard let pendingReportIssueBook else { return }
    guard let client = configuredClient, client.supportsImportIssueReporting else {
      self.pendingReportIssueBook = nil
      return
    }
    self.pendingReportIssueBook = nil
    Task {
      await reportWrongImportedFile(
        bookID: pendingReportIssueBook.id,
        library: library,
        client: client
      )
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

  @MainActor
  private func wipeLocalLibrary() {
    guard isWipingLocalLibrary == false else { return }
    isWipingLocalLibrary = true
    player.stop()
    isShowingPlayer = false
    isShowingShareSheet = false
    shareURL = nil
    isShowingKindleExporter = false
    kindleExportFile = nil
    downloadErrorMessage = nil
    syncErrorMessage = nil
    localDownloadProgressByBookID.removeAll()
    localDownloadingBookIDs.removeAll()
    viewModel.reset()

    Task { @MainActor in
      // Let SwiftUI re-render without local rows before deleting SwiftData objects.
      await Task.yield()
      do {
        try removeLocalLibraryFiles()
        try deleteLocalLibraryRows()
        try modelContext.save()
      } catch {
        syncErrorMessage = "Failed to wipe local library: \(error.localizedDescription)"
      }
      isWipingLocalLibrary = false
    }
  }

  private func deleteLocalLibraryRows() throws {
    try deleteAll(LibrarySyncState.self)
    try deleteAll(LibraryBook.self)
    // LibraryBook.files is nullify, so file rows are cleaned up explicitly after books are gone.
    try deleteAll(LibraryBookFile.self)
    try deleteAll(LocalBookState.self)
    try deleteAll(Series.self)
    try deleteAll(Author.self)
  }

  private func deleteAll<T: PersistentModel>(_ type: T.Type) throws {
    let rows = try modelContext.fetch(FetchDescriptor<T>())
    for row in rows {
      modelContext.delete(row)
    }
  }

  private func removeLocalLibraryFiles() throws {
    let fm = FileManager.default
    for url in localLibraryWipeTargets(fileManager: fm) {
      if fm.fileExists(atPath: url.path) {
        try fm.removeItem(at: url)
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

  private func libraryRow(
    _ item: PodibleLibraryItem,
    localBook: LibraryBook?,
    client: RemoteLibraryServing?
  ) -> some View {
    let rowProgressPercent = item.fullPseudoProgress
    let rowIsAcquiring = rowProgressPercent.map { $0 < 100 } ?? false

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
          rowControls(
            item: item,
            localBook: localBook,
            client: client
          )
          localAudioControls(
            item: item,
            localBook: localBook,
            client: client
          )
        }
        Spacer(minLength: 0)
        remoteLibraryStatusCluster(
          item: item
        )
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
    .listRowInsets(EdgeInsets())
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
          pendingReportIssueBook = PendingReportIssueBook(id: item.id, title: item.title)
        } label: {
          Label("Report Issue", systemImage: "exclamationmark.triangle")
        }
        .tint(.orange)
      }
    }
  }

  @ViewBuilder
  private func rowControls(
    item: PodibleLibraryItem,
    localBook: LibraryBook?,
    client: RemoteLibraryServing?
  ) -> some View {
    let hasRemoteClient = client != nil
    let ebookStatus = item.ebookStatus ?? item.status
    let localEbookStatus = localEbookStatus(for: localBook, fallback: nil)
    let hasEbookAvailable =
      isImportedMediaStatus(ebookStatus)
      || isImportedMediaStatus(localEbookStatus)
    let canShareEbook = hasRemoteClient && hasEbookAvailable
    let canKindleExport =
      canShareEbook && userSettings.kindleEmailAddress.isEmpty == false
    let effectiveAudioStatus = item.audioStatus ?? audioStatus(for: localBook, fallback: nil)
    let localFileStatus = localBook?.files.first?.downloadStatus ?? .notStarted
    let localPlaybackURL = localBook.flatMap { playbackURL(for: $0) }
    let isLocalDownloading = localDownloadingBookIDs.contains(localBook?.llId ?? item.id)
    let canStartLocalAudioDownload =
      localPlaybackURL == nil
      && isImportedMediaStatus(effectiveAudioStatus)
      && localFileStatus != .completed
      && localFileStatus != .downloading
      && hasRemoteClient
      && isLocalDownloading == false
    let controls = HStack(spacing: 8) {
      trailingControlButton(
        label: "Share eBook",
        systemName: "square.and.arrow.up",
        isEnabled: canShareEbook,
        action: {
          guard let client else { return }
          Task {
            await startEbookDownload(
              bookID: item.id,
              title: item.title,
              client: client
            )
          }
        }
      )
      trailingControlButton(
        label: localPlaybackURL == nil ? "Download or Play Audiobook" : "Play Audiobook",
        systemName: "play.fill",
        isEnabled: (localPlaybackURL != nil && localBook != nil) || canStartLocalAudioDownload,
        action: {
          if let localBook, let localPlaybackURL {
            startPlayback(for: localBook, url: localPlaybackURL)
            return
          }
          guard let client else { return }
          startLocalDownload(for: item, client: client)
        }
      )
      trailingControlButton(
        label: "Email to Kindle",
        systemName: "paperplane",
        isEnabled: canKindleExport,
        action: {
          guard let client else { return }
          Task {
            await startKindleExport(
              bookID: item.id,
              title: item.title,
              client: client
            )
          }
        }
      )
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
        .foregroundStyle(isEnabled ? .accent : .secondary)
        .imageScale(.large)
        .frame(width: 44, height: 44, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.4)
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
        .foregroundStyle(isEnabled ? .accent : .secondary)
        .frame(width: 44, height: 44, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.4)
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
    _ = client
    let progress = localDownloadProgressByBookID[item.id]

    return Group {
      if let progress {
        ProgressView(value: progress)
          .frame(maxWidth: 120)
      }
    }
  }

  @ViewBuilder
  private func localLibraryRow(_ book: LibraryBook, client: RemoteLibraryServing?) -> some View {
    libraryRow(localProxyItem(for: book), localBook: book, client: nil)
  }

  private func localProxyItem(for book: LibraryBook) -> PodibleLibraryItem {
    let ebookStatus = localEbookStatus(for: book, fallback: nil)
    let audioStatus = parseAudioStatus(from: book)
    let overallStatus = ebookStatus ?? audioStatus
    return PodibleLibraryItem(
      id: book.llId,
      title: book.title,
      author: book.author?.name ?? "Unknown Author",
      status: overallStatus,
      ebookStatus: ebookStatus,
      audioStatus: audioStatus,
      bookAdded: book.addedAt,
      updatedAt: book.updatedAt,
      fullPseudoProgress: nil,
      bookImagePath: book.coverURLString
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
    let isDownloading = localDownloadingBookIDs.contains(book.llId)
    let canDownload = isImportedMediaStatus(audioStatus) && client != nil
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

  @MainActor
  private func startLocalDownload(for book: LibraryBook, client: RemoteLibraryServing) {
    guard localDownloadingBookIDs.contains(book.llId) == false else { return }
    localDownloadingBookIDs.insert(book.llId)
    localDownloadProgressByBookID[book.llId] = 0
    downloadErrorMessage = nil

    let audioStatus = parseAudioStatus(from: book)
    guard isImportedMediaStatus(audioStatus) else {
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
      bookStatusRaw: (item.ebookStatus ?? item.status).rawValue,
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
    let ebookRaw = (item.ebookStatus ?? item.status).rawValue
    if book.bookStatusRaw != ebookRaw {
      book.bookStatusRaw = ebookRaw
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
