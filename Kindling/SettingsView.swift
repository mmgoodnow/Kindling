import SwiftUI

struct SettingsView: View {
  @EnvironmentObject var userSettings: UserSettings
  @EnvironmentObject var podibleAuth: PodibleAuthController

  private var trimmedRPCURL: String {
    userSettings.podibleRPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSignIn: Bool {
    trimmedRPCURL.isEmpty == false && podibleAuth.isAuthenticating == false
  }

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 6) {
          Text("Podible")
            .font(.headline)
          Text("Connect Kindling to your Podible server, then sign in to access your library.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)

        LabeledContent("Server") {
          TextField("https://podible.example.com/rpc", text: userSettings.$podibleRPCURL)
            .multilineTextAlignment(.trailing)
            #if os(iOS)
              .textInputAutocapitalization(.never)
              .keyboardType(.URL)
              .autocorrectionDisabled()
            #endif
        }

        LabeledContent("Account") {
          Text(podibleAuth.currentUserDescription ?? "Not signed in")
            .foregroundStyle(.secondary)
        }

        LabeledContent("Status") {
          HStack(spacing: 8) {
            Circle()
              .fill(podibleAuth.isAuthenticated ? Color.green : Color.secondary.opacity(0.45))
              .frame(width: 8, height: 8)
            Text(podibleAuth.isAuthenticated ? "Connected" : "Signed out")
              .foregroundStyle(.secondary)
          }
        }

        if let errorMessage = podibleAuth.errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .font(.caption)
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
              Text(podibleAuth.isAuthenticating ? "Signing In…" : "Sign In")
            }
            .frame(maxWidth: .infinity)
          }
          .disabled(canSignIn == false)
        }
      } footer: {
        Text(
          "Use the full /rpc URL for your Podible server. Kindling will open Podible's web sign-in flow and store the returned session securely in Keychain."
        )
      }

      Section("Email") {
        TextField(
          "Kindle Email Address",
          text: userSettings.$kindleEmailAddress
        )
      } footer: {
        Text(
          "Use your Send-to-Kindle email address if you want Kindling to deliver ebooks to your Kindle."
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
