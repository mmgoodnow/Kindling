import SwiftData
import SwiftUI

@MainActor
final class LibraryDataStore: ObservableObject {
  @Published private(set) var books: [LibraryBook] = []
  @Published private(set) var activities: [BookActivityState] = []
  @Published private(set) var syncStates: [LibrarySyncState] = []

  func update(
    books: [LibraryBook],
    activities: [BookActivityState],
    syncStates: [LibrarySyncState]
  ) {
    self.books = books
    self.activities = activities
    self.syncStates = syncStates
  }

  func books(
    for mode: PodibleLibraryScreenMode,
    progress: (LibraryBook) -> Double?
  ) -> [LibraryBook] {
    switch mode {
    case .home, .library:
      books
    case .favorites:
      books.filter { isSavedBookState($0.localState, progress: progress($0)) }
    }
  }

  func books(
    for collection: LibraryCollection,
    progress: (LibraryBook) -> Double?,
    lastPlayedAt: (LibraryBook) -> Date
  ) -> [LibraryBook] {
    switch collection {
    case .continueReading:
      books
        .filter {
          belongsInContinueReading(
            progress: progress($0),
            isRead: $0.localState?.isRead == true
          )
        }
        .sorted { lastPlayedAt($0) > lastPlayedAt($1) }
    case .tbr:
      books.filter {
        belongsInTBR(
          isFavorite: $0.localState?.isFavorite == true,
          isRead: $0.localState?.isRead == true,
          progress: progress($0)
        )
      }
    case .newOnPodible:
      books
        .filter {
          belongsInNewOnPodible(
            isFavorite: isSavedBookState($0.localState, progress: progress($0)),
            isRead: $0.localState?.isRead == true
          )
        }
        .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    case .recentlyViewed:
      books.filter { activity(for: $0.podibleId)?.lastViewedAt != nil }
        .sorted {
          (activity(for: $0.podibleId)?.lastViewedAt ?? .distantPast)
            > (activity(for: $1.podibleId)?.lastViewedAt ?? .distantPast)
        }
    case .read:
      books
        .filter { $0.localState?.isRead == true }
        .sorted {
          (activity(for: $0.podibleId)?.readAt ?? .distantPast)
            > (activity(for: $1.podibleId)?.readAt ?? .distantPast)
        }
    }
  }

  func activity(for bookID: String) -> BookActivityState? {
    activities.first { $0.bookPodibleID == bookID }
  }
}

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
  @StateObject private var libraryData = LibraryDataStore()
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
    .environmentObject(libraryData)
    .task(id: libraryDataRevision) {
      libraryData.update(
        books: localBooks,
        activities: bookActivities,
        syncStates: syncStates
      )
    }
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
