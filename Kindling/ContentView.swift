import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var player: AudioPlayerController
  @State private var selectedTab: AppTab = .library

  private enum AppTab: Hashable {
    case library
    case favorites
    case player
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
      NavigationStack {
        RemoteLibraryView(mode: .library, isShowingPlayer: playerTabBinding)
          .toolbar { settingsToolbar }
      }
      .tabItem {
        Label("Library", systemImage: "books.vertical")
      }
      .tag(AppTab.library)

      NavigationStack {
        RemoteLibraryView(mode: .favorites, isShowingPlayer: playerTabBinding)
          .toolbar { settingsToolbar }
      }
      .tabItem {
        Label("Favorites", systemImage: "heart.fill")
      }
      .tag(AppTab.favorites)

      LocalPlaybackView(player: player)
        .tabItem {
          Label("Player", systemImage: "play.fill")
        }
        .tag(AppTab.player)
    }
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
