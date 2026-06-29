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

  func testAutoReadThreshold() {
    XCTAssertFalse(ReadProgressPolicy.shouldMarkRead(currentTime: 994, duration: 1_000))
    XCTAssertTrue(ReadProgressPolicy.shouldMarkRead(currentTime: 995, duration: 1_000))
    XCTAssertTrue(ReadProgressPolicy.shouldMarkRead(currentTime: 1_100, duration: 1_000))
    XCTAssertFalse(ReadProgressPolicy.shouldMarkRead(currentTime: 0, duration: 0))
  }
}
