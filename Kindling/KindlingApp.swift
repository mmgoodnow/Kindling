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
  @StateObject private var userSettings = UserSettings()
  @StateObject private var podibleAuth = PodibleAuthController()
  @StateObject private var audioPlayer: AudioPlayerController
  let sharedModelContainer: ModelContainer
  private let playbackRepository: PlaybackRepository

  init() {
    let container = Self.makeModelContainer()
    let repository = PlaybackRepository(context: container.mainContext)
    try? repository.migrateLegacyState()
    sharedModelContainer = container
    playbackRepository = repository
    _audioPlayer = StateObject(wrappedValue: AudioPlayerController(repository: repository))
  }

  private static func makeModelContainer() -> ModelContainer {
    let schema = Schema(versionedSchema: KindlingSchemaV3.self)
    let modelConfiguration = ModelConfiguration(
      schema: schema, isStoredInMemoryOnly: false)

    do {
      return try ModelContainer(
        for: schema,
        migrationPlan: KindlingMigrationPlan.self,
        configurations: [modelConfiguration]
      )
    } catch {
      fatalError("Could not create ModelContainer: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(userSettings)
        .environmentObject(podibleAuth)
        .environmentObject(audioPlayer)
        .task {
          _ = audioPlayer.restoreLastSession()
        }
        .task(id: userSettings.podibleRPCURL) {
          await podibleAuth.refreshStoredSession(rpcURLString: userSettings.podibleRPCURL)
          if audioPlayer.hasLoadedItem == false {
            _ = audioPlayer.restoreLastSession(accessToken: podibleAuth.accessToken)
          }
        }
        .onChange(of: scenePhase) { _, phase in
          if phase != .active {
            playbackRepository.flushRecoveryJournal()
          }
        }
    }
    .modelContainer(sharedModelContainer)
    #if os(macOS)
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
