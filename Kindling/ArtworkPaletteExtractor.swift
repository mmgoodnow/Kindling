import CoreGraphics
import Foundation
import KindlingUI
import Kingfisher

enum ArtworkPaletteLoader {
  static func palette(
    for url: URL,
    rpcURLString: String,
    accessToken: String?
  ) async -> ArtworkPalette? {
    var options: KingfisherOptionsInfo = []
    if let modifier = AuthenticatedRemoteImageRequest.modifier(
      for: url,
      rpcURLString: rpcURLString,
      accessToken: accessToken
    ) {
      options.append(.requestModifier(modifier))
    }

    do {
      let result = try await KingfisherManager.shared.retrieveImage(with: url, options: options)
      return ArtworkPaletteSampler.palette(from: result.image)
    } catch {
      return nil
    }
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
