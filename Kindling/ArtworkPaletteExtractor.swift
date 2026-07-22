import CoreGraphics
import Foundation
import KindlingUI
import Kingfisher
import Observation

@MainActor
@Observable
final class ArtworkPaletteStore {
  private var palettesByURL: [String: ArtworkPalette] = [:]
  private var keysBeingSampled = Set<String>()
  private let cache: ArtworkPaletteCache

  init(cache: ArtworkPaletteCache = ArtworkPaletteCache()) {
    self.cache = cache
  }

  func palette(for url: URL?) -> ArtworkPalette {
    guard let key = url?.absoluteString else { return .fallback }
    return palettesByURL[key] ?? .fallback
  }

  func loadCached(for urls: [URL]) {
    let keys = Set(urls.map(\.absoluteString))
    guard keys.isEmpty == false else {
      palettesByURL = [:]
      return
    }
    cache.removePalettes(excluding: keys)
    palettesByURL = palettesByURL.filter { keys.contains($0.key) }
    for key in keys where palettesByURL[key] == nil {
      if let palette = cache.palette(for: key) {
        palettesByURL[key] = palette
      }
    }
  }

  func sampleAndCache(from image: KFCrossPlatformImage, for url: URL) {
    let key = url.absoluteString
    guard palettesByURL[key] == nil else { return }
    guard keysBeingSampled.insert(key).inserted else { return }
    Task {
      let palette = await Task.detached(priority: .utility) {
        ArtworkPaletteSampler.palette(from: image)
      }.value
      keysBeingSampled.remove(key)
      guard let palette else { return }
      cache.store(palette, for: key)
      palettesByURL[key] = palette
    }
  }
}

struct ArtworkPaletteCache {
  private struct StoredPalette: Codable {
    var red: Double
    var green: Double
    var blue: Double
  }

  private let defaults: UserDefaults
  private let keyPrefix = "artworkPalette."

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func palette(for key: String) -> ArtworkPalette? {
    guard let data = defaults.data(forKey: storageKey(for: key)),
      let stored = try? JSONDecoder().decode(StoredPalette.self, from: data)
    else {
      return nil
    }
    return ArtworkPalette(red: stored.red, green: stored.green, blue: stored.blue)
  }

  func store(_ palette: ArtworkPalette, for key: String) {
    let stored = StoredPalette(red: palette.red, green: palette.green, blue: palette.blue)
    guard let data = try? JSONEncoder().encode(stored) else { return }
    defaults.set(data, forKey: storageKey(for: key))
  }

  func removePalettes(excluding validKeys: Set<String>) {
    let validStorageKeys = Set(validKeys.map(storageKey(for:)))
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
      if validStorageKeys.contains(key) == false {
        defaults.removeObject(forKey: key)
      }
    }
  }

  private func storageKey(for key: String) -> String {
    keyPrefix + key
  }
}

enum ArtworkPaletteSampler {
  static func palette(from image: KFCrossPlatformImage) -> ArtworkPalette? {
    guard let cgImage = image.paletteCGImage else { return nil }
    return palette(from: cgImage)
  }

  static func palette(from cgImage: CGImage, sampleSize: Int = 24) -> ArtworkPalette? {
    let width = max(1, sampleSize)
    let height = max(1, sampleSize)
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    guard
      let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      )
    else {
      return nil
    }

    context.interpolationQuality = .low
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var weightedRed = 0.0
    var weightedGreen = 0.0
    var weightedBlue = 0.0
    var totalWeight = 0.0
    var fallbackRed = 0.0
    var fallbackGreen = 0.0
    var fallbackBlue = 0.0
    var fallbackCount = 0.0

    for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
      let alpha = Double(pixels[offset + 3]) / 255
      guard alpha > 0.12 else { continue }

      let red = Double(pixels[offset]) / 255
      let green = Double(pixels[offset + 1]) / 255
      let blue = Double(pixels[offset + 2]) / 255
      let maxChannel = max(red, green, blue)
      let minChannel = min(red, green, blue)
      let saturation = maxChannel - minChannel
      let brightness = maxChannel

      fallbackRed += red
      fallbackGreen += green
      fallbackBlue += blue
      fallbackCount += 1

      guard brightness > 0.08, brightness < 0.96 || saturation > 0.16 else { continue }

      let saturationWeight = max(0.05, saturation)
      let brightnessWeight = 0.45 + min(brightness, 1) * 0.55
      let weight = saturationWeight * brightnessWeight * alpha
      weightedRed += red * weight
      weightedGreen += green * weight
      weightedBlue += blue * weight
      totalWeight += weight
    }

    if totalWeight > 0 {
      return ArtworkPalette(
        red: weightedRed / totalWeight,
        green: weightedGreen / totalWeight,
        blue: weightedBlue / totalWeight
      )
    }

    guard fallbackCount > 0 else { return nil }
    return ArtworkPalette(
      red: fallbackRed / fallbackCount,
      green: fallbackGreen / fallbackCount,
      blue: fallbackBlue / fallbackCount
    )
  }
}

extension KFCrossPlatformImage {
  var paletteCGImage: CGImage? {
    #if os(macOS)
      var rect = CGRect(origin: .zero, size: size)
      return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    #else
      return cgImage
    #endif
  }
}
