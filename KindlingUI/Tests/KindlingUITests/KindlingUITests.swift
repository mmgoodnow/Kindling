import XCTest

@testable import KindlingUI

final class KindlingUITests: XCTestCase {
  private let books: [BookTileViewData] = [
    BookTileViewData(
      id: "second",
      title: "Second Book",
      author: "Author",
      durationText: "9h",
      isRead: true,
      isFavorite: true,
      seriesKey: "series",
      seriesTitle: "Series",
      seriesPosition: 2
    ),
    BookTileViewData(
      id: "first",
      title: "First Book",
      author: "Author",
      durationText: "8h",
      isRead: false,
      isFavorite: false,
      seriesKey: "series",
      seriesTitle: "Series",
      seriesPosition: 1
    ),
    BookTileViewData(
      id: "standalone",
      title: "Standalone",
      author: "Author",
      durationText: "6h",
      isRead: false,
      isFavorite: true
    ),
  ]

  func testReadFilterKeepsExpectedBooks() {
    XCTAssertEqual(
      BookCollectionFilter.all.filtered(books).map(\.id),
      [
        "second", "first", "standalone",
      ])
    XCTAssertEqual(
      BookCollectionFilter.unread.filtered(books).map(\.id),
      [
        "first", "standalone",
      ])
    XCTAssertEqual(BookCollectionFilter.read.filtered(books).map(\.id), ["second"])
  }

  func testReadFiltersExcludeBooksOutsideLibrary() {
    let external = BookTileViewData(
      id: "external",
      title: "External",
      author: "Author",
      isInLibrary: false
    )

    XCTAssertEqual(BookCollectionFilter.all.filtered([external]).map(\.id), ["external"])
    XCTAssertTrue(BookCollectionFilter.unread.filtered([external]).isEmpty)
    XCTAssertTrue(BookCollectionFilter.read.filtered([external]).isEmpty)
  }

  func testSeriesDefaultLayoutIsList() {
    XCTAssertEqual(BookCollectionLayout.seriesDefault, .list)
  }

  func testFavoritesFilteringKeepsLocalFavorites() {
    XCTAssertEqual(
      BookCollectionHelpers.favorites(from: books).map(\.id),
      [
        "second", "standalone",
      ])
  }

  func testSeriesGroupingOrdersBySeriesPositionThenTitle() {
    let groups = SeriesViewData.groups(from: books)

    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups[0].id, "series")
    XCTAssertEqual(groups[0].title, "Series")
    XCTAssertEqual(groups[0].books.map(\.id), ["first", "second"])
  }

  func testBookTileMetadataIncludesSeriesPosition() {
    XCTAssertEqual(books[0].secondaryMetadataText, "Author  ·  #2")
    XCTAssertEqual(books[2].secondaryMetadataText, "Author")
  }

  func testDurationFormatting() {
    XCTAssertNil(KindlingUIFormatters.durationText(seconds: nil))
    XCTAssertNil(KindlingUIFormatters.durationText(seconds: 0))
    XCTAssertEqual(KindlingUIFormatters.durationText(seconds: 59 * 60), "59m")
    XCTAssertEqual(KindlingUIFormatters.durationText(seconds: 60 * 60), "1h")
    XCTAssertEqual(KindlingUIFormatters.durationText(seconds: 75 * 60), "1h 15m")
  }

  func testPlaybackFormattingAndProgress() {
    XCTAssertEqual(KindlingUIFormatters.playbackTime(65), "1:05")
    XCTAssertEqual(KindlingUIFormatters.playbackTime(3_665), "1:01:05")
    XCTAssertEqual(KindlingUIFormatters.percent(currentTime: 30, duration: 100), 30)
    XCTAssertEqual(KindlingUIFormatters.progress(currentTime: 150, duration: 100), 1)
    XCTAssertEqual(KindlingUIFormatters.seriesPositionText(2), "#2")
    XCTAssertEqual(KindlingUIFormatters.seriesPositionText(2.5), "#2.5")
  }

  func testDetailMetadataFormatting() {
    let detail = BookDetailViewData(
      id: "detail",
      title: "Detail",
      author: "Author",
      seriesTitle: "Series",
      seriesPosition: 3,
      narrator: "Narrator",
      publishedYear: 2026
    )

    XCTAssertEqual(detail.metadataText, "Narrated by Narrator    2026")
    XCTAssertEqual(detail.seriesText, "#3 in Series")
    XCTAssertNil(
      BookDetailViewData(id: "missing", title: "Missing", author: "Author").metadataText)
  }

  func testMiniPlayerPresentationAdaptsControlsAndArtworkSize() {
    XCTAssertTrue(MiniPlayerPresentation.expanded.showsSkipForward)
    XCTAssertFalse(MiniPlayerPresentation.inline.showsSkipForward)
    XCTAssertGreaterThan(
      MiniPlayerPresentation.expanded.artworkSize,
      MiniPlayerPresentation.inline.artworkSize
    )
  }

  func testAutoReadThreshold() {
    XCTAssertFalse(ReadProgressPolicy.shouldMarkRead(currentTime: 994, duration: 1_000))
    XCTAssertTrue(ReadProgressPolicy.shouldMarkRead(currentTime: 995, duration: 1_000))
    XCTAssertTrue(ReadProgressPolicy.shouldMarkRead(currentTime: 1_100, duration: 1_000))
    XCTAssertFalse(ReadProgressPolicy.shouldMarkRead(currentTime: 0, duration: 0))
  }
}
