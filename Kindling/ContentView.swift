import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var player: AudioPlayerController
  @State private var selectedTab: AppTab = .library
  @State private var searchQuery = ""
  @State private var libraryNavigationPath = NavigationPath()
  @State private var favoritesNavigationPath = NavigationPath()
  @State private var searchNavigationPath = NavigationPath()
  @State private var isShowingPlayer = false

  private enum AppTab: Hashable {
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
        appTabs
          .tabBarMinimizeBehavior(.onScrollDown)
          .tabViewSearchActivation(.searchTabSelection)
          .tabViewBottomAccessory {
            if player.hasLoadedItem {
              miniPlayer
            }
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
  }

  private var appTabs: some View {
    TabView(selection: $selectedTab) {
      Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
        NavigationStack(path: $libraryNavigationPath) {
          RemoteLibraryView(
            mode: .library,
            navigationPath: $libraryNavigationPath,
            isShowingPlayer: playerTabBinding
          )
        }
      }

      Tab("Favorites", systemImage: "heart.fill", value: AppTab.favorites) {
        NavigationStack(path: $favoritesNavigationPath) {
          RemoteLibraryView(
            mode: .favorites,
            navigationPath: $favoritesNavigationPath,
            isShowingPlayer: playerTabBinding
          )
        }
      }

      Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
        NavigationStack(path: $searchNavigationPath) {
          RemoteLibraryView(
            mode: .library,
            searchQuery: $searchQuery,
            navigationPath: $searchNavigationPath,
            isShowingPlayer: playerTabBinding
          )
        }
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

#Preview {
  ContentView()
    .environmentObject(UserSettings())
    .environmentObject(PodibleAuthController())
    .environmentObject(AudioPlayerController())
}
