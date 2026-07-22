import SwiftData
import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var player: AudioPlayerController
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
        if player.hasLoadedItem {
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
            if player.hasLoadedItem {
              miniPlayer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
          }
      #endif
    }
    .sheet(isPresented: $isShowingPlayer) {
      LocalPlaybackView(player: player)
    }
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
  }

  @EnvironmentObject private var userSettings: UserSettings
  @EnvironmentObject private var podibleAuth: PodibleAuthController

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

  private var appTabs: some View {
    TabView(selection: $selectedTab) {
      Tab("Home", systemImage: "house.fill", value: AppTab.home) {
        LibraryTabRoot(
          mode: .home,
          navigationPath: $homeNavigationPath,
          isShowingPlayer: playerTabBinding
        )
        .equatable()
      }

      Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
        LibraryTabRoot(
          mode: .library,
          navigationPath: $libraryNavigationPath,
          isShowingPlayer: playerTabBinding
        )
        .equatable()
      }

      Tab("Favorites", systemImage: "heart.fill", value: AppTab.favorites) {
        LibraryTabRoot(
          mode: .favorites,
          navigationPath: $favoritesNavigationPath,
          isShowingPlayer: playerTabBinding
        )
        .equatable()
      }

      Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
        LibraryTabRoot(
          mode: .library,
          searchQuery: $searchQuery,
          navigationPath: $searchNavigationPath,
          isShowingPlayer: playerTabBinding
        )
        .equatable()
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

private struct LibraryTabRoot: View, Equatable {
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

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.mode == rhs.mode
  }

  var body: some View {
    NavigationStack(path: $navigationPath) {
      RemoteLibraryView(
        mode: mode,
        searchQuery: searchQuery,
        navigationPath: $navigationPath,
        isShowingPlayer: $isShowingPlayer
      )
    }
  }
}

#Preview {
  ContentView()
    .environmentObject(UserSettings())
    .environmentObject(PodibleAuthController())
    .environmentObject(AudioPlayerController())
}
