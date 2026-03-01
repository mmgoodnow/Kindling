//
//  KindlingApp.swift
//  Kindling
//
//  Created by Michael Goodnow on 9/9/24.
//

import SwiftData
import SwiftUI

#if os(iOS)
  import MediaPlayer
#endif

enum AppModelStore {
  static let schema = Schema([
    Author.self,
    Series.self,
    LibraryBook.self,
    LibraryBookFile.self,
    LocalBookState.self,
    LibrarySyncState.self,
  ])

  static let sharedModelContainer: ModelContainer = {
    let modelConfiguration = ModelConfiguration(
      schema: schema, isStoredInMemoryOnly: false)

    do {
      return try ModelContainer(for: schema, configurations: [modelConfiguration])
    } catch {
      fatalError("Could not create ModelContainer: \(error)")
    }
  }()
}

@main
struct KindlingApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var userSettings = UserSettings()

  init() {
    #if os(iOS)
      CarPlayLibraryManager.shared.activate()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(userSettings)
    }
    .modelContainer(AppModelStore.sharedModelContainer)
    .onChange(of: scenePhase) { _, newPhase in
      #if os(iOS)
        if newPhase == .active {
          CarPlayLibraryManager.shared.reload()
        }
      #endif
    }
    #if os(macOS)
      Settings {
        SettingsView()
          .scenePadding()
          .frame(minWidth: 400, minHeight: 400)
          .environmentObject(userSettings)
      }
    #endif
  }
}

#if os(iOS)
  @MainActor
  final class CarPlayLibraryManager: NSObject, MPPlayableContentDataSource,
    MPPlayableContentDelegate
  {
    static let shared = CarPlayLibraryManager()

    private lazy var modelContext = ModelContext(AppModelStore.sharedModelContainer)

    func activate() {
      let manager = MPPlayableContentManager.shared()
      let _ = AudioPlayerController.shared
      manager.dataSource = self
      manager.delegate = self
      reload()
    }

    func reload() {
      MPPlayableContentManager.shared().reloadData()
    }

    func numberOfChildItems(at indexPath: IndexPath) -> Int {
      if indexPath.count == 0 {
        return playableBooks.count
      }
      return 0
    }

    func contentItem(at indexPath: IndexPath) -> MPContentItem? {
      guard indexPath.count == 1, indexPath.item < playableBooks.count else { return nil }
      let book = playableBooks[indexPath.item]
      let item = MPContentItem(identifier: book.llId)
      item.title = book.title
      item.subtitle = book.author?.name ?? "Unknown Author"
      item.isContainer = false
      item.isPlayable = true
      if let progress = book.localState?.progressSeconds,
        let duration = book.runtimeSeconds.map(Double.init),
        duration > 0
      {
        item.playbackProgress = Float(min(max(progress / duration, 0), 1))
      }
      return item
    }

    func playableContentManager(
      _ contentManager: MPPlayableContentManager,
      initiatePlaybackOfContentItemAt indexPath: IndexPath,
      completionHandler: @escaping (Error?) -> Void
    ) {
      guard indexPath.count == 1, indexPath.item < playableBooks.count else {
        completionHandler(NSError(domain: "Kindling.CarPlay", code: 1))
        return
      }

      let book = playableBooks[indexPath.item]
      guard let url = playbackURL(for: book) else {
        completionHandler(NSError(domain: "Kindling.CarPlay", code: 2))
        return
      }

      let localState = book.localState ?? LocalBookState(bookLlId: book.llId, book: book)
      if book.localState == nil {
        modelContext.insert(localState)
        book.localState = localState
      }
      localState.lastPlayedAt = Date()
      try? modelContext.save()

      AudioPlayerController.shared.load(
        url: url,
        bookID: book.llId,
        title: book.title,
        author: book.author?.name,
        description: book.summary,
        artworkURL: book.coverURLString.flatMap(URL.init(string:))
      )
      AudioPlayerController.shared.play()
      contentManager.nowPlayingIdentifiers = [book.llId]
      completionHandler(nil)
    }

    private var playableBooks: [LibraryBook] {
      let descriptor = FetchDescriptor<LibraryBook>(
        sortBy: [
          SortDescriptor(\LibraryBook.addedAt, order: .reverse),
          SortDescriptor(\LibraryBook.title, order: .forward),
        ])
      let books = (try? modelContext.fetch(descriptor)) ?? []
      return books.filter { playbackURL(for: $0) != nil }
    }

    private func playbackURL(for book: LibraryBook) -> URL? {
      guard
        let file = book.files.first,
        file.downloadStatus == .completed,
        let relativePath = file.localRelativePath
      else {
        return nil
      }

      let url = try? LibraryStorage().url(forRelativePath: relativePath)
      guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }

      let format =
        file.format == .unknown ? BookFileFormat.fromFilename(url.lastPathComponent) : file.format
      switch format {
      case .m4b, .mp3, .m4a:
        return url
      default:
        return nil
      }
    }
  }

#endif
