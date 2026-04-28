import SwiftData
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject var userSettings: UserSettings
  @EnvironmentObject var podibleAuth: PodibleAuthController
  @EnvironmentObject var player: AudioPlayerController
  @Environment(\.modelContext) private var modelContext
  @State private var isShowingWipeConfirmation = false
  @State private var isWipingLocalLibrary = false
  @State private var wipeErrorMessage: String?

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
          #if os(iOS)
            TextField("https://podible.example.com", text: userSettings.$podibleRPCURL)
              .multilineTextAlignment(.trailing)
              .textInputAutocapitalization(.never)
              .keyboardType(.URL)
              .autocorrectionDisabled()
          #else
            TextField("https://podible.example.com", text: userSettings.$podibleRPCURL)
              .multilineTextAlignment(.trailing)
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
          "Enter the web address for your Podible server. After you sign in, your library will sync to this device."
        )
      }

      Section {
        TextField(
          "Kindle Email Address",
          text: userSettings.$kindleEmailAddress
        )
      } header: {
        Text("Email")
      } footer: {
        Text(
          "Use your Send-to-Kindle email address if you want Kindling to deliver ebooks to your Kindle."
        )
      }

      Section {
        if let wipeErrorMessage {
          Text(wipeErrorMessage)
            .foregroundStyle(.red)
            .font(.caption)
        }

        Button(role: .destructive) {
          isShowingWipeConfirmation = true
        } label: {
          if isWipingLocalLibrary {
            HStack(spacing: 8) {
              ProgressView()
              Text("Wiping Local Cache…")
            }
          } else {
            Text("Wipe Local Cache")
          }
        }
        .disabled(isWipingLocalLibrary)
        .confirmationDialog(
          "Wipe Local Cache?",
          isPresented: $isShowingWipeConfirmation,
          titleVisibility: .visible
        ) {
          Button("Wipe Local Cache", role: .destructive) {
            wipeLocalLibrary()
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(
            "Kindling will remove its cached library records and downloaded files on this device. Your Podible library is not changed."
          )
        }
      } header: {
        Text("Local Cache")
      } footer: {
        Text(
          "Removes cached library records and downloaded files from this device. Your Podible library is not changed."
        )
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Settings")
  }

  @MainActor
  private func wipeLocalLibrary() {
    guard isWipingLocalLibrary == false else { return }
    isWipingLocalLibrary = true
    wipeErrorMessage = nil
    player.stop()

    Task { @MainActor in
      do {
        try LocalLibraryResetService().wipeLocalLibrary(modelContext: modelContext)
      } catch {
        wipeErrorMessage = "Failed to wipe local cache: \(error.localizedDescription)"
      }
      isWipingLocalLibrary = false
    }
  }
}

#Preview {
  SettingsView()
    .environmentObject(UserSettings())
    .environmentObject(PodibleAuthController())
    .environmentObject(AudioPlayerController())
}
