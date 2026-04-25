import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var player: AudioPlayerController
  @State private var isShowingPlayer = false

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
    #if os(iOS)
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
