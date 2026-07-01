import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var player: AudioPlayerController
  @EnvironmentObject private var userSettings: UserSettings
  @EnvironmentObject private var podibleAuth: PodibleAuthController
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

      Tab(value: AppTab.player) {
        LocalPlaybackView(player: player)
      } label: {
        Label {
          Text("Player")
        } icon: {
          playerTabIcon
        }
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

  @ViewBuilder
  private var playerTabIcon: some View {
    if player.hasLoadedItem {
      AuthenticatedRemoteImage(
        url: player.artworkURL,
        rpcURLString: userSettings.podibleRPCURL,
        accessToken: podibleAuth.accessToken
      ) {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
          .imageScale(.large)
      }
      .scaledToFill()
      .frame(width: 24, height: 24)
      .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    } else {
      Image(systemName: "play.fill")
    }
  }
}

#Preview {
  ContentView()
    .environmentObject(UserSettings())
    .environmentObject(PodibleAuthController())
    .environmentObject(AudioPlayerController())
}
