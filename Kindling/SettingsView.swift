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
    }.formStyle(.grouped)
      .navigationTitle("Settings")
  }
}

#Preview {
  SettingsView()
    .environmentObject(UserSettings())
    .environmentObject(PodibleAuthController())
}
