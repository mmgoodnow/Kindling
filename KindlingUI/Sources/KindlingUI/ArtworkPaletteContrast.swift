import Foundation
import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

enum ArtworkPaletteAppearance {
  case light
  case dark
}

struct ArtworkPaletteRGB: Hashable, Sendable {
  var red: Double
  var green: Double
  var blue: Double

  static func canvas(for appearance: ArtworkPaletteAppearance) -> Self {
    switch appearance {
    case .light:
      Self(red: 1, green: 1, blue: 1)
    case .dark:
      Self(red: 0.12, green: 0.12, blue: 0.13)
    }
  }

  var relativeLuminance: Double {
    0.2126 * Self.linearized(red)
      + 0.7152 * Self.linearized(green)
      + 0.0722 * Self.linearized(blue)
  }

  func contrastRatio(with other: Self) -> Double {
    let lighter = max(relativeLuminance, other.relativeLuminance)
    let darker = min(relativeLuminance, other.relativeLuminance)
    return (lighter + 0.05) / (darker + 0.05)
  }

  var oklch: OKLCH {
    let red = Self.linearized(red)
    let green = Self.linearized(green)
    let blue = Self.linearized(blue)
    let l = 0.412_221_470_8 * red + 0.536_332_536_3 * green + 0.051_445_992_9 * blue
    let m = 0.211_903_498_2 * red + 0.680_699_545_1 * green + 0.107_396_956_6 * blue
    let s = 0.088_302_461_9 * red + 0.281_718_837_6 * green + 0.629_978_700_5 * blue
    let cubeRootL = cbrt(l)
    let cubeRootM = cbrt(m)
    let cubeRootS = cbrt(s)
    let lightness =
      0.210_454_255_3 * cubeRootL
      + 0.793_617_785 * cubeRootM
      - 0.004_072_046_8 * cubeRootS
    let a =
      1.977_998_495_1 * cubeRootL
      - 2.428_592_205 * cubeRootM
      + 0.450_593_709_9 * cubeRootS
    let b =
      0.025_904_037_1 * cubeRootL
      + 0.782_771_766_2 * cubeRootM
      - 0.808_675_766 * cubeRootS
    return OKLCH(
      lightness: lightness,
      chroma: hypot(a, b),
      hueRadians: atan2(b, a)
    )
  }

  func adjustedToMeetContrast(_ minimumContrast: Double, against background: Self) -> Self {
    guard contrastRatio(with: background) < minimumContrast else { return self }

    let source = oklch
    let lighter = Self.gamutMapped(
      OKLCH(lightness: 1, chroma: source.chroma, hueRadians: source.hueRadians)
    )
    let darker = Self.gamutMapped(
      OKLCH(lightness: 0, chroma: source.chroma, hueRadians: source.hueRadians)
    )
    let canLighten = lighter.contrastRatio(with: background) >= minimumContrast
    let canDarken = darker.contrastRatio(with: background) >= minimumContrast

    if canLighten && canDarken {
      let lightened = contrastBoundary(
        from: source,
        toward: 1,
        minimumContrast: minimumContrast,
        background: background
      )
      let darkened = contrastBoundary(
        from: source,
        toward: 0,
        minimumContrast: minimumContrast,
        background: background
      )
      return
        abs(lightened.oklch.lightness - source.lightness)
        < abs(darkened.oklch.lightness - source.lightness)
        ? lightened : darkened
    }

    if canLighten {
      return contrastBoundary(
        from: source,
        toward: 1,
        minimumContrast: minimumContrast,
        background: background
      )
    }

    if canDarken {
      return contrastBoundary(
        from: source,
        toward: 0,
        minimumContrast: minimumContrast,
        background: background
      )
    }

    return lighter.contrastRatio(with: background) > darker.contrastRatio(with: background)
      ? lighter : darker
  }

