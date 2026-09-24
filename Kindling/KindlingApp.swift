//
//  KindlingApp.swift
//  Kindling
//
//  Created by Michael Goodnow on 9/9/24.
//

import SwiftData
import SwiftUI

@main
struct KindlingApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var userSettings: UserSettings
  @StateObject private var podibleAuth: PodibleAuthController
  @StateObject private var audioPlayer: AudioPlayerController
  let sharedModelContainer: ModelContainer
  private let playbackRepository: PlaybackRepository

  init() {
    let runtime = KindlingRuntime.shared
    sharedModelContainer = runtime.container
    playbackRepository = runtime.repository
    _audioPlayer = StateObject(wrappedValue: runtime.player)
    _userSettings = StateObject(wrappedValue: runtime.settings)
    _podibleAuth = StateObject(wrappedValue: runtime.auth)
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(userSettings)
        .environmentObject(podibleAuth)
        .environmentObject(audioPlayer)
        .task {
          if audioPlayer.hasLoadedItem == false && !KindlingRuntime.shared.isHandlingPlaybackIntent
          {
            _ = audioPlayer.restoreLastSession()
          }
        }
        .task(id: userSettings.podibleRPCURL) {
          await podibleAuth.refreshStoredSession(rpcURLString: userSettings.podibleRPCURL)
          #if os(iOS)
            audioPlayer.updateArtworkAccessToken(podibleAuth.accessToken)
          #endif
          if audioPlayer.hasLoadedItem == false && !KindlingRuntime.shared.isHandlingPlaybackIntent
          {
            _ = audioPlayer.restoreLastSession(accessToken: podibleAuth.accessToken)
          }
        }
        #if os(iOS)
          .task {
            KindlingShortcuts.updateAppShortcutParameters()
            AudiobookSpotlightIndexer.shared.schedule()
          }
          .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            AudiobookSpotlightIndexer.shared.schedule()
          }
        #endif
        .onChange(of: scenePhase) { _, phase in
          if phase != .active {
            playbackRepository.flushRecoveryJournal()
          }
        }
    }
    .modelContainer(sharedModelContainer)
    #if os(macOS)
      Window("Now Playing", id: "now-playing") {
        LocalPlaybackView(player: audioPlayer)
          .environmentObject(userSettings)
          .environmentObject(podibleAuth)
      }
      .defaultSize(width: 680, height: 640)
      .windowResizability(.contentMinSize)

      Settings {
        SettingsView()
          .scenePadding()
          .frame(minWidth: 400, minHeight: 400)
          .environmentObject(userSettings)
          .environmentObject(podibleAuth)
          .environmentObject(audioPlayer)
          .modelContainer(sharedModelContainer)
      }
    #endif
  }
}
