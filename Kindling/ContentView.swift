import SwiftUI

struct ContentView: View {
  var body: some View {
    NavigationStack {
      RemoteLibraryView()
        .toolbar {
          ToolbarItem {
            NavigationLink(destination: SettingsView()) {
              Image(systemName: "gear")
            }
          }
        }
    }
  }
}

#Preview {
  ContentView()
    .environmentObject(UserSettings())
    .environmentObject(PodibleAuthController())
}