  private func contrastBoundary(
    from source: OKLCH,
    toward endpoint: Double,
    minimumContrast: Double,
    background: Self
  ) -> Self {
    var failingLightness = source.lightness
    var passingLightness = endpoint

    for _ in 0..<24 {
      let candidateLightness = (failingLightness + passingLightness) / 2
      let candidate = Self.gamutMapped(
        OKLCH(
          lightness: candidateLightness,
          chroma: source.chroma,
          hueRadians: source.hueRadians
        )
      )
      if candidate.contrastRatio(with: background) >= minimumContrast {
        passingLightness = candidateLightness
      } else {
        failingLightness = candidateLightness
      }
    }

    return Self.gamutMapped(
      OKLCH(
        lightness: passingLightness,
        chroma: source.chroma,
        hueRadians: source.hueRadians
      )
    )
  }

  private static func gamutMapped(_ color: OKLCH) -> Self {
    let candidate = rgb(from: color)
    guard candidate.isInGamut == false else { return candidate }

    var minimumChromaScale = 0.0
    var maximumChromaScale = 1.0
    for _ in 0..<20 {
      let chromaScale = (minimumChromaScale + maximumChromaScale) / 2
      let candidate = rgb(
        from: OKLCH(
          lightness: color.lightness,
          chroma: color.chroma * chromaScale,
          hueRadians: color.hueRadians
        )
      )
      if candidate.isInGamut {
        minimumChromaScale = chromaScale
      } else {
        maximumChromaScale = chromaScale
      }
    }

    return rgb(
      from: OKLCH(
        lightness: color.lightness,
        chroma: color.chroma * minimumChromaScale,
        hueRadians: color.hueRadians
      )
    ).clamped
  }

  private static func rgb(from color: OKLCH) -> Self {
    let a = color.chroma * cos(color.hueRadians)
    let b = color.chroma * sin(color.hueRadians)
    let l = color.lightness + 0.396_337_777_4 * a + 0.215_803_757_3 * b
    let m = color.lightness - 0.105_561_345_8 * a - 0.063_854_172_8 * b
    let s = color.lightness - 0.089_484_177_5 * a - 1.291_485_548 * b
    let linearL = l * l * l
    let linearM = m * m * m
    let linearS = s * s * s
    return Self(
      red: delinearized(
        4.076_741_662_1 * linearL
          - 3.307_711_591_3 * linearM
          + 0.230_969_929_2 * linearS
      ),
      green: delinearized(
        -1.268_438_004_6 * linearL
          + 2.609_757_401_1 * linearM
          - 0.341_319_396_5 * linearS
      ),
      blue: delinearized(
        -0.004_196_086_3 * linearL
          - 0.703_418_614_7 * linearM
          + 1.707_614_701 * linearS
      )
    )
  }

  private var isInGamut: Bool {
    (0...1).contains(red) && (0...1).contains(green) && (0...1).contains(blue)
  }

  private var clamped: Self {
    Self(
      red: max(0, min(1, red)),
      green: max(0, min(1, green)),
      blue: max(0, min(1, blue))
    )
  }

  private static func linearized(_ component: Double) -> Double {
    component <= 0.04045
      ? component / 12.92
      : pow((component + 0.055) / 1.055, 2.4)
  }

  private static func delinearized(_ component: Double) -> Double {
    component <= 0.003_130_8
      ? component * 12.92
      : 1.055 * pow(component, 1 / 2.4) - 0.055
  }
}

struct OKLCH: Hashable, Sendable {
  var lightness: Double
  var chroma: Double
  var hueRadians: Double
}

extension ArtworkPalette {
  func resolvedForeground(
    for appearance: ArtworkPaletteAppearance,
    minimumContrast: Double
  ) -> ArtworkPaletteRGB {
    ArtworkPaletteRGB(red: red, green: green, blue: blue)
      .adjustedToMeetContrast(
        minimumContrast,
        against: .canvas(for: appearance)
      )
  }

  func adaptiveColor(light: ArtworkPaletteRGB, dark: ArtworkPaletteRGB) -> Color {
    #if canImport(UIKit)
      Color(
        uiColor: UIColor { traits in
          let color = traits.userInterfaceStyle == .dark ? dark : light
          return UIColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 1
          )
        }
      )
    #elseif canImport(AppKit)
      Color(
        nsColor: NSColor(name: nil) { appearance in
          let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          let color = isDark ? dark : light
          return NSColor(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 1
          )
        }
      )
    #else
      Color(red: red, green: green, blue: blue)
    #endif
  }
}
