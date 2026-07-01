import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var player: AudioPlayerController
  @State private var selectedTab: AppTab = .library
  @State private var searchQuery = ""

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
        if isShowing, player.hasLoadedItem {
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
        }
      }

      Tab("Favorites", systemImage: "heart.fill", value: AppTab.favorites) {
        NavigationStack {
          RemoteLibraryView(
            mode: .favorites,
            isShowingPlayer: playerTabBinding
          )
        }
      }

      if player.hasLoadedItem {
        Tab(
          "Player", systemImage: player.isPlaying ? "pause.fill" : "play.fill", value: AppTab.player
        ) {
          LocalPlaybackView(player: player)
        }
      }

      Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
        NavigationStack {
          RemoteLibraryView(
            mode: .library,
            searchQuery: $searchQuery,
            isShowingPlayer: playerTabBinding
          )
        }
      }
    }
    .onChange(of: player.hasLoadedItem) { _, hasLoadedItem in
      if hasLoadedItem == false, selectedTab == .player {
        selectedTab = .library
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
