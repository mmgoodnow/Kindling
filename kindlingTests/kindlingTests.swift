import CoreGraphics
import Foundation
import KindlingUI
import SwiftData
import XCTest

@testable import Kindling

final class kindlingTests: XCTestCase {
  private let resumePositionKeyPrefix = "audioPlayer.resumePosition."

  func testArtworkPaletteSamplerReadsDominantColor() throws {
    let image = try solidImage(red: 204, green: 34, blue: 17)
    let palette = try XCTUnwrap(ArtworkPaletteSampler.palette(from: image))

    XCTAssertEqual(palette.red, 0.80, accuracy: 0.02)
    XCTAssertEqual(palette.green, 0.13, accuracy: 0.02)
    XCTAssertEqual(palette.blue, 0.07, accuracy: 0.02)
  }

  func testArtworkPaletteSamplerFallsBackToNeutralArtAverage() throws {
    let image = try solidImage(red: 180, green: 180, blue: 180)
    let palette = try XCTUnwrap(ArtworkPaletteSampler.palette(from: image))

    XCTAssertEqual(palette.red, 0.71, accuracy: 0.02)
    XCTAssertEqual(palette.green, 0.71, accuracy: 0.02)
    XCTAssertEqual(palette.blue, 0.71, accuracy: 0.02)
  }

  func testArtworkPaletteCacheRoundTripsAndPrunesStoredPalettes() throws {
    let suiteName = "KindlingTests.ArtworkPaletteCache.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let cache = ArtworkPaletteCache(defaults: defaults)
    let retainedKey = "https://example.com/retained.jpg?v=1"
    let removedKey = "https://example.com/removed.jpg?v=1"
    let retainedPalette = ArtworkPalette(red: 0.12, green: 0.34, blue: 0.56)

    cache.store(retainedPalette, for: retainedKey)
    cache.store(ArtworkPalette(red: 0.8, green: 0.7, blue: 0.6), for: removedKey)

    XCTAssertEqual(cache.palette(for: retainedKey), retainedPalette)
    cache.removePalettes(excluding: [retainedKey])
    XCTAssertEqual(cache.palette(for: retainedKey), retainedPalette)
    XCTAssertNil(cache.palette(for: removedKey))
  }

  func testLibrarySyncCancellationDoesNotProduceUserFacingError() {
    XCTAssertNil(librarySyncErrorMessage(for: CancellationError()))
    XCTAssertNil(librarySyncErrorMessage(for: URLError(.cancelled)))
  }

  func testLibrarySyncFailureRemainsUserFacing() {
    let error = URLError(.notConnectedToInternet)

    XCTAssertEqual(librarySyncErrorMessage(for: error), error.localizedDescription)
  }

  func testMiniPlayerUsesCurrentChapterAndRemainingTime() {
    let chapters = [
      AudioPlayerController.Chapter(id: 0, title: "Chapter 2", startTime: 0, duration: 600),
      AudioPlayerController.Chapter(
        id: 1,
        title: "Chapter 3",
        startTime: 600,
        duration: 1_200
      ),
    ]

    XCTAssertEqual(
      miniPlayerViewData(
        bookTitle: "Wool",
        author: "Hugh Howey",
        isPlaying: true,
        chapters: chapters,
        currentTime: 1_200,
        totalDuration: 1_800
      ),
      MiniPlayerViewData(
        primaryText: "Chapter 3  •  10 mins left",
        secondaryText: "Wool  •  Hugh Howey",
        isPlaying: true
      )
    )
  }

  func testMiniPlayerFallsBackToBookMetadataWithoutChapters() {
    XCTAssertEqual(
      miniPlayerViewData(
        bookTitle: "Wool",
        author: "Hugh Howey",
        isPlaying: false,
        chapters: [],
        currentTime: 300,
        totalDuration: 1_800
      ),
      MiniPlayerViewData(
        primaryText: "Wool",
        secondaryText: "Hugh Howey",
        isPlaying: false
      )
    )
  }

