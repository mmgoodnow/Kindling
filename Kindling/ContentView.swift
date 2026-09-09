import SwiftData
import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var player: AudioPlayerController
  @EnvironmentObject private var userSettings: UserSettings
  @EnvironmentObject private var podibleAuth: PodibleAuthController
  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase
  #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
  #endif
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
  @State private var libraryData = LibraryStore()
  @State private var podibleLibrary = PodibleLibraryViewModel()
  @State private var artworkPalettes = ArtworkPaletteStore()
  @State private var libraryDownloads = LibraryDownloadController()
  @StateObject private var playbackIdentityResolver = PlaybackIdentityResolver()
  @State private var selectedTab: AppTab = .home
  @State private var searchQuery = ""
  @State private var libraryNavigationPath = NavigationPath()
  @State private var homeNavigationPath = NavigationPath()
  @State private var favoritesNavigationPath = NavigationPath()
  @State private var searchNavigationPath = NavigationPath()
  @State private var isShowingPlayer = false

  private enum AppTab: Hashable {
    case home
    case library
    case favorites
    case search
  }

  private var playerTabBinding: Binding<Bool> {
    $isShowingPlayer
  }

  var body: some View {
    Group {
      #if os(iOS)
        if player.hasLoadedItem && !player.hasFinished {
          appTabs
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewSearchActivation(.searchTabSelection)
            .tabViewBottomAccessory {
              miniPlayer
            }
        } else {
          appTabs
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewSearchActivation(.searchTabSelection)
        }
      #else
        appTabs
          .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.hasLoadedItem && !player.hasFinished {
              miniPlayer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
          }
      #endif
    }
    #if os(iOS)
      .overlay {
        if isShowingPlayer {
          LocalPlaybackView(player: player) {
            isShowingPlayer = false
          }
          .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .identity))
          .zIndex(1)
        }
      }
      .animation(.snappy(duration: 0.38), value: isShowingPlayer)
    #else
      .onChange(of: isShowingPlayer) { _, isPresented in
        guard isPresented else { return }
        openWindow(id: "now-playing")
        isShowingPlayer = false
      }
    #endif
    .environment(libraryData)
    .environment(podibleLibrary)
    .environment(artworkPalettes)
    .environment(libraryDownloads)
    .task(id: libraryDataRevision) {
      libraryData.update(
        books: localBooks,
        activities: bookActivities,
        syncStates: syncStates
      )
      try? libraryData.migrateLegacyActivityState(context: modelContext)
    }
    .task(id: artworkPaletteTaskID) {
      artworkPalettes.loadCached(
        for: localBooks.compactMap { book in
          remoteLibraryAssetURL(
            baseURLString: userSettings.podibleRPCURL,
            path: book.coverURLString,
            versionToken: book.updatedAt.map { String(Int($0.timeIntervalSince1970)) }
          )
        }
      )
    }
    .task(id: podibleSessionTaskID) {
      guard podibleAuth.isCheckingStoredSession == false else { return }
      guard let client = configuredClient else {
        podibleLibrary.reset()
        return
      }
      await podibleLibrary.refresh(using: client, modelContext: modelContext)
    }
    .task(id: playbackMetadataTaskID) {
      guard let client = configuredClient else { return }
      await PlaybackMetadataLoader(player: player).loadForActivePlaybackIfNeeded(
        books: localBooks,
        identity: playbackIdentityResolver.identity(for:),
        client: client
      )
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active, let client = configuredClient else { return }
      Task {
        await podibleLibrary.refresh(using: client, modelContext: modelContext)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .audioPlayerDidFinishItem)) {
      markFinishedPlaybackRead($0)
    }
    .alert("Podible Session Expired", isPresented: reauthenticationPrompt) {
      Button("Not Now", role: .cancel) {
        podibleAuth.dismissReauthenticationPrompt()
      }
      Button("Sign In Again") {
        Task {
          await podibleAuth.signIn(rpcURLString: userSettings.podibleRPCURL)
        }
      }
    } message: {
      Text(
        "Sign in again to reconnect to Podible. Audiobooks already downloaded to this device remain available."
      )
    }
  }

  private var configuredClient: RemoteLibraryServing? {
    podibleAuth.makeAuthenticatedClient(rpcURLString: userSettings.podibleRPCURL)
  }

  private var reauthenticationPrompt: Binding<Bool> {
    Binding(
      get: { podibleAuth.requiresReauthentication },
      set: { isPresented in
        if isPresented == false {
          podibleAuth.dismissReauthenticationPrompt()
        }
      }
    )
  }

  private var podibleSessionTaskID: String {
    "\(userSettings.podibleRPCURL)|\(podibleAuth.accessToken ?? "")|\(podibleAuth.hasCheckedStoredSession)"
  }

  private var playbackMetadataTaskID: String {
    guard configuredClient != nil, let activeResumeID = player.activeResumeID else { return "none" }
    return "\(podibleAuth.accessToken ?? "")|\(activeResumeID)|\(localBooks.count)"
  }

  private var artworkPaletteTaskID: Int {
    artworkPaletteRevision(
      baseURL: userSettings.podibleRPCURL,
      accessToken: podibleAuth.accessToken,
      books: localBooks.map {
        (id: $0.podibleId, coverURL: $0.coverURLString, updatedAt: $0.updatedAt)
      }
    )
  }

  private var libraryDataRevision: Int {
    var hasher = Hasher()
    localBooks.forEach { hasher.combine($0.persistentModelID) }
    bookActivities.forEach { hasher.combine($0.persistentModelID) }
    syncStates.forEach { hasher.combine($0.persistentModelID) }
    return hasher.finalize()
  }

  private func markFinishedPlaybackRead(_ notification: Notification) {
    guard let source = notification.object as? AudioPlayerController, source === player,
      let resumeID = notification.userInfo?["resumeID"] as? String
    else { return }
    isShowingPlayer = false
    #if os(macOS)
      dismissWindow(id: "now-playing")
    #endif
    guard
      let book = localBooks.first(where: {
        $0.podibleId == player.activePlaybackIdentity?.podibleID
          || playbackIdentityResolver.identity(for: $0).matches(resumeID)
      })
    else { return }
    try? libraryData.markFinishedPlaybackRead(
      resumeID: resumeID,
      identity: {
        if $0.podibleId == book.podibleId, let identity = player.activePlaybackIdentity {
          return identity
        }
        return playbackIdentityResolver.identity(for: $0)
      },
      context: modelContext
    )
    let path = NavigationPath([LibraryNavigationRoute.localBook(book.podibleId)])
    switch selectedTab {
    case .home: homeNavigationPath = path
    case .library: libraryNavigationPath = path
    case .favorites: favoritesNavigationPath = path
    case .search: searchNavigationPath = path
    }
  }

  private var appTabs: some View {
    TabView(selection: $selectedTab) {
      Tab("Home", systemImage: "house.fill", value: AppTab.home) {
        LibraryTabRoot(
          mode: .home,
          navigationPath: $homeNavigationPath,
          isShowingPlayer: playerTabBinding
        )
      }

      Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
        LibraryTabRoot(
          mode: .library,
          navigationPath: $libraryNavigationPath,
          isShowingPlayer: playerTabBinding
        )
      }

      Tab("Favorites", systemImage: "heart.fill", value: AppTab.favorites) {
        LibraryTabRoot(
          mode: .favorites,
          navigationPath: $favoritesNavigationPath,
          isShowingPlayer: playerTabBinding
        )
      }

      Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
        LibraryTabRoot(
          mode: .library,
          searchQuery: $searchQuery,
          navigationPath: $searchNavigationPath,
          isShowingPlayer: playerTabBinding
        )
      }
      .tabPlacement(.pinned)
    }
  }

  private var miniPlayer: some View {
    MiniPlaybackAccessory(player: player) {
      isShowingPlayer = true
    }
  }
}

