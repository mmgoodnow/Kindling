import SwiftUI

struct SettingsView: View {
  @EnvironmentObject var userSettings: UserSettings
  @EnvironmentObject var podibleAuth: PodibleAuthController

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
        if let errorMessage = podibleAuth.errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .font(.caption)
        }
        if let currentUserDescription = podibleAuth.currentUserDescription {
          Text("Signed in as \(currentUserDescription)")
            .font(.subheadline)
        } else {
          Text("Sign in with your Podible account to access your library.")
            .foregroundStyle(.secondary)
            .font(.subheadline)
        }
        if podibleAuth.isAuthenticated {
          Button("Sign Out", role: .destructive) {
            Task {
              await podibleAuth.logout(rpcURLString: userSettings.podibleRPCURL)
            }
          }
        } else {
          Button {
            Task {
              await podibleAuth.signIn(rpcURLString: userSettings.podibleRPCURL)
            }
          } label: {
            HStack(spacing: 8) {
              if podibleAuth.isAuthenticating {
                ProgressView()
              }
              Text("Sign In")
            }
          }
          .disabled(
            userSettings.podibleRPCURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || podibleAuth.isAuthenticating
          )
        }
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
    .environmentObject(PodibleAuthController())
}