  func testLibraryItemDecodesSeriesMembership() throws {
    let data = try XCTUnwrap(
      """
      {
        "id": "42",
        "bookname": "The Second Book",
        "authorname": "An Author",
        "description": "A plain description.",
        "descriptionHtml": "<p>A <strong>rich</strong> description.</p>",
        "status": "have",
        "series": [
          { "key": "OL123L", "name": "The Series", "position": "2" }
        ]
      }
      """.data(using: .utf8)
    )

    let item = try JSONDecoder().decode(PodibleLibraryItem.self, from: data)

    XCTAssertEqual(
      item.series, [PodibleBookSeriesMembership(key: "OL123L", name: "The Series", position: "2")])
    XCTAssertEqual(item.seriesKey, "OL123L")
    XCTAssertEqual(item.seriesTitle, "The Series")
    XCTAssertEqual(item.seriesPosition, 2)
    XCTAssertEqual(item.descriptionHTML, "<p>A <strong>rich</strong> description.</p>")
  }

  func testSeriesMembershipMatchesTheActiveSeriesInsteadOfTheFirstMembership() {
    let memberships = [
      PodibleBookSeriesMembership(key: "OL-OTHER", name: "Other Series", position: "8"),
      PodibleBookSeriesMembership(key: "OL-DCC", name: "Dungeon Crawler Carl", position: "3"),
    ]

    XCTAssertEqual(
      podibleSeriesMembership(
        matchingSeriesKey: "OL-DCC",
        seriesTitle: "Dungeon Crawler Carl",
        in: memberships
      ),
      memberships[1]
    )
  }

  func testSeriesMembershipFallsBackToCaseInsensitiveTitleMatch() {
    let membership = PodibleBookSeriesMembership(
      key: nil,
      name: "Dungeon Crawler Carl",
      position: "4"
    )

    XCTAssertEqual(
      podibleSeriesMembership(
        matchingSeriesKey: nil,
        seriesTitle: "dungeon crawler carl",
        in: [membership]
      ),
      membership
    )
  }

  @MainActor
  func testMarkdownDescriptionRendererPreservesFormatting() throws {
    let rendered = try XCTUnwrap(
      markdownDescriptionAttributedString(
        markdown: "A **rich** description.\n\nSecond paragraph with [a link](https://example.com)."
      )
    )

    let text = String(rendered.characters)
    XCTAssertTrue(text.contains("A rich description."))
    XCTAssertTrue(text.contains("Second paragraph with a link."))
    XCTAssertTrue(
      rendered.runs.contains {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
      }
    )
    XCTAssertTrue(rendered.runs.contains { $0.link == URL(string: "https://example.com") })
  }

  @MainActor
  func testMarkdownDescriptionRendererPreservesParagraphSeparators() throws {
    let rendered = try XCTUnwrap(
      markdownDescriptionAttributedString(
        markdown:
          "**New Achievement! Total, Utter Failure.**\r\n\r\nYou failed a quest.\r\n\r\nA floating fortress."
      )
    )

    XCTAssertEqual(
      String(rendered.characters),
      "New Achievement! Total, Utter Failure.\n\nYou failed a quest.\n\nA floating fortress."
    )
  }

  func testMarkdownDescriptionNormalizationRemovesCarriageReturnsAndLineBackslashes() {
    let description =
      "First sentence.\\\r\nSecond sentence.\\\r\n\\\r\nSecond paragraph.\\\r\n"

    XCTAssertEqual(
      normalizedMarkdownDescription(description),
      "First sentence. Second sentence.\n\nSecond paragraph."
    )
  }

