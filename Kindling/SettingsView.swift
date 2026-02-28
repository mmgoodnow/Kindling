import SwiftUI

struct SettingsView: View {
  @EnvironmentObject var userSettings: UserSettings

  var body: some View {
    Form {
      Section("Podible Backend") {
        TextField(
          "RPC URL (e.g. http://localhost/rpc)",
          text: userSettings.$podibleRPCURL
        )
        #if os(iOS)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
        #endif
        TextField("API Key", text: userSettings.$podibleAPIKey)
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
      }

      Section("Email") {
        TextField(
          "Kindle Email Address",
          text: userSettings.$kindleEmailAddress
        )
      }

      Section("IRC") {
        TextField("Server", text: userSettings.$ircServer)
        TextField(
          "Port",
          value: userSettings.$ircPort,
          formatter: portNumberFormatter
        )
        TextField("Channel", text: userSettings.$ircChannel)
        TextField("Nickname", text: userSettings.$ircNick)
        Picker("Search Bot", selection: userSettings.$searchBot) {
          Text("Search").tag("Search")
          Text("SearchOok").tag("SearchOok")
        }.pickerStyle(.menu)
      }
    }.formStyle(.grouped)
      .navigationTitle("Settings")
  }

  private var portNumberFormatter: NumberFormatter {
    let formatter = NumberFormatter()
    formatter.numberStyle = .none
    formatter.minimum = 1
    formatter.maximum = 65535
    return formatter
  }
}

#Preview {
  SettingsView()
    .environmentObject(UserSettings())
}
