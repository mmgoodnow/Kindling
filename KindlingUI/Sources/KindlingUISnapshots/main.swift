import AppKit
import KindlingUI
import SwiftUI

private struct Snapshot {
  var name: String
  var size: CGSize
  var colorScheme: ColorScheme
  var content: @MainActor () -> AnyView

  init(
    _ name: String,
    size: CGSize = CGSize(width: 390, height: 844),
    colorScheme: ColorScheme = .light,
    @ViewBuilder content: @MainActor @escaping () -> some View
  ) {
    self.name = name
    self.size = size
    self.colorScheme = colorScheme
    self.content = { AnyView(content()) }
  }
}

private enum SnapshotFixtures {
  static let ocean = ArtworkPalette(red: 0.12, green: 0.62, blue: 0.64)
  static let red = ArtworkPalette(red: 0.73, green: 0.13, blue: 0.16)
  static let pink = ArtworkPalette(red: 0.78, green: 0.21, blue: 0.62)
  static let green = ArtworkPalette(red: 0.15, green: 0.58, blue: 0.38)

  static let books: [BookTileViewData] = [
    BookTileViewData(
      id: "hp1",
      title: "Harry Potter and the Philosopher's Stone",
      author: "J.K. Rowling",
      usesSquareArtwork: false,
      durationText: "8h 17m",
      isRead: false,
      isFavorite: true,
      palette: ocean,
      seriesKey: "harry-potter",
      seriesTitle: "Harry Potter",
      seriesPosition: 1,
      publishedYear: 1997,
      narrator: "Jim Dale",
      description: "A preview description with enough text to wrap in the detail view."
    ),
    BookTileViewData(
      id: "hp2",
      title: "Harry Potter and the Chamber of Secrets",
      author: "J.K. Rowling",
      usesSquareArtwork: false,
      durationText: "9h 3m",
      isRead: true,
      isFavorite: true,
      palette: red,
      seriesKey: "harry-potter",
      seriesTitle: "Harry Potter",
      seriesPosition: 2,
      publishedYear: 1998,
      narrator: "Jim Dale"
    ),
    BookTileViewData(
      id: "margo",
      title: "Margo's Got Money Troubles",
      author: "Rufi Thorpe",
      usesSquareArtwork: true,
      durationText: "10h 28m",
      isFavorite: true,
      palette: pink,
      publishedYear: 2024
    ),
    BookTileViewData(
      id: "katabasis",
      title: "Katabasis",
      author: "R.F. Kuang",
      usesSquareArtwork: true,
      durationText: "13h 38m",
      palette: green,
      publishedYear: 2025
    ),
  ]

  static let detail = BookDetailViewData(
    id: "hp1",
    title: "Harry Potter and the Philosopher's Stone",
    author: "J.K. Rowling",
    palette: ocean,
    durationText: "8h 17m",
    seriesTitle: "Harry Potter",
    seriesPosition: 1,
    narrator: "Jim Dale",
    publishedYear: 1997,
    description:
      "Turning the envelope over, his hand trembling, Harry saw a purple wax seal. An adventure is about to begin."
  )

  static let player = PlayerViewData(
    palette: ocean,
    bookCompletionPercent: 16,
    bookProgress: 0.16,
    currentChapterTitle: "Chapter 1",
    currentChapterProgress: 0.32,
    currentChapterElapsedText: "6:53",
    currentChapterRemainingText: "-22:15",
    isPlaying: false,
    playbackRateText: "1x",
    chapters: [
      ChapterRowViewData(
        id: 0, title: "Opening Credits", durationText: "0:21", progress: 1,
        isCompleted: true),
      ChapterRowViewData(
        id: 1, title: "Chapter 1", durationText: "25:13", progress: 0.32,
        isCurrent: true),
      ChapterRowViewData(id: 2, title: "Chapter 2", durationText: "29:54"),
      ChapterRowViewData(id: 3, title: "Chapter 3", durationText: "14:41"),
      ChapterRowViewData(id: 4, title: "Chapter 4", durationText: "17:31"),
      ChapterRowViewData(id: 5, title: "Chapter 5", durationText: "19:28"),
    ],
    transcriptStatusText: "Transcript unavailable"
  )
}

@main
private enum KindlingUISnapshots {
  @MainActor
  static func main() throws {
    _ = NSApplication.shared

    let outputDirectory =
      CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("KindlingUISnapshots", isDirectory: true)

    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true
    )

    for snapshot in snapshots {
      try render(snapshot, to: outputDirectory)
    }

    print("Wrote \(snapshots.count) snapshots to \(outputDirectory.path)")
  }

  @MainActor
  private static var snapshots: [Snapshot] {
    [
      Snapshot("library-grid") {
        NavigationStack {
          BookCollectionView(
            books: SnapshotFixtures.books,
            layout: .grid,
            filter: .all
          )
          .navigationTitle("Library")
        }
      },
      Snapshot("library-list") {
        NavigationStack {
          BookCollectionView(
            books: SnapshotFixtures.books,
            layout: .list,
            filter: .all
          )
          .navigationTitle("Library")
        }
      },
      Snapshot("favorites-empty") {
        NavigationStack {
          BookCollectionView(
            books: [],
            layout: .grid,
            filter: .all
          )
          .navigationTitle("Favorites")
        }
      },
      Snapshot("book-detail") {
        BookDetailContentView(
          book: SnapshotFixtures.detail,
          actions: BookActionViewData(
            canEmailToKindle: true,
            isFavorite: true,
            isRead: false,
            canShare: true,
            canDownload: true,
            canPlay: true
          )
        )
      },
      Snapshot("series-grid") {
        NavigationStack {
          SeriesContentView(
            series: SeriesViewData.groups(from: SnapshotFixtures.books)[0],
            layout: .grid,
            filter: .all
          )
        }
      },
      Snapshot("player-cover") {
        PlayerContentView(player: SnapshotFixtures.player, selectedTab: .cover)
      },
      Snapshot("player-chapters") {
        PlayerContentView(player: SnapshotFixtures.player, selectedTab: .chapters)
      },
      Snapshot(
        "library-grid-dark-compact", size: CGSize(width: 320, height: 568), colorScheme: .dark
      ) {
        NavigationStack {
          BookCollectionView(
            books: SnapshotFixtures.books,
            layout: .grid,
            filter: .all
          )
          .navigationTitle("Library")
        }
      },
    ]
  }

  @MainActor
  private static func render(_ snapshot: Snapshot, to outputDirectory: URL) throws {
    let view = snapshot.content()
      .frame(width: snapshot.size.width, height: snapshot.size.height)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, snapshot.colorScheme)

    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(origin: .zero, size: snapshot.size)
    hostingView.layoutSubtreeIfNeeded()

    guard
      let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    else {
      throw SnapshotError.renderFailed(snapshot.name)
    }
    representation.size = snapshot.size
    hostingView.cacheDisplay(in: hostingView.bounds, to: representation)

    guard
      let pngData = representation.representation(using: .png, properties: [:])
    else {
      throw SnapshotError.encodeFailed(snapshot.name)
    }

    try pngData.write(to: outputDirectory.appendingPathComponent("\(snapshot.name).png"))
  }
}

private enum SnapshotError: LocalizedError {
  case renderFailed(String)
  case encodeFailed(String)

  var errorDescription: String? {
    switch self {
    case .renderFailed(let name):
      "Failed to render \(name)."
    case .encodeFailed(let name):
      "Failed to encode \(name)."
    }
  }
}
