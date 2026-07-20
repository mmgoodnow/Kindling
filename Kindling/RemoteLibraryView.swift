import Foundation
import KindlingUI
import Kingfisher
import SwiftData
import SwiftUI

func relatedBookIdentity(title: String, author: String) -> String {
  [title, author]
    .map {
      $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    }
    .joined(separator: "|")
}

func belongsInNewOnPodible(isFavorite: Bool, isRead: Bool) -> Bool {
  isFavorite == false && isRead == false
}

func belongsInContinueReading(progress: Double?, isRead: Bool) -> Bool {
  guard let progress else { return false }
  return progress > 0 && progress < ReadProgressPolicy.completionThreshold && isRead == false
}

func belongsInTBR(isFavorite: Bool, isRead: Bool, progress: Double?) -> Bool {
  isFavorite && isRead == false && (progress ?? 0) == 0
}

enum PodibleLibraryScreenMode {
  case home
  case library
  case favorites

  var title: String {
    switch self {
    case .home:
      "Home"
    case .library:
      "Library"
    case .favorites:
      "Favorites"
    }
  }
}

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
  @Query private var bookActivities: [BookActivityState]
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
  @State private var artworkPalettesByURL: [String: ArtworkPalette] = [:]
  @State private var artworkPaletteKeysBeingSampled = Set<String>()
  @State private var relatedBooksResults: [BookGroupRoute: PodibleRelatedBooksResult] = [:]
  @State private var loadingRelatedBooksRoutes = Set<BookGroupRoute>()
  @State private var relatedBooksErrors: [BookGroupRoute: String] = [:]
  @State private var isCollectionHeaderCollapsed = false
  @State private var isShowingSettings = false
  @AppStorage("library.collectionFilter") private var collectionFilterRawValue =
    BookCollectionFilter.all.rawValue
  @AppStorage("library.collectionLayout") private var collectionLayoutRawValue =
    BookCollectionLayout.grid.rawValue
  @AppStorage("library.seriesLayout") private var seriesLayoutRawValue =
    BookCollectionLayout.seriesDefault.rawValue
  @AppStorage("library.homeCollectionLayout") private var homeCollectionLayoutRawValue =
    BookCollectionLayout.grid.rawValue

  let mode: PodibleLibraryScreenMode
  let clientOverride: RemoteLibraryServing?
  let searchQuery: Binding<String>?
  @Binding var navigationPath: NavigationPath
  @Binding var isShowingPlayer: Bool

  init(
    mode: PodibleLibraryScreenMode = .library,
    client: RemoteLibraryServing? = nil,
    searchQuery: Binding<String>? = nil,
    navigationPath: Binding<NavigationPath> = .constant(NavigationPath()),
    isShowingPlayer: Binding<Bool> = .constant(false)
  ) {
    self.mode = mode
    self.clientOverride = client
    self.searchQuery = searchQuery
    self._navigationPath = navigationPath
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

  private var trimmedPodibleRPCURL: String {
    userSettings.podibleRPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canStartPodibleSignIn: Bool {
    trimmedPodibleRPCURL.isEmpty == false && podibleAuth.isAuthenticating == false
  }

  private var isWaitingForStoredPodibleSession: Bool {
    clientOverride == nil
      && trimmedPodibleRPCURL.isEmpty == false
      && podibleAuth.isCheckingStoredSession
  }

  private var remoteAssetBaseURLString: String {
    userSettings.podibleRPCURL
  }

  var body: some View {
    content(client: configuredClient)
      .navigationDestination(for: LibraryNavigationRoute.self) { route in
        switch route {
        case .book(let item):
          bookDetailView(for: item)
        case .group(let groupRoute):
          relatedBooksContent(for: groupRoute)
        case .homeRail(let rail):
          homeRailContent(for: rail)
        }
      }
      .navigationDestination(isPresented: $isShowingSettings) {
        SettingsView()
      }
      .onReceive(NotificationCenter.default.publisher(for: .audioPlayerDidFinishItem)) {
        markFinishedPlaybackRead($0)
      }
      .task {
        migrateLegacyActivityState()
      }
  }

  private func bookDetailView(for item: PodibleLibraryItem) -> some View {
    BookDetailView(
      item: item,
      localBook: localBooksById[item.id],
      actions: detailActions(item: item, client: configuredClient),
      onShowAuthor: { authorName in
        navigationPath.append(
          LibraryNavigationRoute.group(.author(BookAuthorRoute(name: authorName)))
        )
      },
      isStreamOnly: isStreamOnly(item: item, localBook: localBooksById[item.id]),
      isShowingPlayer: $isShowingPlayer
    )
    .onAppear {
      recordRecentlyViewed(bookID: item.id)
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
    let defaultManifestationID = playback?.audio?.manifestationId
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
    actions.isFavorite = localBook.map(isSavedBook(_:)) ?? false
    actions.isRead = localBook?.localState?.isRead == true
    if localBook != nil {
      actions.toggleFavorite = { toggleFavorite(bookID: item.id) }
      actions.toggleRead = { toggleRead(bookID: item.id) }
    }

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
    actions.canPlayAudioEdition = { audio in
      if audio.manifestationId == defaultManifestationID, localPlaybackURL != nil {
        return true
      }
      return client != nil
    }
    actions.playAudioEdition = { audio in
      if audio.manifestationId == defaultManifestationID, let localBook, let localPlaybackURL {
        startPlayback(for: localBook, url: localPlaybackURL)
      } else if let client {
        startStreamingPlayback(for: item, playbackAudio: audio, client: client)
      }
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
      actions.searchReleases = { media, query in
        try await client.searchReleases(
          bookID: item.id,
          mediaType: media,
          query: query,
          limit: 50
        )
      }
      actions.createManifestationFromSearch = { selection in
        let result = try await client.createManifestationFromSearch(
          bookID: item.id,
          selection: selection
        )
        await refresh(using: client)
        return result
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
    let series = fetchOrCreateSeries(for: item)
    updateLocalBook(book, with: item, author: author, series: series)
    if modelContext.hasChanges {
      saveModelContext()
    }
  }

  @MainActor
  private func persistRequestedBook(_ item: PodibleLibraryItem) {
    let book = ensureLocalBook(for: item)
    let author = fetchOrCreateAuthor(name: item.author)
    let series = fetchOrCreateSeries(for: item)
    updateLocalBook(book, with: item, author: author, series: series)
    if modelContext.hasChanges {
      saveModelContext()
    }
  }

  @ViewBuilder
  private func content(client: RemoteLibraryServing?) -> some View {
    Group {
      let query = trimmedSearchQuery
      if query.isEmpty && searchQuery == nil {
        if mode == .home {
          homeContent(client: client)
        } else {
          collectionContent(client: client)
        }
      } else {
        List {
          searchStatusRows(client: client)
          searchListing(query: query, client: client)
        }
      }
    }
    #if os(iOS)
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(listBackgroundColor)
    #endif
    .navigationTitle(navigationTitle)
    .toolbar {
      #if os(iOS)
        ToolbarItem(placement: .principal) {
          if isCollectionHeaderCollapsed {
            compactCollectionHeader
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          if mode != .home {
            collectionOptionsMenu
          }
        }
      #endif
      #if os(macOS)
        ToolbarItem {
          syncButton(client: client)
        }
        ToolbarItem {
          collectionOptionsMenu
        }
      #endif
    }
    .task(id: "\(podibleAuth.accessToken ?? "")|\(podibleAuth.hasCheckedStoredSession)") {
      guard isWaitingForStoredPodibleSession == false else { return }
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
    .task(id: activePlaybackMetadataTaskID(client: client)) {
      guard let client else { return }
      await loadMetadataForActivePlaybackIfNeeded(client: client)
    }
    .task(id: artworkPaletteTaskID) {
      loadCachedArtworkPalettes()
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
    .modifier(
      RemoteLibrarySearchBindingModifier(
        searchQuery: searchQuery,
        viewModel: viewModel,
        onChange: { handleSearchQueryChange($0, client: client) }
      )
    )
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

  private var collectionFilter: BookCollectionFilter {
    BookCollectionFilter(rawValue: collectionFilterRawValue) ?? .all
  }

  private var collectionLayout: BookCollectionLayout {
    BookCollectionLayout(rawValue: collectionLayoutRawValue) ?? .grid
  }

  private var seriesLayout: BookCollectionLayout {
    BookCollectionLayout(rawValue: seriesLayoutRawValue) ?? .seriesDefault
  }

  private var homeCollectionLayout: BookCollectionLayout {
    BookCollectionLayout(rawValue: homeCollectionLayoutRawValue) ?? .grid
  }

  private var navigationTitle: String {
    searchQuery == nil ? mode.title : "Search"
  }

  private var collectionFilterBinding: Binding<BookCollectionFilter> {
    Binding(
      get: { collectionFilter },
      set: { collectionFilterRawValue = $0.rawValue }
    )
  }

  private var collectionLayoutBinding: Binding<BookCollectionLayout> {
    Binding(
      get: { collectionLayout },
      set: { collectionLayoutRawValue = $0.rawValue }
    )
  }

  private var seriesLayoutBinding: Binding<BookCollectionLayout> {
    Binding(
      get: { seriesLayout },
      set: { seriesLayoutRawValue = $0.rawValue }
    )
  }

  private var homeCollectionLayoutBinding: Binding<BookCollectionLayout> {
    Binding(
      get: { homeCollectionLayout },
      set: { homeCollectionLayoutRawValue = $0.rawValue }
    )
  }

  private var collectionBooks: [LibraryBook] {
    switch mode {
    case .home:
      localBooks
    case .library:
      localBooks
    case .favorites:
      localBooks.filter(isSavedBook(_:))
    }
  }

  @MainActor
  private func recordRecentlyViewed(bookID: String) {
    let activity = activityState(for: bookID)
    activity.lastViewedAt = Date()
    saveModelContext()
  }

  private func books(for collection: LibraryCollection) -> [LibraryBook] {
    return switch collection {
    case .continueReading:
      localBooks
        .filter {
          belongsInContinueReading(
            progress: playbackProgress(for: $0),
            isRead: $0.localState?.isRead == true
          )
        }
        .sorted {
          playbackLastPlayedAt(for: $0) > playbackLastPlayedAt(for: $1)
        }
    case .tbr:
      localBooks.filter {
        belongsInTBR(
          isFavorite: $0.localState?.isFavorite == true,
          isRead: $0.localState?.isRead == true,
          progress: playbackProgress(for: $0)
        )
      }
    case .newOnPodible:
      localBooks
        .filter {
          belongsInNewOnPodible(
            isFavorite: isSavedBook($0),
            isRead: $0.localState?.isRead == true
          )
        }
        .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    case .recentlyViewed:
      localBooks.filter { activityStateIfPresent(for: $0.podibleId)?.lastViewedAt != nil }
        .sorted {
          (activityStateIfPresent(for: $0.podibleId)?.lastViewedAt ?? .distantPast)
            > (activityStateIfPresent(for: $1.podibleId)?.lastViewedAt ?? .distantPast)
        }
    case .read:
      localBooks
        .filter { $0.localState?.isRead == true }
        .sorted {
          (activityStateIfPresent(for: $0.podibleId)?.readAt ?? .distantPast)
            > (activityStateIfPresent(for: $1.podibleId)?.readAt ?? .distantPast)
        }
    }
  }

  private func homeContent(client: RemoteLibraryServing?) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 28) {
        collectionStatusMessages(client: client)
        ForEach(LibraryCollection.allCases) { collection in
          BookRailView(
            title: collection.title,
            books: books(for: collection).map(bookTileViewData(for:)),
            emptyMessage: homeRailEmptyMessage(title: collection.title),
            artwork: collectionArtwork(for:cornerRadius:),
            onSelect: selectCollectionBook(_:),
            onToggleRead: toggleRead(_:),
            onToggleFavorite: toggleFavorite(_:),
            onSeeAll: { navigationPath.append(LibraryNavigationRoute.homeRail(collection)) }
          )
        }
      }
      .padding(.top, 12)
      .padding(.bottom, 20)
    }
  }

  private func homeRailContent(for collection: LibraryCollection) -> some View {
    BookGroupContentView(
      title: collection.title,
      books: books(for: collection).map(bookTileViewData(for:)),
      layout: homeCollectionLayout,
      filter: collectionFilter,
      artwork: collectionArtwork(for:cornerRadius:),
      onSelect: selectCollectionBook(_:),
      onToggleRead: toggleRead(_:),
      onToggleFavorite: toggleFavorite(_:)
    )
    .navigationTitle(collection.title)
    .toolbar {
      #if os(iOS)
        ToolbarItem(placement: .topBarTrailing) {
          homeCollectionOptionsMenu
        }
      #else
        ToolbarItem(placement: .primaryAction) {
          homeCollectionOptionsMenu
        }
      #endif
    }
  }

  private func homeRailEmptyMessage(title: String) -> String {
    switch title {
    case "Continue reading":
      "No books in progress."
    case "TBR":
      "No unread favorites."
    case "New on Podible":
      "No new books."
    case "Recently Viewed":
      "No recently viewed books."
    default:
      "No read books."
    }
  }

  private var trimmedSearchQuery: String {
    viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func collectionContentTopPadding(client: RemoteLibraryServing?) -> CGFloat {
    hasCollectionStatusMessages(client: client) ? 58 : 0
  }

  private func handleSearchQueryChange(
    _ newValue: String,
    client: RemoteLibraryServing?
  ) {
    searchTask?.cancel()
    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      viewModel.searchResults = []
      pendingSearchItemIDs.removeAll()
      return
    }
    guard mode == .library else {
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

  private var collectionTiles: [BookTileViewData] {
    collectionBooks.map(bookTileViewData(for:))
  }

  @ViewBuilder
  private func collectionContent(client: RemoteLibraryServing?) -> some View {
    if collectionBooks.isEmpty {
      VStack(spacing: 0) {
        collectionStatusMessages(client: client)
        collectionEmptyState(client: client)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      #if os(iOS)
        ZStack(alignment: .top) {
          BookCollectionView(
            books: collectionTiles,
            layout: collectionLayout,
            filter: collectionFilter,
            contentTopPadding: collectionContentTopPadding(client: client),
            artwork: collectionArtwork(for:cornerRadius:),
            onSelect: selectCollectionBook(_:),
            onToggleRead: toggleRead(_:),
            onToggleFavorite: toggleFavorite(_:),
            onScrolledPastHeader: setCollectionHeaderCollapsed(_:)
          )

          collectionStatusMessages(client: client)
        }
      #else
        VStack(spacing: 0) {
          collectionStatusMessages(client: client)
          collectionControls
          BookCollectionView(
            books: collectionTiles,
            layout: collectionLayout,
            filter: collectionFilter,
            artwork: collectionArtwork(for:cornerRadius:),
            onSelect: selectCollectionBook(_:),
            onToggleRead: toggleRead(_:),
            onToggleFavorite: toggleFavorite(_:)
          )
        }
      #endif
    }
  }

  private func hasCollectionStatusMessages(client: RemoteLibraryServing?) -> Bool {
    (client == nil && localBooks.isEmpty == false && isWaitingForStoredPodibleSession == false)
      || viewModel.errorMessage != nil
      || downloadErrorMessage != nil
      || syncErrorMessage != nil
  }

  @ViewBuilder
  private func collectionStatusMessages(client: RemoteLibraryServing?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if client == nil && localBooks.isEmpty == false && isWaitingForStoredPodibleSession == false {
        podibleConnectionBanner
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
    }
    .padding(.horizontal, 16)
  }

  @ViewBuilder
  private func collectionEmptyState(client: RemoteLibraryServing?) -> some View {
    if mode == .favorites {
      ContentUnavailableView("No Favorites", systemImage: "heart")
    } else if isWaitingForStoredPodibleSession {
      ProgressView()
    } else if client == nil {
      podibleOnboardingCard
    } else {
      ContentUnavailableView(
        "No Books",
        systemImage: "tray",
        description: Text("Pull to refresh your Podible library.")
      )
    }
  }

  private var collectionControls: some View {
    collectionControlContent
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
  }

  private var collectionControlContent: some View {
    HStack(spacing: 12) {
      Picker("Read filter", selection: collectionFilterBinding) {
        ForEach(BookCollectionFilter.allCases) { filter in
          Text(filter.title).tag(filter)
        }
      }
      .pickerStyle(.segmented)

      Picker("Layout", selection: collectionLayoutBinding) {
        ForEach(BookCollectionLayout.allCases) { layout in
          Image(systemName: layout.systemImage).tag(layout)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 144)
    }
  }

  private var compactCollectionHeader: some View {
    Text(navigationTitle)
      .font(.headline.weight(.semibold))
      .lineLimit(1)
      .frame(maxWidth: .infinity)
      .transition(.opacity)
  }

  private var collectionOptionsMenu: some View {
    Menu {
      Picker("Read filter", selection: collectionFilterBinding) {
        ForEach(BookCollectionFilter.allCases) { filter in
          Text(filter.title).tag(filter)
        }
      }

      Picker("Layout", selection: collectionLayoutBinding) {
        ForEach(BookCollectionLayout.allCases) { layout in
          Label(layout.title, systemImage: layout.systemImage).tag(layout)
        }
      }

      Divider()

      Button {
        isShowingSettings = true
      } label: {
        Label("Settings", systemImage: "gear")
      }
    } label: {
      Image(systemName: "ellipsis")
        .imageScale(.large)
    }
    .accessibilityLabel("Library options")
  }

  private var relatedBooksOptionsMenu: some View {
    Menu {
      Picker("Read filter", selection: collectionFilterBinding) {
        ForEach(BookCollectionFilter.allCases) { filter in
          Text(filter.title).tag(filter)
        }
      }

      Picker("Layout", selection: seriesLayoutBinding) {
        ForEach(BookCollectionLayout.allCases) { layout in
          Label(layout.title, systemImage: layout.systemImage).tag(layout)
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .imageScale(.large)
    }
    .accessibilityLabel("Book list options")
  }

  private var homeCollectionOptionsMenu: some View {
    Menu {
      Picker("Read filter", selection: collectionFilterBinding) {
        ForEach(BookCollectionFilter.allCases) { filter in
          Text(filter.title).tag(filter)
        }
      }
      Picker("Layout", selection: homeCollectionLayoutBinding) {
        ForEach(BookCollectionLayout.allCases) { layout in
          Label(layout.title, systemImage: layout.systemImage).tag(layout)
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .imageScale(.large)
    }
    .accessibilityLabel("Collection options")
  }

  private func syncButton(client: RemoteLibraryServing?) -> some View {
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

  private func setCollectionHeaderCollapsed(_ isCollapsed: Bool) {
    guard isCollectionHeaderCollapsed != isCollapsed else { return }
    withAnimation(.snappy(duration: 0.18)) {
      isCollectionHeaderCollapsed = isCollapsed
    }
  }

  private func relatedBooksContent(for route: BookGroupRoute) -> some View {
    let books = relatedBookTiles(for: route)
    return Group {
      if loadingRelatedBooksRoutes.contains(route) && relatedBooksResults[route] == nil
        && books.isEmpty
      {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error = relatedBooksErrors[route], books.isEmpty {
        ContentUnavailableView(
          "Unable to Load Books",
          systemImage: "exclamationmark.triangle",
          description: Text(error)
        )
      } else {
        relatedBooksCollection(route: route, books: books)
      }
    }
    .navigationTitle(route.title)
    .toolbar {
      #if os(iOS)
        ToolbarItem(placement: .topBarTrailing) {
          relatedBooksOptionsMenu
        }
      #else
        ToolbarItem(placement: .primaryAction) {
          relatedBooksOptionsMenu
        }
      #endif
    }
    .task(id: route) {
      await loadRelatedBooks(route, using: configuredClient)
    }
  }

  @ViewBuilder
  private func relatedBooksCollection(route: BookGroupRoute, books: [BookTileViewData]) -> some View
  {
    #if os(iOS)
      BookGroupContentView(
        title: route.title,
        books: books,
        layout: seriesLayout,
        filter: collectionFilter,
        artwork: collectionArtwork(for:cornerRadius:),
        onSelect: selectCollectionBook(_:),
        onToggleRead: toggleRead(_:),
        onToggleFavorite: toggleFavorite(_:)
      )
    #else
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Picker("Read filter", selection: collectionFilterBinding) {
            ForEach(BookCollectionFilter.allCases) { filter in
              Text(filter.title).tag(filter)
            }
          }
          .pickerStyle(.segmented)

          Picker("Layout", selection: seriesLayoutBinding) {
            ForEach(BookCollectionLayout.allCases) { layout in
              Image(systemName: layout.systemImage).tag(layout)
            }
          }
          .pickerStyle(.segmented)
          .frame(width: 144)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        BookGroupContentView(
          title: route.title,
          books: books,
          layout: seriesLayout,
          filter: collectionFilter,
          artwork: collectionArtwork(for:cornerRadius:),
          onSelect: selectCollectionBook(_:),
          onToggleRead: toggleRead(_:),
          onToggleFavorite: toggleFavorite(_:)
        )
      }
    #endif
  }

  @MainActor
  private func loadRelatedBooks(_ route: BookGroupRoute, using client: RemoteLibraryServing?) async
  {
    guard relatedBooksResults[route] == nil else { return }
    guard loadingRelatedBooksRoutes.insert(route).inserted else { return }
    defer { loadingRelatedBooksRoutes.remove(route) }
    guard let client else { return }

    do {
      let result: PodibleRelatedBooksResult
      switch route {
      case .series(let series):
        result = try await client.fetchSeries(
          seriesKey: series.seriesKey,
          seriesName: series.title,
          limit: 100
        ).relatedBooks
      case .author(let author):
        result = try await client.fetchAuthor(authorName: author.name, limit: 100).relatedBooks
      }
      result.libraryBooks.forEach(applyLibraryItemUpdate(_:))
      relatedBooksResults[route] = result
      relatedBooksErrors[route] = nil
    } catch {
      guard isCancellationError(error) == false else { return }
      relatedBooksErrors[route] = error.localizedDescription
    }
  }

  private func localRelatedBooks(for route: BookGroupRoute) -> [LibraryBook] {
    switch route {
    case .series(let series):
      localBooks.filter { book in
        book.series?.podibleId == series.id || book.series?.title == series.title
      }
    case .author(let author):
      localBooks.filter {
        $0.author?.name.localizedCaseInsensitiveCompare(author.name) == .orderedSame
      }
    }
  }

  private func relatedBookTiles(for route: BookGroupRoute) -> [BookTileViewData] {
    guard let result = relatedBooksResults[route] else {
      return sortRelatedBookTiles(
        localRelatedBooks(for: route).map { bookTileViewData(for: $0, group: route) }, for: route)
    }

    var books = result.libraryBooks.map { item in
      let tile = localBooksById[item.id].map(bookTileViewData(for:)) ?? bookTileViewData(for: item)
      return bookTileViewData(tile, series: item.series, group: route)
    }
    let libraryOpenLibraryIDs = Set(
      result.libraryBooks.compactMap(\.openLibraryWorkID).map(normalizedOpenLibraryID(_:))
    )
    var seenBookIdentities = Set(
      result.libraryBooks.map { relatedBookIdentity(title: $0.title, author: $0.author) }
    )
    books.append(
      contentsOf: result.openLibraryBooks.compactMap { book in
        guard libraryOpenLibraryIDs.contains(normalizedOpenLibraryID(book.openLibraryKey)) == false
        else { return nil }
        let identity = relatedBookIdentity(title: book.title, author: book.author)
        guard seenBookIdentities.insert(identity).inserted else { return nil }
        return bookTileViewData(for: book, group: route)
      }
    )
    return sortRelatedBookTiles(books, for: route)
  }

  private func sortRelatedBookTiles(
    _ books: [BookTileViewData],
    for route: BookGroupRoute
  ) -> [BookTileViewData] {
    switch route {
    case .series:
      SeriesViewData.sortedBooks(books)
    case .author:
      books.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
    }
  }

  private var localBooksById: [String: LibraryBook] {
    Dictionary(uniqueKeysWithValues: localBooks.map { ($0.podibleId, $0) })
  }

  private func bookTileViewData(for book: LibraryBook) -> BookTileViewData {
    let artworkURL = remoteLibraryAssetURL(
      baseURLString: remoteAssetBaseURLString,
      path: book.coverURLString,
      versionToken: book.updatedAt.map { String(Int($0.timeIntervalSince1970)) }
    )
    let progress = playbackProgress(for: book)

    return BookTileViewData(
      id: book.podibleId,
      title: book.title,
      author: book.author?.name ?? "Unknown Author",
      artworkURL: artworkURL,
      durationText: book.runtimeSeconds.map(formatRuntime(seconds:)),
      progress: progress,
      isRead: book.localState?.isRead == true,
      isFavorite: isSavedBookState(book.localState, progress: progress),
      palette: artworkPalette(for: artworkURL),
      seriesKey: book.series?.podibleId,
      seriesTitle: book.series?.title,
      seriesPosition: book.seriesIndex,
      publishedYear: book.publishedYear,
      narrator: book.narrator,
      description: book.summary
    )
  }

  private func bookTileViewData(for item: PodibleLibraryItem) -> BookTileViewData {
    let artworkURL = remoteLibraryAssetURL(
      baseURLString: remoteAssetBaseURLString,
      path: item.bookImagePath,
      versionToken: item.updatedAt.map { String(Int($0.timeIntervalSince1970)) }
    )
    return BookTileViewData(
      id: item.id,
      title: item.title,
      author: item.author,
      artworkURL: artworkURL,
      durationText: item.runtimeSeconds.map(formatRuntime(seconds:)),
      palette: artworkPalette(for: artworkURL),
      seriesKey: item.seriesKey,
      seriesTitle: item.seriesTitle,
      seriesPosition: item.seriesPosition,
      publishedYear: item.publishedYear,
      narrator: item.narrator,
      description: item.summary
    )
  }

  private func bookTileViewData(
    for book: LibraryBook,
    group route: BookGroupRoute
  ) -> BookTileViewData {
    var memberships = podibleSeriesMemberships(from: book.seriesMembershipsJSON)
    if memberships.isEmpty, let series = book.series {
      memberships = [
        PodibleBookSeriesMembership(
          key: series.podibleId,
          name: series.title,
          position: book.seriesIndex.map { String($0) }
        )
      ]
    }
    return bookTileViewData(bookTileViewData(for: book), series: memberships, group: route)
  }

  private func bookTileViewData(
    _ tile: BookTileViewData,
    series memberships: [PodibleBookSeriesMembership],
    group route: BookGroupRoute
  ) -> BookTileViewData {
    guard case .series(let series) = route,
      let membership = podibleSeriesMembership(
        matchingSeriesKey: series.seriesKey,
        seriesTitle: series.title,
        in: memberships
      )
    else { return tile }

    var tile = tile
    tile.seriesKey = membership.key
    tile.seriesTitle = membership.name
    tile.seriesPosition = membership.numericPosition
    return tile
  }

  private func bookTileViewData(
    for book: PodibleOpenLibraryBook,
    group route: BookGroupRoute
  ) -> BookTileViewData {
    let membership: PodibleBookSeriesMembership?
    switch route {
    case .series(let series):
      membership = podibleSeriesMembership(
        matchingSeriesKey: series.seriesKey,
        seriesTitle: series.title,
        in: book.series
      )
    case .author:
      membership = book.series.first
    }
    let artworkURL = book.coverID.flatMap {
      URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg")
    }
    return BookTileViewData(
      id: "openlibrary:\(book.openLibraryKey)",
      title: book.title,
      author: book.author,
      artworkURL: artworkURL,
      isInLibrary: false,
      palette: artworkPalette(for: artworkURL),
      seriesKey: membership?.key,
      seriesTitle: membership?.name,
      seriesPosition: membership?.numericPosition,
      publishedYear: book.publishedYear
    )
  }

  private func normalizedOpenLibraryID(_ raw: String) -> String {
    raw.split(separator: "/").last.map(String.init)?.uppercased() ?? raw.uppercased()
  }

  private func collectionArtwork(
    for book: BookTileViewData,
    cornerRadius: CGFloat
  ) -> AnyView {
    AnyView(
      Group {
        if let url = book.artworkURL {
          AuthenticatedRemoteImage(
            url: url,
            rpcURLString: userSettings.podibleRPCURL,
            accessToken: podibleAuth.accessToken,
            onSuccess: { image in
              sampleAndCacheArtworkPalette(from: image, for: url)
            }
          ) {
            collectionArtworkPlaceholder(for: book)
          }
          .scaledToFill()
        } else {
          collectionArtworkPlaceholder(for: book)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    )
  }

  private func collectionArtworkPlaceholder(for book: BookTileViewData) -> some View {
    ZStack {
      Rectangle()
        .fill(coverPlaceholderColor(title: book.title, author: book.author))
      VStack(spacing: 6) {
        Text(book.title)
          .font(.caption.weight(.bold))
          .multilineTextAlignment(.center)
          .lineLimit(4)
        if book.author.isEmpty == false {
          Text(book.author)
            .font(.caption2)
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }
      }
      .padding(10)
      .foregroundStyle(.secondary)
    }
  }

  private var artworkPaletteTaskID: String {
    let bookKeys = localBooks.map { book in
      [
        book.podibleId,
        book.coverURLString ?? "",
        book.updatedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "",
      ].joined(separator: ":")
    }
    return ([remoteAssetBaseURLString, podibleAuth.accessToken ?? ""] + bookKeys).joined(
      separator: "|")
  }

  private func artworkPalette(for artworkURL: URL?) -> ArtworkPalette {
    guard let key = artworkURL?.absoluteString else { return .fallback }
    return artworkPalettesByURL[key] ?? .fallback
  }

  @MainActor
  private func loadCachedArtworkPalettes() {
    let requests = localBooks.compactMap { book -> URL? in
      remoteLibraryAssetURL(
        baseURLString: remoteAssetBaseURLString,
        path: book.coverURLString,
        versionToken: book.updatedAt.map { String(Int($0.timeIntervalSince1970)) }
      )
    }
    guard requests.isEmpty == false else {
      artworkPalettesByURL = [:]
      return
    }
    let currentKeys = Set(requests.map(\.absoluteString))
    let cache = ArtworkPaletteCache()
    cache.removePalettes(excluding: currentKeys)

    artworkPalettesByURL = artworkPalettesByURL.filter { currentKeys.contains($0.key) }
    for key in currentKeys where artworkPalettesByURL[key] == nil {
      if let cached = cache.palette(for: key) {
        artworkPalettesByURL[key] = cached
      }
    }
  }

  @MainActor
  private func sampleAndCacheArtworkPalette(
    from image: KFCrossPlatformImage,
    for url: URL
  ) {
    let key = url.absoluteString
    guard artworkPalettesByURL[key] == nil else { return }
    guard artworkPaletteKeysBeingSampled.insert(key).inserted else { return }

    Task {
      let palette = await Task.detached(priority: .utility) {
        ArtworkPaletteSampler.palette(from: image)
      }.value
      artworkPaletteKeysBeingSampled.remove(key)
      guard let palette else { return }
      ArtworkPaletteCache().store(palette, for: key)
      artworkPalettesByURL[key] = palette
    }
  }

  @MainActor
  private func selectCollectionBook(_ book: BookTileViewData) {
    if let localBook = localBooksById[book.id] {
      navigationPath.append(LibraryNavigationRoute.book(localProxyItem(for: localBook)))
      return
    }
    guard
      let item = relatedBooksResults.values.lazy
        .flatMap(\.libraryBooks)
        .first(where: { $0.id == book.id })
    else { return }
    navigationPath.append(LibraryNavigationRoute.book(item))
  }

  @MainActor
  private func toggleRead(_ book: BookTileViewData) {
    toggleRead(bookID: book.id)
  }

  @MainActor
  private func toggleFavorite(_ book: BookTileViewData) {
    toggleFavorite(bookID: book.id)
  }

  @MainActor
  private func toggleRead(bookID: String) {
    guard let localBook = localBooksById[bookID] else { return }
    let state = ensureLocalState(for: localBook)
    setReadState(!(state.isRead ?? false), on: state)
    activityState(for: bookID).readAt = state.isRead == true ? Date() : nil
    if modelContext.hasChanges {
      saveModelContext()
    }
  }

  @MainActor
  private func toggleFavorite(bookID: String) {
    guard let localBook = localBooksById[bookID] else { return }
    let state = ensureLocalState(for: localBook)
    guard state.isRead != true, (playbackProgress(for: localBook) ?? 0) == 0 else { return }
    state.isFavorite = !(state.isFavorite ?? false)
    if modelContext.hasChanges {
      saveModelContext()
    }
  }

  private func isSavedBook(_ book: LibraryBook) -> Bool {
    isSavedBookState(book.localState, progress: playbackProgress(for: book))
  }

  private func playbackLastPlayedAt(for book: LibraryBook) -> Date {
    player.persistedLastPlayedAt(identity: playbackIdentity(for: book))
      ?? book.localState?.lastPlayedAt
      ?? book.updatedAt
      ?? .distantPast
  }

  @MainActor
  private func markFinishedPlaybackRead(_ notification: Notification) {
    guard let resumeID = notification.userInfo?["resumeID"] as? String else { return }
    guard let book = localBooks.first(where: { playbackIdentity(for: $0).matches(resumeID) }) else {
      return
    }
    let state = ensureLocalState(for: book)
    guard state.isRead != true else { return }
    setReadState(true, on: state)
    activityState(for: book.podibleId).readAt = Date()
    if modelContext.hasChanges {
      saveModelContext()
    }
  }

  private func activePlaybackMetadataTaskID(client: RemoteLibraryServing?) -> String {
    guard client != nil, let activeResumeID = player.activeResumeID else { return "none" }
    return "\(podibleAuth.accessToken ?? "")|\(activeResumeID)|\(localBooks.count)"
  }

  private var syncState: LibrarySyncState? {
    syncStates.first
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
  private func libraryListing(client: RemoteLibraryServing?) -> some View {
    if localBooks.isEmpty {
      centeredListEmptyState {
        if isWaitingForStoredPodibleSession {
          ProgressView()
        } else if client == nil {
          podibleOnboardingCard
        } else {
          ContentUnavailableView(
            "No Books",
            systemImage: "tray",
            description: Text("Pull to refresh your Podible library.")
          )
        }
      }
    } else {
      ForEach(localBooks) { book in
        localLibraryRow(book, client: client)
      }
    }
  }

  @ViewBuilder
  private func searchListing(query: String, client: RemoteLibraryServing?) -> some View {
    if query.isEmpty {
      centeredListEmptyState {
        ContentUnavailableView("Search Books", systemImage: "magnifyingglass")
      }
    } else {
      let localMatches = filteredCollectionBooks(query: query)
      let localIds = Set(localMatches.map(\.podibleId))
      let remoteResults =
        mode == .library
        ? viewModel.searchResults.filter { localIds.contains($0.id) == false }
        : []

      if localMatches.isEmpty && remoteResults.isEmpty {
        centeredListEmptyState {
          ContentUnavailableView("No Results", systemImage: "magnifyingglass")
        }
      } else {
        ForEach(localMatches) { book in
          localLibraryRow(book, client: client)
        }
        if mode == .library, let client {
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
  }

  @ViewBuilder
  private func searchStatusRows(client: RemoteLibraryServing?) -> some View {
    if client == nil && localBooks.isEmpty == false && isWaitingForStoredPodibleSession == false {
      podibleConnectionBanner
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
  }

  private func filteredCollectionBooks(query: String) -> [LibraryBook] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return collectionBooks }
    let needle = trimmed.lowercased()
    return collectionBooks.filter { book in
      book.title.lowercased().contains(needle)
        || (book.author?.name.lowercased().contains(needle) ?? false)
        || (book.series?.title.lowercased().contains(needle) ?? false)
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

  private var podibleOnboardingCard: some View {
    VStack(spacing: 18) {
      Image(systemName: "books.vertical.fill")
        .font(.system(size: 44, weight: .semibold))
        .foregroundStyle(.tint)
        .padding(18)
        .background(.tint.opacity(0.12), in: Circle())

      VStack(spacing: 8) {
        Text("Connect Your Library")
          .font(.title2.weight(.bold))
          .multilineTextAlignment(.center)
        Text("Sign in to Podible to sync your audiobooks, covers, chapters, and transcripts.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 10) {
        podibleServerTextField
        podibleSignInButton
        podibleAuthErrorText
      }
      .frame(maxWidth: 360)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 28)
    .frame(maxWidth: .infinity)
  }

  private var podibleConnectionBanner: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "person.crop.circle.badge.plus")
          .font(.title2)
          .foregroundStyle(.tint)
          .frame(width: 34)
        VStack(alignment: .leading, spacing: 4) {
          Text("Connect Podible")
            .font(.headline)
          Text(
            "Sign in here to refresh your remote library. Downloaded audiobooks still work offline."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      podibleServerTextField
      podibleSignInButton
      podibleAuthErrorText
    }
    .padding(14)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  private var podibleServerTextField: some View {
    #if os(iOS)
      TextField("https://podible.example.com", text: userSettings.$podibleRPCURL)
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
        .autocorrectionDisabled()
    #else
      TextField("https://podible.example.com", text: userSettings.$podibleRPCURL)
        .textFieldStyle(.roundedBorder)
    #endif
  }

  private var podibleSignInButton: some View {
    Button {
      startPodibleSignIn()
    } label: {
      HStack(spacing: 8) {
        if podibleAuth.isAuthenticating {
          ProgressView()
        }
        Text(podibleAuth.isAuthenticating ? "Signing In..." : "Sign In to Podible")
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
    .disabled(canStartPodibleSignIn == false)
  }

  @ViewBuilder
  private var podibleAuthErrorText: some View {
    if let errorMessage = podibleAuth.errorMessage {
      Text(errorMessage)
        .font(.caption)
        .foregroundStyle(.red)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    } else if trimmedPodibleRPCURL.isEmpty {
      Text("Enter your Podible server URL to continue.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
  }

  private func startPodibleSignIn() {
    guard canStartPodibleSignIn else { return }
    Task {
      await podibleAuth.signIn(rpcURLString: userSettings.podibleRPCURL)
    }
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
      syncErrorMessage = librarySyncErrorMessage(for: error)
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
      NavigationLink(value: LibraryNavigationRoute.book(item)) {
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
      descriptionHTML: book.descriptionHTML,
      status: overallStatus,
      ebookStatus: ebookStatus,
      audioStatus: audioStatus,
      bookAdded: book.addedAt,
      updatedAt: book.updatedAt,
      fullPseudoProgress: book.fullPseudoProgress,
      bookImagePath: book.coverURLString,
      wordCount: book.wordCount,
      runtimeSeconds: book.runtimeSeconds,
      publishedYear: book.publishedYear,
      narrator: book.narrator,
      series: podibleSeriesMemberships(from: book.seriesMembershipsJSON),
      seriesKey: book.series?.podibleId,
      seriesTitle: book.series?.title,
      seriesPosition: book.seriesIndex,
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
    localState.isFavorite = true
    localState.lastPlayedAt = Date()
    try? modelContext.save()
    let identity = playbackIdentity(for: book)
    player.load(
      url: url,
      identity: identity,
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
        await loadPlaybackMetadata(playback: playbackAudio, identity: identity, client: client)
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
    guard
      let playbackAudio =
        item.playback?.audio
        ?? localBooksById[item.id].flatMap({ self.playback(from: $0.playbackJSON)?.audio })
    else {
      downloadErrorMessage = "Audiobook not available for streaming."
      return
    }
    startStreamingPlayback(for: item, playbackAudio: playbackAudio, client: client)
  }

  @MainActor
  private func startStreamingPlayback(
    for item: PodibleLibraryItem,
    playbackAudio: PodiblePlaybackAudio,
    client: RemoteLibraryServing
  ) {
    isShowingPlayer = true
    let identity = streamingIdentity(for: item, playbackAudio: playbackAudio)
    let localBook = ensureLocalBook(for: item)
    ensureLocalState(for: localBook).isFavorite = true
    saveModelContext()
    let localBookID = localBook.podibleId
    Task {
      do {
        let httpURL = try client.audiobookStreamURL(playback: playbackAudio)
        let cache = try? StreamingAudioCache(
          sourceURL: httpURL,
          suggestedFilename: audiobookFilename(
            title: item.title,
            playback: playbackAudio,
            sourceURL: httpURL
          )
        )
        await MainActor.run {
          player.loadStreaming(
            httpURL: httpURL,
            accessToken: podibleAuth.accessToken,
            identity: identity,
            title: item.title,
            author: item.author,
            description: item.summary,
            artworkURL: remoteLibraryAssetURL(
              baseURLString: remoteAssetBaseURLString,
              path: item.bookImagePath,
              versionToken: item.updatedAt.map { String(Int($0.timeIntervalSince1970)) }),
            artworkAccessToken: podibleAuth.accessToken,
            cache: cache,
            onCacheCompleted: { completed in
              Task { @MainActor in
                completeCachedStreamingDownload(completed, forBookID: localBookID)
              }
            }
          )
          player.play()
          if let cache {
            Task {
              try? await Task.sleep(nanoseconds: 2_000_000_000)
              do {
                let completed = try await cache.fillAll(
                  accessToken: podibleAuth.accessToken,
                  progress: { _ in }
                )
                await MainActor.run {
                  completeCachedStreamingDownload(completed, forBookID: localBookID)
                }
              } catch {
                // Playback can continue even if opportunistic offline caching fails.
              }
            }
          }
          // Server-side chapters/transcript still available — fire and forget.
          Task {
            await loadPlaybackMetadata(playback: playbackAudio, identity: identity, client: client)
          }
        }
      } catch {
        downloadErrorMessage = "Streaming failed: \(error.localizedDescription)"
      }
    }
  }

  private func streamingIdentity(
    for item: PodibleLibraryItem,
    playbackAudio: PodiblePlaybackAudio? = nil
  ) -> PlaybackIdentity {
    let manifestationID =
      playbackAudio?.manifestationId
      ?? item.playback?.audio?.manifestationId
      ?? localBooksById[item.id].flatMap {
        self.playback(from: $0.playbackJSON)?.audio?.manifestationId
      }
    return PlaybackIdentity(
      openLibraryWorkID: item.openLibraryWorkID,
      podibleID: item.id,
      manifestationID: manifestationID
    )
  }

  @MainActor
  private func loadPlaybackMetadata(
    playback: PodiblePlaybackAudio?,
    identity: PlaybackIdentity,
    client: RemoteLibraryServing
  ) async {
    guard let playback else {
      player.applyRemoteTranscriptUnavailable(
        "No audio edition metadata is available for transcript lookup.",
        for: identity
      )
      player.applyRemoteChapters([], for: identity)
      return
    }

    async let chapters: Void = loadRemoteChapters(
      playback: playback,
      identity: identity,
      client: client
    )
    async let transcript: Void = loadRemoteTranscript(
      playback: playback,
      identity: identity,
      client: client
    )
    _ = await (chapters, transcript)
  }

  @MainActor
  private func loadMetadataForActivePlaybackIfNeeded(client: RemoteLibraryServing) async {
    guard player.transcriptLoadState == .idle else { return }
    guard let activeResumeID = player.activeResumeID else { return }
    guard
      let activeBook = localBooks.first(where: {
        playbackIdentity(for: $0).matches(activeResumeID)
      })
    else {
      return
    }
    let playbackAudio = playback(from: activeBook.playbackJSON)?.audio
    await loadPlaybackMetadata(
      playback: playbackAudio,
      identity: playbackIdentity(for: activeBook),
      client: client
    )
  }

  private func loadRemoteTranscript(
    playback: PodiblePlaybackAudio,
    identity: PlaybackIdentity,
    client: RemoteLibraryServing
  ) async {
    guard let transcriptURL = playback.transcriptUrl,
      transcriptURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else {
      await MainActor.run {
        player.applyRemoteTranscriptUnavailable(
          "Podible did not return a transcript URL for this audio edition.",
          for: identity
        )
      }
      return
    }

    await MainActor.run {
      player.beginRemoteTranscriptLoad(for: identity)
    }

    do {
      if let transcript = try await client.fetchTranscript(playback: playback) {
        await MainActor.run {
          player.applyRemoteTranscript(transcript, for: identity)
        }
      } else {
        await MainActor.run {
          player.applyRemoteTranscriptUnavailable(
            "Podible returned 404 for this transcript URL.",
            for: identity
          )
        }
      }
    } catch {
      await MainActor.run {
        player.applyRemoteTranscriptFailure(
          "Transcript download failed: \(error.localizedDescription)",
          for: identity
        )
      }
    }
  }

  private func loadRemoteChapters(
    playback: PodiblePlaybackAudio,
    identity: PlaybackIdentity,
    client: RemoteLibraryServing
  ) async {
    do {
      let chapters = try await client.fetchChapters(playback: playback)
      await MainActor.run {
        player.applyRemoteChapters(chapters, for: identity)
      }
    } catch {
      await MainActor.run {
        player.applyRemoteChapters([], for: identity)
      }
    }
  }

  private func playbackIdentity(for book: LibraryBook) -> PlaybackIdentity {
    return PlaybackIdentity(
      openLibraryWorkID: book.openLibraryWorkID,
      podibleID: book.podibleId,
      manifestationID: playback(from: book.playbackJSON)?.audio?.manifestationId
    )
  }

  private func playbackProgress(for book: LibraryBook) -> Double? {
    player.persistedProgress(
      identity: playbackIdentity(for: book),
      duration: book.runtimeSeconds.map(Double.init)
    )
  }

  @MainActor
  private func startLocalDownload(for book: LibraryBook, client: RemoteLibraryServing) {
    guard localDownloadingBookIDs.contains(book.podibleId) == false else { return }
    localDownloadingBookIDs.insert(book.podibleId)
    localDownloadProgressByBookID[book.podibleId] = 0
    downloadErrorMessage = nil
    let bookID = book.podibleId

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
        let streamURL = try client.audiobookStreamURL(playback: playbackAudio)
        let cache = try StreamingAudioCache(
          sourceURL: streamURL,
          suggestedFilename: audiobookFilename(
            title: book.title,
            playback: playbackAudio,
            sourceURL: streamURL
          )
        )
        let completed = try await cache.fillAll(accessToken: podibleAuth.accessToken) { value in
          Task { @MainActor in
            localDownloadProgressByBookID[bookID] = value
          }
        }
        try storeCompletedAudiobook(completed, for: book, fileRecord: fileRecord)
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

  @MainActor
  private func completeCachedStreamingDownload(
    _ completed: StreamingAudioCache.CompletedFile,
    forBookID bookID: String
  ) {
    guard let book = localBooksById[bookID] else { return }
    let fileRecord = ensureFileRecord(for: book)
    guard fileRecord.downloadStatus != .completed else { return }
    do {
      try storeCompletedAudiobook(completed, for: book, fileRecord: fileRecord)
      try LocalAudiobookCache().enforceLimit(modelContext: modelContext, keeping: book.podibleId)
    } catch {
      fileRecord.downloadStatus = .failed
      fileRecord.lastError = error.localizedDescription
      try? modelContext.save()
    }
  }

  @MainActor
  private func storeCompletedAudiobook(
    _ completed: StreamingAudioCache.CompletedFile,
    for book: LibraryBook,
    fileRecord: LibraryBookFile
  ) throws {
    let stored = try LibraryStorage().storeCopiedFile(
      completed.url,
      for: book,
      suggestedFilename: completed.suggestedFilename
    )
    let fileSize = stored.fileSizeBytes ?? completed.fileSizeBytes
    fileRecord.filename = stored.filename
    fileRecord.localRelativePath = stored.relativePath
    fileRecord.sizeBytes = fileSize
    fileRecord.bytesDownloaded = fileSize
    fileRecord.format = BookFileFormat.fromFilename(stored.filename)
    fileRecord.downloadStatus = .completed
    fileRecord.lastError = nil

    let localState = ensureLocalState(for: book)
    localState.isDownloaded = true
    localState.lastPlayedAt = localState.lastPlayedAt ?? Date()

    try modelContext.save()
  }

  private func audiobookFilename(
    title: String,
    playback: PodiblePlaybackAudio,
    sourceURL: URL
  ) -> String {
    let base = sanitizeFilename(title)
    let ext: String
    if sourceURL.pathExtension.isEmpty == false {
      ext = sourceURL.pathExtension
    } else if playback.mimeType == "audio/mpeg" {
      ext = "mp3"
    } else if playback.mimeType == "audio/mp4" || playback.mimeType == "audio/x-m4b" {
      ext = "m4b"
    } else {
      ext = "audio"
    }
    return "\(base).\(ext)"
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

  private func activityStateIfPresent(for bookID: String) -> BookActivityState? {
    bookActivities.first { $0.bookPodibleID == bookID }
  }

  private func activityState(for bookID: String) -> BookActivityState {
    if let existing = activityStateIfPresent(for: bookID) {
      return existing
    }
    let activity = BookActivityState(bookPodibleID: bookID)
    modelContext.insert(activity)
    return activity
  }

  private func migrateLegacyActivityState() {
    let key = "library.recentlyViewedBookIDs"
    let ids =
      UserDefaults.standard.string(forKey: key)?.split(separator: "\n").map(String.init) ?? []
    let now = Date()
    for (index, id) in ids.enumerated() {
      let activity = activityState(for: id)
      if activity.lastViewedAt == nil {
        activity.lastViewedAt = now.addingTimeInterval(Double(-index))
      }
    }
    for book in localBooks where book.localState?.isRead == true {
      let activity = activityState(for: book.podibleId)
      activity.readAt = activity.readAt ?? book.localState?.lastPlayedAt ?? book.updatedAt ?? now
    }
    if modelContext.hasChanges {
      saveModelContext()
    }
    if ids.isEmpty == false {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  @MainActor
  private func ensureLocalBook(for item: PodibleLibraryItem) -> LibraryBook {
    if let existing = localBooksById[item.id] {
      let author = fetchOrCreateAuthor(name: item.author)
      let series = fetchOrCreateSeries(for: item)
      updateLocalBook(existing, with: item, author: author, series: series)
      return existing
    }

    let author = fetchOrCreateAuthor(name: item.author)
    let series = fetchOrCreateSeries(for: item)
    let book = LibraryBook(
      podibleId: item.id,
      openLibraryWorkID: item.openLibraryWorkID,
      title: item.title,
      summary: item.summary,
      descriptionHTML: item.descriptionHTML,
      coverURLString: item.bookImagePath,
      runtimeSeconds: item.runtimeSeconds,
      wordCount: item.wordCount,
      publishedYear: item.publishedYear,
      narrator: item.narrator,
      addedAt: item.bookAdded,
      updatedAt: latestLibraryDate(for: item),
      fullPseudoProgress: item.fullPseudoProgress,
      seriesIndex: item.seriesPosition,
      seriesMembershipsJSON: podibleSeriesMembershipsData(item.series),
      bookStatusRaw: (item.ebookStatus ?? item.status).rawValue,
      audioStatusRaw: item.audioStatus?.rawValue,
      playbackJSON: playbackData(for: item.playback),
      author: author,
      series: series
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
  private func fetchOrCreateSeries(for item: PodibleLibraryItem) -> Series? {
    guard let key = seriesKey(for: item) else { return nil }
    let title = item.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayTitle = title?.isEmpty == false ? title! : key
    let descriptor = FetchDescriptor<Series>(
      predicate: #Predicate { $0.podibleId == key }
    )
    if let existing = (try? modelContext.fetch(descriptor))?.first {
      if existing.title != displayTitle {
        existing.title = displayTitle
      }
      return existing
    }
    let series = Series(podibleId: key, title: displayTitle)
    modelContext.insert(series)
    return series
  }

  @MainActor
  private func updateLocalBook(
    _ book: LibraryBook,
    with item: PodibleLibraryItem,
    author: Author,
    series: Series?
  ) {
    var updated = false
    if let localState = book.localState, localState.bookPodibleId != item.id {
      localState.bookPodibleId = item.id
      updated = true
    }
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
    if book.descriptionHTML != item.descriptionHTML {
      book.descriptionHTML = item.descriptionHTML
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
    if book.publishedYear != item.publishedYear {
      book.publishedYear = item.publishedYear
      updated = true
    }
    if book.narrator != item.narrator {
      book.narrator = item.narrator
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
    if book.series !== series {
      book.series = series
      updated = true
    }
    if book.seriesIndex != item.seriesPosition {
      book.seriesIndex = item.seriesPosition
      updated = true
    }
    let nextSeriesMembershipsJSON = podibleSeriesMembershipsData(item.series)
    if book.seriesMembershipsJSON != nextSeriesMembershipsJSON {
      book.seriesMembershipsJSON = nextSeriesMembershipsJSON
      updated = true
    }
    if book.fullPseudoProgress != item.fullPseudoProgress {
      book.fullPseudoProgress = item.fullPseudoProgress
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

  private func seriesKey(for item: PodibleLibraryItem) -> String? {
    if let raw = item.seriesKey?.trimmingCharacters(in: .whitespacesAndNewlines),
      raw.isEmpty == false
    {
      return raw
    }
    guard let title = item.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      title.isEmpty == false
    else {
      return nil
    }
    return title.lowercased()
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
  accessToken: String?,
  width: CGFloat = 88,
  height: CGFloat = 128,
  cornerRadius: CGFloat = 6
) -> some View {
  if let url {
    AuthenticatedRemoteImage(
      url: url,
      rpcURLString: rpcURLString,
      accessToken: accessToken
    ) {
      bookCoverPlaceholder(
        title: title, author: author, width: width, height: height, cornerRadius: cornerRadius)
    }
    .scaledToFill()
    .frame(width: width, height: height)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
  } else {
    bookCoverPlaceholder(
      title: title, author: author, width: width, height: height, cornerRadius: cornerRadius)
  }
}

func bookCoverPlaceholder(
  title: String,
  author: String,
  width: CGFloat = 88,
  height: CGFloat = 128,
  cornerRadius: CGFloat = 6
) -> some View {
  let scale = min(width / 88, height / 128)
  let titleSize = 12 * scale
  let authorSize = 10 * scale
  let textSpacing = 6 * scale
  let textPadding = 8 * scale

  return RoundedRectangle(cornerRadius: cornerRadius)
    .fill(coverPlaceholderColor(title: title, author: author))
    .frame(width: width, height: height)
    .overlay(
      VStack(spacing: textSpacing) {
        Text(title)
          .font(.system(size: titleSize, weight: .semibold))
          .multilineTextAlignment(.center)
          .lineLimit(3)
        Text(author)
          .font(.system(size: authorSize))
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
      .padding(textPadding)
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

private struct RemoteLibrarySearchBindingModifier: ViewModifier {
  let searchQuery: Binding<String>?
  @ObservedObject var viewModel: RemoteLibraryViewModel
  let onChange: (String) -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if let searchQuery {
      content
        .searchable(
          text: searchQuery,
          prompt: "Search by title, author, or series"
        )
        .onAppear {
          syncSearchQuery(searchQuery.wrappedValue)
        }
        .onChange(of: searchQuery.wrappedValue) { _, newValue in
          syncSearchQuery(newValue)
        }
        .onChange(of: viewModel.query) { _, newValue in
          guard searchQuery.wrappedValue != newValue else { return }
          searchQuery.wrappedValue = newValue
        }
    } else {
      content
    }
  }

  private func syncSearchQuery(_ query: String) {
    if viewModel.query != query {
      viewModel.query = query
    }
    onChange(query)
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
      PlaybackState.self,
      BookActivityState.self,
      LibrarySyncState.self,
    ],
    inMemory: true
  )
}
