import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var player: AudioPlayerController
  @State private var isShowingPlayer = false
  @State private var floatingDock: FloatingDockBox?

  var body: some View {
    NavigationStack {
      RemoteLibraryView(isShowingPlayer: $isShowingPlayer)
        .toolbar {
          ToolbarItem {
            NavigationLink(destination: SettingsView()) {
              Image(systemName: "gear")
            }
          }
        }
    }
    .onPreferenceChange(FloatingDockPreferenceKey.self) { value in
      floatingDock = value
    }
    #if os(iOS)
      // Insets compose bottom-up: the FIRST inset hugs the screen edge, each
      // subsequent inset stacks above it. Dock first → mini bar above it.
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let floatingDock {
          floatingDock.view
          .padding(.bottom, 8)
        }
      }
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
}

#Preview {
  ContentView()
    .environmentObject(UserSettings())
    .environmentObject(PodibleAuthController())
}