private struct LibraryTabRoot: View {
  let mode: PodibleLibraryScreenMode
  var searchQuery: Binding<String>?
  @Binding var navigationPath: NavigationPath
  @Binding var isShowingPlayer: Bool

  init(
    mode: PodibleLibraryScreenMode,
    searchQuery: Binding<String>? = nil,
    navigationPath: Binding<NavigationPath>,
    isShowingPlayer: Binding<Bool>
  ) {
    self.mode = mode
    self.searchQuery = searchQuery
    self._navigationPath = navigationPath
    self._isShowingPlayer = isShowingPlayer
  }

  var body: some View {
    NavigationStack(path: $navigationPath) {
      switch mode {
      case .home:
        HomeScreen(
          navigationPath: $navigationPath,
          isShowingPlayer: $isShowingPlayer
        )
      case .library:
        if let searchQuery {
          SearchScreen(
            query: searchQuery,
            navigationPath: $navigationPath,
            isShowingPlayer: $isShowingPlayer
          )
        } else {
          LibraryScreen(
            navigationPath: $navigationPath,
            isShowingPlayer: $isShowingPlayer
          )
        }
      case .favorites:
        FavoritesScreen(
          navigationPath: $navigationPath,
          isShowingPlayer: $isShowingPlayer
        )
      }
    }
  }
}

private struct HomeScreen: View {
  @Binding var navigationPath: NavigationPath
  @Binding var isShowingPlayer: Bool

  var body: some View {
    LibraryFeatureContainer(
      mode: .home,
      navigationPath: $navigationPath,
      isShowingPlayer: $isShowingPlayer
    )
  }
}

private struct LibraryScreen: View {
  @Binding var navigationPath: NavigationPath
  @Binding var isShowingPlayer: Bool

  var body: some View {
    LibraryFeatureContainer(
      mode: .library,
      navigationPath: $navigationPath,
      isShowingPlayer: $isShowingPlayer
    )
  }
}

private struct FavoritesScreen: View {
  @Binding var navigationPath: NavigationPath
  @Binding var isShowingPlayer: Bool

  var body: some View {
    LibraryFeatureContainer(
      mode: .favorites,
      navigationPath: $navigationPath,
      isShowingPlayer: $isShowingPlayer
    )
  }
}

private struct SearchScreen: View {
  let query: Binding<String>
  @Binding var navigationPath: NavigationPath
  @Binding var isShowingPlayer: Bool

  var body: some View {
    LibraryFeatureContainer(
      mode: .library,
      searchQuery: query,
      navigationPath: $navigationPath,
      isShowingPlayer: $isShowingPlayer
    )
  }
}

#Preview {
  ContentView()
    .environmentObject(UserSettings())
    .environmentObject(PodibleAuthController())
    .environmentObject(AudioPlayerController())
}
