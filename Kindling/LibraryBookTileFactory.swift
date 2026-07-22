import Foundation
import KindlingUI

struct LibraryBookTileFactory {
  let assetBaseURLString: String
  let progress: (LibraryBook) -> Double?
  let palette: (URL?) -> ArtworkPalette
  let durationText: (Int) -> String

  func make(for book: LibraryBook) -> BookTileViewData {
    let artworkURL = remoteLibraryAssetURL(
      baseURLString: assetBaseURLString,
      path: book.coverURLString,
      versionToken: book.updatedAt.map { String(Int($0.timeIntervalSince1970)) }
    )
    let playbackProgress = progress(book)

    return BookTileViewData(
      id: book.podibleId,
      title: book.title,
      author: book.author?.name ?? "Unknown Author",
      artworkURL: artworkURL,
      durationText: book.runtimeSeconds.map(durationText),
      progress: playbackProgress,
      isRead: book.localState?.isRead == true,
      isFavorite: isSavedBookState(book.localState, progress: playbackProgress),
      palette: palette(artworkURL),
      seriesKey: book.series?.podibleId,
      seriesTitle: book.series?.title,
      seriesPosition: book.seriesIndex,
      publishedYear: book.publishedYear,
      narrator: book.narrator,
      description: book.summary
    )
  }

  func make(for item: PodibleLibraryItem) -> BookTileViewData {
    let artworkURL = remoteLibraryAssetURL(
      baseURLString: assetBaseURLString,
      path: item.bookImagePath,
      versionToken: item.updatedAt.map { String(Int($0.timeIntervalSince1970)) }
    )
    return BookTileViewData(
      id: item.id,
      title: item.title,
      author: item.author,
      artworkURL: artworkURL,
      durationText: item.runtimeSeconds.map(durationText),
      palette: palette(artworkURL),
      seriesKey: item.seriesKey,
      seriesTitle: item.seriesTitle,
      seriesPosition: item.seriesPosition,
      publishedYear: item.publishedYear,
      narrator: item.narrator,
      description: item.summary
    )
  }

  func make(for book: LibraryBook, group route: BookGroupRoute) -> BookTileViewData {
    var memberships = podibleSeriesMemberships(from: book.seriesMembershipsJSON)
    if memberships.isEmpty, let series = book.series {
      memberships = [
        PodibleBookSeriesMembership(
          key: series.podibleId,
          name: series.title,
          position: book.seriesIndex.map { String($0) }
        )
      ]
    }
    return applyingSeriesMembership(to: make(for: book), memberships: memberships, group: route)
  }

  func applyingSeriesMembership(
    to tile: BookTileViewData,
    memberships: [PodibleBookSeriesMembership],
    group route: BookGroupRoute
  ) -> BookTileViewData {
    guard case .series(let series) = route,
      let membership = podibleSeriesMembership(
        matchingSeriesKey: series.seriesKey,
        seriesTitle: series.title,
        in: memberships
      )
    else { return tile }

    var tile = tile
    tile.seriesKey = membership.key
    tile.seriesTitle = membership.name
    tile.seriesPosition = membership.numericPosition
    return tile
  }

  func make(for book: PodibleOpenLibraryBook, group route: BookGroupRoute) -> BookTileViewData {
    let membership: PodibleBookSeriesMembership?
    switch route {
    case .series(let series):
      membership = podibleSeriesMembership(
        matchingSeriesKey: series.seriesKey,
        seriesTitle: series.title,
        in: book.series
      )
    case .author:
      membership = book.series.first
    }
    let artworkURL = book.coverID.flatMap {
      URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg")
    }
    return BookTileViewData(
      id: "openlibrary:\(book.openLibraryKey)",
      title: book.title,
      author: book.author,
      artworkURL: artworkURL,
      isInLibrary: false,
      palette: palette(artworkURL),
      seriesKey: membership?.key,
      seriesTitle: membership?.name,
      seriesPosition: membership?.numericPosition,
      publishedYear: book.publishedYear
    )
  }
}