  @MainActor
  func testLibraryBookPersistsRemotePresentationMetadata() throws {
    let schema = Schema([
      Author.self,
      Series.self,
      LibraryBook.self,
      LibraryBookFile.self,
      LocalBookState.self,
      LibrarySyncState.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = container.mainContext
    let seriesMemberships = [
      PodibleBookSeriesMembership(key: "OL123L", name: "The Series", position: "2"),
      PodibleBookSeriesMembership(key: "OL456L", name: "The Crossover", position: "1"),
    ]
    context.insert(
      LibraryBook(
        podibleId: "42",
        title: "The Second Book",
        descriptionHTML: "<p>A <strong>rich</strong> description.</p>",
        fullPseudoProgress: 63,
        seriesMembershipsJSON: podibleSeriesMembershipsData(seriesMemberships)
      )
    )
    try context.save()

    let persisted = try XCTUnwrap(context.fetch(FetchDescriptor<LibraryBook>()).first)
    XCTAssertEqual(
      persisted.descriptionHTML,
      "<p>A <strong>rich</strong> description.</p>"
    )
    XCTAssertEqual(persisted.fullPseudoProgress, 63)
    XCTAssertEqual(
      podibleSeriesMemberships(from: persisted.seriesMembershipsJSON),
      seriesMemberships
    )
  }

  func testLibrarySeriesResponseDecodesOpenLibraryBooks() throws {
    let data = try XCTUnwrap(
      """
      {
        "series": { "key": "OL123L", "name": "The Series", "position": null },
        "libraryBooks": [],
        "openLibraryBooks": [
          {
            "openLibraryKey": "/works/OL456W",
            "title": "The First Book",
            "author": "An Author",
            "publishedAt": "2024",
            "coverId": 123,
            "series": [
              { "key": "OL123L", "name": "The Series", "position": "1" }
            ]
          }
        ]
      }
      """.data(using: .utf8)
    )

    let response = try JSONDecoder().decode(PodibleLibrarySeriesRPCResult.self, from: data)

    XCTAssertEqual(response.series.name, "The Series")
    XCTAssertEqual(response.openLibraryBooks.map(\.openLibraryKey), ["/works/OL456W"])
    XCTAssertEqual(response.openLibraryBooks.first?.series.first?.numericPosition, 1)
  }

  func testLibraryAuthorResponseDecodesOwnedAndOpenLibraryBooks() throws {
    let data = try XCTUnwrap(
      """
      {
        "author": "Hugh Howey",
        "libraryBooks": [],
        "openLibraryBooks": [
          {
            "openLibraryKey": "/works/OL17377506W",
            "title": "Sand",
            "author": "Hugh Howey",
            "publishedAt": "2014-01-01T00:00:00.000Z",
            "coverId": 456,
            "series": []
          }
        ]
      }
      """.data(using: .utf8)
    )

    let response = try JSONDecoder().decode(PodibleLibraryAuthorRPCResult.self, from: data)

    XCTAssertEqual(response.author, "Hugh Howey")
    XCTAssertEqual(response.openLibraryBooks.map(\.openLibraryKey), ["/works/OL17377506W"])
    XCTAssertEqual(response.openLibraryBooks.first?.author, "Hugh Howey")
  }

  func testBookSeriesRouteFormatsNumericAndFreeformPositions() {
    XCTAssertEqual(
      BookSeriesRoute(id: "one", title: "Series", seriesKey: "one", position: "2").displayText,
      "#2 in Series"
    )
    XCTAssertEqual(
      BookSeriesRoute(
        id: "two",
        title: "Series",
        seriesKey: "two",
        position: "Prequel"
      ).displayText,
      "Prequel in Series"
    )
  }

  func testAuthorRouteUsesWorksByTitle() {
    let author = BookAuthorRoute(name: "Hugh Howey")

    XCTAssertEqual(author.title, "Works by Hugh Howey")
    XCTAssertEqual(BookGroupRoute.author(author).title, "Works by Hugh Howey")
  }

  func testRelatedBookIdentityNormalizesAuthorAndTitleForDeduplication() {
    XCTAssertEqual(
      relatedBookIdentity(title: "  The   Résumé  ", author: "AN AUTHOR"),
      relatedBookIdentity(title: "the resume", author: "an author")
    )
  }

  func testManifestationResumeIDPreservesLegacyPlaybackPosition() {
    let legacyResumeID = "OL123W"
    let manifestationResumeID = "\(legacyResumeID)#manifestation-456"
    let identity = PlaybackIdentity(canonicalID: manifestationResumeID)
    let expectedPosition = 3_218.5
    let defaults = UserDefaults.standard
    let sessionKey = "audioPlayer.lastSession"
    let legacyKey = resumePositionKeyPrefix + legacyResumeID
    let manifestationKey = resumePositionKeyPrefix + manifestationResumeID
    defaults.removeObject(forKey: sessionKey)
    defaults.removeObject(forKey: legacyKey)
    defaults.removeObject(forKey: manifestationKey)
    defer {
      defaults.removeObject(forKey: sessionKey)
      defaults.removeObject(forKey: legacyKey)
      defaults.removeObject(forKey: manifestationKey)
    }
    defaults.set(expectedPosition, forKey: legacyKey)
    defaults.set(0, forKey: manifestationKey)

    let player = AudioPlayerController()
    player.load(
      url: URL(fileURLWithPath: "/tmp/kindling-regression-audio.m4b"),
      identity: identity,
      title: "Regression Test"
    )

    XCTAssertEqual(player.progress.currentTime, expectedPosition, accuracy: 0.001)
  }

  func testResumeIDAliasesPreserveProgressAcrossBookIdentityChanges() {
    let openLibraryResumeID = "OL123W#manifestation-456"
    let openLibraryLegacyResumeID = "OL123W"
    let podibleResumeID = "podible-123#manifestation-456"
    let identity = PlaybackIdentity(
      openLibraryWorkID: openLibraryLegacyResumeID,
      podibleID: "podible-123",
      manifestationID: 456
    )
    let expectedPosition = 3_218.5
    let defaults = UserDefaults.standard
    let sessionKey = "audioPlayer.lastSession"
    let openLibraryKey = resumePositionKeyPrefix + openLibraryResumeID
    let openLibraryLegacyKey = resumePositionKeyPrefix + openLibraryLegacyResumeID
    let podibleKey = resumePositionKeyPrefix + podibleResumeID
    defaults.removeObject(forKey: sessionKey)
    defaults.removeObject(forKey: openLibraryKey)
    defaults.removeObject(forKey: openLibraryLegacyKey)
    defaults.removeObject(forKey: podibleKey)
    defer {
      defaults.removeObject(forKey: sessionKey)
      defaults.removeObject(forKey: openLibraryKey)
      defaults.removeObject(forKey: openLibraryLegacyKey)
      defaults.removeObject(forKey: podibleKey)
    }
    defaults.set(expectedPosition, forKey: openLibraryKey)
    defaults.set(0, forKey: podibleKey)

    let player = AudioPlayerController()
    player.load(
      url: URL(fileURLWithPath: "/tmp/kindling-regression-audio.m4b"),
      identity: identity,
      title: "Regression Test"
    )

    XCTAssertEqual(player.progress.currentTime, expectedPosition, accuracy: 0.001)
    XCTAssertEqual(defaults.double(forKey: openLibraryKey), expectedPosition, accuracy: 0.001)
    XCTAssertEqual(defaults.double(forKey: podibleKey), expectedPosition, accuracy: 0.001)
  }

  func testPersistedProgressLookupDoesNotRewriteResumeAliases() throws {
    let identity = PlaybackIdentity(
      openLibraryWorkID: "OL123W",
      podibleID: "podible-123",
      manifestationID: 456
    )
    let expectedPosition = 1_234.5
    let defaults = UserDefaults.standard
    let keys = identity.allResumeIDs.map { resumePositionKeyPrefix + $0 }
    for key in keys {
      defaults.removeObject(forKey: key)
    }
    defer {
      for key in keys {
        defaults.removeObject(forKey: key)
      }
    }
    defaults.set(expectedPosition, forKey: resumePositionKeyPrefix + "OL123W")

    let player = AudioPlayerController()
    let progress = try XCTUnwrap(
      player.persistedProgress(identity: identity, duration: 2_469)
    )

    XCTAssertEqual(progress, 0.5, accuracy: 0.001)
    XCTAssertNil(defaults.object(forKey: resumePositionKeyPrefix + identity.canonicalID))
    XCTAssertNil(defaults.object(forKey: resumePositionKeyPrefix + "podible-123"))
    XCTAssertNil(
      defaults.object(forKey: resumePositionKeyPrefix + "podible-123#manifestation-456")
    )
  }

  func testPlaybackIdentityIncludesCanonicalAliasesAndLegacyFallbacks() {
    let identity = PlaybackIdentity(
      openLibraryWorkID: "OL123W",
      podibleID: "podible-123",
      manifestationID: 456
    )

    XCTAssertEqual(identity.canonicalID, "OL123W#manifestation-456")
    XCTAssertEqual(
      identity.allResumeIDs,
      [
        "OL123W#manifestation-456",
        "OL123W",
        "podible-123",
        "podible-123#manifestation-456",
      ]
    )
    XCTAssertTrue(identity.matches("podible-123#manifestation-456"))
    XCTAssertTrue(identity.matches("podible-123"))
    XCTAssertFalse(identity.matches("other-book"))
  }

  private func solidImage(red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
    let width = 8
    let height = 8
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
      pixels[offset] = red
      pixels[offset + 1] = green
      pixels[offset + 2] = blue
      pixels[offset + 3] = 255
    }

    let data = Data(pixels) as CFData
    let provider = try XCTUnwrap(CGDataProvider(data: data))
    let bitmapInfo = CGBitmapInfo(
      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )
    return try XCTUnwrap(
      CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    )
  }
}
