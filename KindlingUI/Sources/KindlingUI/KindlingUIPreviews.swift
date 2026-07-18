import SwiftUI

private enum PreviewData {
  static let palette = ArtworkPalette(red: 0.12, green: 0.62, blue: 0.64)
  static let warmPalette = ArtworkPalette(red: 0.73, green: 0.13, blue: 0.16)
  static let pinkPalette = ArtworkPalette(red: 0.78, green: 0.21, blue: 0.62)

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
      palette: warmPalette,
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
      palette: pinkPalette,
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

  static let detailMissingSeries = BookDetailViewData(
    id: "standalone",
    title: "Margo's Got Money Troubles",
    author: "Rufi Thorpe",
    usesSquareArtwork: true,
    palette: pinkPalette,
    durationText: "10h 28m",
    publishedYear: 2024,
    description:
      "A standalone preview with no series metadata and no narrator, used to verify hidden optional rows."
  )

  static let detailLongTitle = BookDetailViewData(
    id: "long-title",
    title: "The Extremely Inconvenient Adventures of a Very Particular Audiobook Listener",
    author: "A. Very Long Author Name",
    palette: warmPalette,
    durationText: "14h 02m",
    seriesTitle: "Long Running Preview Series",
    seriesPosition: 12,
    narrator: "A Narrator With a Considerably Long Name",
    publishedYear: 2026,
    description:
      "This fixture intentionally uses long strings so button labels, metadata, and titles can be checked in compact previews."
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

  static let playerTranscriptLoading = PlayerViewData(
    palette: warmPalette,
    bookCompletionPercent: 47,
    bookProgress: 0.47,
    currentChapterTitle: "Chapter 12",
    currentChapterProgress: 0.64,
    currentChapterElapsedText: "18:04",
    currentChapterRemainingText: "-10:12",
    isPlaying: true,
    playbackRateText: "1.25x",
    chapters: [
      ChapterRowViewData(
        id: 10, title: "Chapter 10", durationText: "21:14", progress: 1, isCompleted: true),
      ChapterRowViewData(
        id: 11, title: "Chapter 11", durationText: "17:02", progress: 1, isCompleted: true),
      ChapterRowViewData(
        id: 12, title: "Chapter 12", durationText: "28:16", progress: 0.64, isCurrent: true),
    ],
    transcriptStatusText: "Loading transcript..."
  )
}

extension View {
  fileprivate func compactPhonePreview() -> some View {
    frame(width: 320, height: 568)
  }

  fileprivate func largePhonePreview() -> some View {
    frame(width: 430, height: 932)
  }
}

#Preview("Library Grid - Populated") {
  NavigationStack {
    BookCollectionView(
      books: PreviewData.books,
      layout: .grid,
      filter: .all
    )
    .navigationTitle("Library")
  }
}

#Preview("Library List - Populated") {
  NavigationStack {
    BookCollectionView(
      books: PreviewData.books,
      layout: .list,
      filter: .all
    )
    .navigationTitle("Library")
  }
}

#Preview("Library Grid - Empty") {
  NavigationStack {
    BookCollectionView(
      books: [],
      layout: .grid,
      filter: .all
    )
    .navigationTitle("Library")
  }
}

#Preview("Favorites Grid - Populated") {
  NavigationStack {
    BookCollectionView(
      books: BookCollectionHelpers.favorites(from: PreviewData.books),
      layout: .grid,
      filter: .all
    )
    .navigationTitle("Favorites")
  }
}

#Preview("Favorites List - Populated") {
  NavigationStack {
    BookCollectionView(
      books: BookCollectionHelpers.favorites(from: PreviewData.books),
      layout: .list,
      filter: .all
    )
    .navigationTitle("Favorites")
  }
}

#Preview("Favorites Empty") {
  NavigationStack {
    BookCollectionView(
      books: [],
      layout: .grid,
      filter: .all
    )
    .navigationTitle("Favorites")
  }
}

#Preview("Book Detail - Full Metadata") {
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

#Preview("Book Detail - Missing Series") {
  BookDetailContentView(
    book: PreviewData.detailMissingSeries,
    actions: BookActionViewData(
      canEmailToKindle: true,
      isFavorite: false,
      isRead: false,
      canShare: true,
      canDownload: false,
      canPlay: true
    ),
    onAuthor: {}
  )
}

#Preview("Book Detail - Long Title Compact") {
  BookDetailContentView(
    book: PreviewData.detailLongTitle,
    actions: BookActionViewData(
      canEmailToKindle: true,
      isFavorite: true,
      isRead: true,
      canShare: true,
      canDownload: true,
      canPlay: true
    )
  )
  .compactPhonePreview()
}

#Preview("Series Grid") {
  NavigationStack {
    SeriesContentView(
      series: SeriesViewData.groups(from: PreviewData.books)[0],
      layout: .grid,
      filter: .all
    )
  }
}

#Preview("Series List") {
  NavigationStack {
    SeriesContentView(
      series: SeriesViewData.groups(from: PreviewData.books)[0],
      layout: .list,
      filter: .all
    )
  }
}

#Preview("Works by Author") {
  NavigationStack {
    BookGroupContentView(
      title: "Works by J.K. Rowling",
      books: [
        PreviewData.books[0],
        PreviewData.books[1],
        BookTileViewData(
          id: "openlibrary-casual-vacancy",
          title: "The Casual Vacancy",
          author: "J.K. Rowling",
          isInLibrary: false,
          publishedYear: 2012
        ),
      ],
      layout: .list,
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

#Preview("Player Transcript - Loading") {
  PlayerContentView(player: PreviewData.playerTranscriptLoading, selectedTab: .transcript)
}

#Preview("Player Transcript - Unavailable") {
  PlayerContentView(player: PreviewData.player, selectedTab: .transcript)
}

#Preview("Library Grid - Dark Compact") {
  NavigationStack {
    BookCollectionView(
      books: PreviewData.books,
      layout: .grid,
      filter: .all
    )
    .navigationTitle("Library")
  }
  .preferredColorScheme(.dark)
  .compactPhonePreview()
}

#Preview("Book Detail - Light Large") {
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
  .preferredColorScheme(.light)
  .largePhonePreview()
}
