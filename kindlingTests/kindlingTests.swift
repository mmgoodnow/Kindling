import CoreGraphics
import Foundation
import KindlingUI
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

  func testRecentLibrarySyncTimestampDoesNotChangeEverySecond() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let syncedAt = now.addingTimeInterval(-2)

    XCTAssertEqual(librarySyncRelativeText(syncedAt: syncedAt, relativeTo: now), "just now")
    XCTAssertEqual(
      librarySyncRelativeText(syncedAt: syncedAt, relativeTo: now.addingTimeInterval(30)),
      "just now"
    )
  }

  func testLibraryItemDecodesSeriesMembership() throws {
    let data = try XCTUnwrap(
      """
      {
        "id": "42",
        "bookname": "The Second Book",
        "authorname": "An Author",
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
