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
    .sheet(isPresented: $isShowingPlayer) {
      LocalPlaybackView(player: player)
    }
  }
}

#Preview {
  ContentView()
    .environmentObject(UserSettings())
    .environmentObject(PodibleAuthController())
    .environmentObject(AudioPlayerController())
}
