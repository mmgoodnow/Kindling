import SwiftUI

private enum PreviewData {
  static let palette = ArtworkPalette(red: 0.12, green: 0.62, blue: 0.64)

  static let books: [BookTileViewData] = [
    BookTileViewData(
      id: "hp1",
      title: "Harry Potter and the Philosopher's Stone",
      author: "J.K. Rowling",
      usesSquareArtwork: false,
      durationText: "8h 17m",
      isRead: false,
      isFavorite: true,
      palette: palette,
      seriesKey: "harry-potter",
      seriesTitle: "Harry Potter",
      seriesPosition: 1,
      publishedYear: 1997,
      narrator: "Jim Dale",
      description: "A quiet fixture description that gives the detail view enough text to wrap."
    ),
    BookTileViewData(
      id: "hp2",
      title: "Harry Potter and the Chamber of Secrets",
      author: "J.K. Rowling",
      usesSquareArtwork: false,
      durationText: "9h 3m",
      isRead: true,
      isFavorite: true,
      palette: ArtworkPalette(red: 0.73, green: 0.13, blue: 0.16),
      seriesKey: "harry-potter",
      seriesTitle: "Harry Potter",
      seriesPosition: 2,
      publishedYear: 1998
    ),
    BookTileViewData(
      id: "standalone",
      title: "Margo's Got Money Troubles",
      author: "Rufi Thorpe",
      usesSquareArtwork: true,
      durationText: "10h 28m",
      palette: ArtworkPalette(red: 0.78, green: 0.21, blue: 0.62),
      publishedYear: 2024
    ),
  ]

  static let detail = BookDetailViewData(
    id: "hp1",
    title: "Harry Potter and the Philosopher's Stone",
    author: "J.K. Rowling",
    palette: palette,
    durationText: "8h 17m",
    seriesTitle: "Harry Potter",
    seriesPosition: 1,
    narrator: "Jim Dale",
    publishedYear: 1997,
    description:
      "Turning the envelope over, his hand trembling, Harry saw a purple wax seal. An adventure is about to begin."
  )

  static let player = PlayerViewData(
    palette: palette,
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
    ],
    transcriptStatusText: "Transcript unavailable"
  )
}

#Preview("Library Grid") {
  NavigationStack {
    BookCollectionView(
      books: PreviewData.books,
      layout: .grid,
      filter: .all
    )
    .navigationTitle("Library")
  }
}

#Preview("Favorites List") {
  NavigationStack {
    BookCollectionView(
      books: BookCollectionHelpers.favorites(from: PreviewData.books),
      layout: .list,
      filter: .all
    )
    .navigationTitle("Favorites")
  }
}

#Preview("Book Detail") {
  BookDetailContentView(
    book: PreviewData.detail,
    actions: BookActionViewData(
      canEmailToKindle: true,
      isFavorite: true,
      isRead: false,
      canShare: true,
      canDownload: true,
      canPlay: true
    )
  )
}

#Preview("Series") {
  NavigationStack {
    SeriesContentView(
      series: SeriesViewData.groups(from: PreviewData.books)[0],
      layout: .grid,
      filter: .all
    )
  }
}

#Preview("Player Cover") {
  PlayerContentView(player: PreviewData.player, selectedTab: .cover)
}

#Preview("Player Chapters") {
  PlayerContentView(player: PreviewData.player, selectedTab: .chapters)
}
