//
//  ContentView.swift
//  kindling
//
//  Created by Michael Goodnow on 9/9/24.
//

import Network
import SwiftUI

struct ContentView: View {
  @EnvironmentObject var userSettings: UserSettings
  @State private var downloader: EBookDownloader?
  @State private var stateReporter = StateReporter()
  @State private var downloaderID = UUID()

  var body: some View {
    NavigationStack {
      if hasPodibleBackendConfig {
        RemoteLibraryView()
          .toolbar {
            ToolbarItem {
              NavigationLink(destination: SettingsView()) {
                Image(systemName: "gear")
              }
            }
          }
      } else {
        Group {
          if let downloader {
            SearchView(downloader: downloader)
              .id(downloaderID)
          } else {
            ProgressView()
              .onAppear {
                updateDownloader()
              }
          }
        }
        .toolbar {
          ToolbarItem {
            Circle()
              .fill(registrationStatusDotColor)
              .frame(width: 10, height: 10)
          }
          ToolbarItem {
            Button(action: updateDownloader) {
              Image(systemName: "arrow.clockwise")
            }
          }
          ToolbarItem {
            NavigationLink(destination: SettingsView()) {
              Image(systemName: "gear")
            }
          }
        }
      }
    }
  }

  private var hasPodibleBackendConfig: Bool {
    let url = userSettings.podibleRPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = userSettings.podibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return url.isEmpty == false && key.isEmpty == false
  }

  private var registrationStatusDotColor: Color {
    switch stateReporter.state {
    case .idle:
      return .gray
    case .failed:
      return .red
    case .ready:
      return .green
    case .loading:
      return .yellow
    }
  }

  private func updateDownloader() {
    if let oldDownloader = downloader {
      Task {
        try await oldDownloader.cleanup()
      }
    }
    let stateReporter = StateReporter()
    let downloader = EBookDownloader(
      ircConnection: IRCConnection(
        connection: NWConnection(
          host: NWEndpoint.Host(userSettings.ircServer),
          port: NWEndpoint.Port(
            integerLiteral: UInt16(userSettings.ircPort)
          ),
          using: .tcp
        ),
        nickname: userSettings.ircNick,
        username: userSettings.ircNick,
        stateReporter: stateReporter
      ),
      ebooksChannel: userSettings.ircChannel,
      stateReporter: stateReporter
    )
    downloaderID = UUID()
    self.downloader = downloader
    self.stateReporter = stateReporter

    Task {
      try await downloader.start()
    }
  }
}

#Preview {
  ContentView()
    .environmentObject(UserSettings())
}
