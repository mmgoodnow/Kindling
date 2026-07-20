import CoreGraphics
import Foundation
import KindlingUI
import SwiftData
import XCTest

@testable import Kindling

@MainActor
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

  func testPlaybackRemainingTextUsesFriendlyMinutes() {
    XCTAssertEqual(playbackRemainingText(12 * 60 + 25), "12 mins left")
    XCTAssertEqual(playbackRemainingText(12 * 60), "12 mins left")
    XCTAssertEqual(playbackRemainingText(60), "1 min left")
    XCTAssertEqual(playbackRemainingText(25), "<1 min left")
  }

  func testPlaybackRatePersistsAcrossPlayerInstances() throws {
    let suiteName = "KindlingTests.PlaybackRate.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let player = AudioPlayerController(defaults: defaults)
    player.setPlaybackRate(1.5)

    let restoredPlayer = AudioPlayerController(defaults: defaults)
    XCTAssertEqual(restoredPlayer.playbackRate, 1.5)
  }

  func testTranscriptStatusDecodesGenerationState() throws {
    let status = try JSONDecoder().decode(
      PodibleTranscriptStatus.self,
      from: Data(#"{"status":"running","error":null}"#.utf8)
    )

    XCTAssertEqual(status, PodibleTranscriptStatus(status: .running, error: nil))
  }

  func testPlaybackIdentityRetainsTranscriptRequestTarget() {
    let identity = PlaybackIdentity(
      openLibraryWorkID: "OL123W",
      podibleID: "42",
      manifestationID: 7
    )

    XCTAssertEqual(identity.podibleID, "42")
    XCTAssertEqual(identity.manifestationID, 7)
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
      "Series 2"
    )
    XCTAssertEqual(
      BookSeriesRoute(
        id: "two",
        title: "Series",
        seriesKey: "two",
        position: "Prequel"
      ).displayText,
      "Series Prequel"
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

  func testNewOnPodibleExcludesFavoriteAndReadBooks() {
    XCTAssertTrue(belongsInNewOnPodible(isFavorite: false, isRead: false))
    XCTAssertFalse(belongsInNewOnPodible(isFavorite: true, isRead: false))
    XCTAssertFalse(belongsInNewOnPodible(isFavorite: false, isRead: true))
    XCTAssertFalse(belongsInNewOnPodible(isFavorite: true, isRead: true))
  }

  func testContinueReadingUsesPersistedProgress() {
    XCTAssertTrue(belongsInContinueReading(progress: 0.25, isRead: false))
    XCTAssertFalse(belongsInContinueReading(progress: nil, isRead: false))
    XCTAssertFalse(belongsInContinueReading(progress: 0, isRead: false))
    XCTAssertFalse(belongsInContinueReading(progress: 0.25, isRead: true))
    XCTAssertFalse(belongsInContinueReading(progress: 1, isRead: false))
  }

  func testTBRExcludesBooksWithPersistedProgress() {
    XCTAssertTrue(belongsInTBR(isFavorite: true, isRead: false, progress: nil))
    XCTAssertTrue(belongsInTBR(isFavorite: true, isRead: false, progress: 0))
    XCTAssertFalse(belongsInTBR(isFavorite: true, isRead: false, progress: 0.25))
    XCTAssertFalse(belongsInTBR(isFavorite: true, isRead: true, progress: 0))
    XCTAssertFalse(belongsInTBR(isFavorite: false, isRead: false, progress: 0))
  }

  func testMarkingReadFavoritesBookWithoutChangingProgress() {
    let resumeKey = resumePositionKeyPrefix + "book"
    UserDefaults.standard.set(1_234.5, forKey: resumeKey)
    defer { UserDefaults.standard.removeObject(forKey: resumeKey) }
    let state = LocalBookState(
      bookPodibleId: "book",
      isFavorite: false,
      isRead: false,
      progressSeconds: 1_234.5
    )

    setReadState(true, on: state)

    XCTAssertEqual(state.isRead, true)
    XCTAssertEqual(state.isFavorite, true)
    XCTAssertEqual(state.progressSeconds, 1_234.5)
    XCTAssertEqual(UserDefaults.standard.double(forKey: resumeKey), 1_234.5)
  }

  func testMarkingUnreadKeepsBookFavoritedAndPreservesProgress() {
    let state = LocalBookState(
      bookPodibleId: "book",
      isFavorite: true,
      isRead: true,
      progressSeconds: 1_234.5
    )

    setReadState(false, on: state)

    XCTAssertEqual(state.isRead, false)
    XCTAssertEqual(state.isFavorite, true)
    XCTAssertEqual(state.progressSeconds, 1_234.5)
  }

  func testReadBookIsSavedEvenWithLegacyFavoriteState() {
    let state = LocalBookState(bookPodibleId: "book", isFavorite: false, isRead: true)

    XCTAssertTrue(isSavedBookState(state))
  }

  func testBookInProgressIsSavedWithoutExplicitFavoriteState() {
    let state = LocalBookState(bookPodibleId: "book", isFavorite: false, isRead: false)

    XCTAssertTrue(isSavedBookState(state, progress: 0.25))
    XCTAssertFalse(isSavedBookState(state, progress: 0))
    XCTAssertFalse(isSavedBookState(state, progress: nil))
  }

  func testLibraryCollectionsHaveStableTitles() {
    XCTAssertEqual(
      LibraryCollection.allCases.map(\.title),
      ["Continue reading", "TBR", "New on Podible", "Recently Viewed", "Read"]
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

  @MainActor
  func testV1StoreMigratesToPlaybackStateSchemaWithoutLosingLibraryState() throws {
    let storeURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("KindlingMigration-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-shm", "-wal"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
      }
    }

    do {
      let configuration = ModelConfiguration(
        "migration-test",
        schema: Schema(versionedSchema: KindlingSchemaV1.self),
        url: storeURL
      )
      let container = try ModelContainer(
        for: Schema(versionedSchema: KindlingSchemaV1.self),
        configurations: [configuration]
      )
      let book = LibraryBook(podibleId: "book", title: "Preserved Book")
      let state = LocalBookState(
        bookPodibleId: "book",
        isFavorite: true,
        progressSeconds: 987.5,
        book: book
      )
      container.mainContext.insert(book)
      container.mainContext.insert(state)
      try container.mainContext.save()
    }

    let configuration = ModelConfiguration(
      "migration-test",
      schema: Schema(versionedSchema: KindlingSchemaV2.self),
      url: storeURL
    )
    let container = try ModelContainer(
      for: Schema(versionedSchema: KindlingSchemaV2.self),
      migrationPlan: KindlingMigrationPlan.self,
      configurations: [configuration]
    )

    let book = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<LibraryBook>()).first)
    XCTAssertEqual(book.title, "Preserved Book")
    XCTAssertEqual(book.localState?.isFavorite, true)
    XCTAssertEqual(book.localState?.progressSeconds, 987.5)
    XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<PlaybackState>()).isEmpty)
  }

  @MainActor
  func testV2StoreMigratesToBookActivitySchemaWithoutLosingPlayback() throws {
    let storeURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("KindlingActivityMigration-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-shm", "-wal"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
      }
    }
    do {
      let configuration = ModelConfiguration(
        "activity-migration-test",
        schema: Schema(versionedSchema: KindlingSchemaV2.self),
        url: storeURL
      )
      let container = try ModelContainer(
        for: Schema(versionedSchema: KindlingSchemaV2.self),
        migrationPlan: KindlingMigrationPlan.self,
        configurations: [configuration]
      )
      container.mainContext.insert(
        PlaybackState(canonicalID: "book", positionSeconds: 456, playbackRate: 1.5)
      )
      try container.mainContext.save()
    }

    let configuration = ModelConfiguration(
      "activity-migration-test",
      schema: Schema(versionedSchema: KindlingSchemaV3.self),
      url: storeURL
    )
    let container = try ModelContainer(
      for: Schema(versionedSchema: KindlingSchemaV3.self),
      migrationPlan: KindlingMigrationPlan.self,
      configurations: [configuration]
    )
    let playback = try XCTUnwrap(
      container.mainContext.fetch(FetchDescriptor<PlaybackState>()).first)
    XCTAssertEqual(playback.positionSeconds, 456)
    XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<BookActivityState>()).isEmpty)
  }

  @MainActor
  func testPlaybackRepositoryImportsLegacyPositionIdempotently() throws {
    let defaults = try isolatedDefaults(named: "LegacyImport")
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(432.1, forKey: resumePositionKeyPrefix + "book#manifestation-7")
    defaults.set(1.5, forKey: "audioPlayer.playbackRate")
    let container = try playbackTestContainer()
    let repository = PlaybackRepository(context: container.mainContext, defaults: defaults)

    try repository.migrateLegacyState()
    try repository.migrateLegacyState()

    let states = try container.mainContext.fetch(FetchDescriptor<PlaybackState>())
    XCTAssertEqual(states.count, 1)
    XCTAssertEqual(states.first?.positionSeconds, 432.1)
    XCTAssertEqual(states.first?.playbackRate, 1.5)
  }

  @MainActor
  func testPlaybackRepositoryKeepsManifestationsIndependent() throws {
    let defaults = try isolatedDefaults(named: "Manifestations")
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let container = try playbackTestContainer()
    let repository = PlaybackRepository(context: container.mainContext, defaults: defaults)
    let first = PlaybackIdentity(canonicalID: "book#manifestation-1")
    let second = PlaybackIdentity(canonicalID: "book#manifestation-2")

    repository.checkpoint(
      identity: first, position: 100, duration: 1_000, playbackRate: 1, flush: true)
    repository.checkpoint(
      identity: second, position: 250, duration: 1_000, playbackRate: 1.25, flush: true)

    XCTAssertEqual(repository.position(for: first), 100)
    XCTAssertEqual(repository.position(for: second), 250)
  }

  @MainActor
  func testPlaybackRepositoryIndexesNewStateForRepeatedReads() throws {
    let defaults = try isolatedDefaults(named: "IndexedReads")
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let container = try playbackTestContainer()
    let repository = PlaybackRepository(context: container.mainContext, defaults: defaults)
    let identity = PlaybackIdentity(canonicalID: "indexed-book")

    repository.checkpoint(
      identity: identity,
      position: 321,
      duration: 1_000,
      playbackRate: 1,
      flush: true
    )

    for _ in 0..<100 {
      XCTAssertEqual(repository.position(for: identity), 321)
    }
    let states = try container.mainContext.fetch(FetchDescriptor<PlaybackState>())
    XCTAssertEqual(states.map(\.canonicalID), ["indexed-book"])
  }

  @MainActor
  func testPlaybackRepositoryReplaysRecoveryJournal() throws {
    let defaults = try isolatedDefaults(named: "Recovery")
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let container = try playbackTestContainer()
    let identity = PlaybackIdentity(canonicalID: "book")
    PlaybackRepository(context: container.mainContext, defaults: defaults).checkpoint(
      identity: identity, position: 321, duration: 900, playbackRate: 1.25, flush: false)

    let restored = PlaybackRepository(context: container.mainContext, defaults: defaults)
    try restored.migrateLegacyState()

    XCTAssertEqual(restored.position(for: identity), 321)
  }

  @MainActor
  func testMarkReadDoesNotChangeRepositoryPosition() throws {
    let defaults = try isolatedDefaults(named: "MarkRead")
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let container = try playbackTestContainer()
    let repository = PlaybackRepository(context: container.mainContext, defaults: defaults)
    let identity = PlaybackIdentity(canonicalID: "book")
    repository.checkpoint(
      identity: identity, position: 654, duration: 1_000, playbackRate: 1, flush: true)
    let localState = LocalBookState(bookPodibleId: "book")

    setReadState(true, on: localState)

    XCTAssertEqual(repository.position(for: identity), 654)
  }

  @MainActor
  private func playbackTestContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(
      schema: Schema(versionedSchema: KindlingSchemaV2.self),
      isStoredInMemoryOnly: true
    )
    return try ModelContainer(
      for: Schema(versionedSchema: KindlingSchemaV2.self),
      migrationPlan: KindlingMigrationPlan.self,
      configurations: [configuration]
    )
  }

  private func isolatedDefaults(named name: String) throws -> UserDefaults {
    let suite = "KindlingTests.\(name).\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(suite, forKey: "test.suiteName")
    return defaults
  }

  private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "test.suiteName") ?? ""
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
