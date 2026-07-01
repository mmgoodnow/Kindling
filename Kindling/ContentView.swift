import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var player: AudioPlayerController
  @State private var selectedTab: AppTab = .library

  private enum AppTab: Hashable {
    case library
    case favorites
    case player
    case search
  }

  private var playerTabBinding: Binding<Bool> {
    Binding(
      get: { selectedTab == .player },
      set: { isShowing in
        if isShowing {
          selectedTab = .player
        }
      }
    )
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
        NavigationStack {
          RemoteLibraryView(
            mode: .library,
            isShowingPlayer: playerTabBinding
          )
          .toolbar { settingsToolbar }
        }
      }

      Tab("Favorites", systemImage: "heart.fill", value: AppTab.favorites) {
        NavigationStack {
          RemoteLibraryView(
            mode: .favorites,
            isShowingPlayer: playerTabBinding
          )
          .toolbar { settingsToolbar }
        }
      }

      Tab(
        "Player", systemImage: player.isPlaying ? "pause.fill" : "play.fill", value: AppTab.player
      ) {
        LocalPlaybackView(player: player)
      }

      Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
        NavigationStack {
          RemoteLibraryView(
            mode: .library,
            isSearchEnabled: true,
            isShowingPlayer: playerTabBinding
          )
          .toolbar { settingsToolbar }
        }
      }
      .tabPlacement(.pinned)
    }
    .tabViewSearchActivation(.searchTabSelection)
  }

  @ToolbarContentBuilder
  private var settingsToolbar: some ToolbarContent {
    ToolbarItem {
      NavigationLink(destination: SettingsView()) {
        Image(systemName: "gear")
      }
    }
  }
}

#Preview {
  ContentView()
    .environmentObject(UserSettings())
    .environmentObject(PodibleAuthController())
    .environmentObject(AudioPlayerController())
}
