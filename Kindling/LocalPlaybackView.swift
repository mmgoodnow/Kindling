import Kingfisher
import SwiftUI

struct LocalPlaybackView: View {
  @ObservedObject var player: AudioPlayerController

  var body: some View {
    #if os(iOS)
      expandedPlayerView(showsDismissButton: false)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(.ultraThinMaterial)
    #else
      expandedPlayerView(showsDismissButton: true)
        .frame(minWidth: 420, minHeight: 560)
        .padding(28)
        .background(macPlayerBackground)
    #endif
  }

  private func expandedPlayerView(showsDismissButton: Bool) -> some View {
    VStack(spacing: 0) {
      HStack(alignment: .center) {
        Spacer(minLength: 0)

        Text("Now Playing")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Spacer(minLength: 0)
      }
      .padding(.bottom, 28)

      Spacer(minLength: 0)

      sharedPlaybackArtwork(size: 296, cornerRadius: 24, player: player)
        .shadow(color: .black.opacity(0.16), radius: 24, y: 10)

      VStack(spacing: 8) {
        Text(player.title)
          .font(.title2.weight(.bold))
          .multilineTextAlignment(.center)
          .lineLimit(3)
        if player.author.isEmpty == false {
          Text(player.author)
            .font(.headline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }
      }
      .padding(.top, 28)

      VStack(spacing: 10) {
        Slider(
          value: Binding(
            get: { min(player.currentTime, max(player.duration, 0)) },
            set: { player.seek(to: $0) }
          ),
          in: 0...max(player.duration, 1)
        )

        HStack {
          Text(formatTime(player.currentTime))
          Spacer()
          Text(formatTime(player.duration))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      .padding(.top, 28)

      HStack(spacing: 28) {
        transportButton(systemName: "gobackward.15") {
          player.skip(by: -15)
        }
        .font(.title2)

        Button(action: player.togglePlayback) {
          Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
            .font(.system(size: 72))
        }
        .buttonStyle(.plain)

        transportButton(systemName: "goforward.30") {
          player.skip(by: 30)
        }
        .font(.title2)
      }
      .padding(.top, 26)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 24)
    .padding(.top, 18)
    .padding(.bottom, 28)
    .background(expandedPlayerBackground)
  }

  private var expandedPlayerBackground: some View {
    #if os(iOS)
      Color(uiColor: .systemBackground)
        .opacity(0.92)
        .ignoresSafeArea()
    #else
      Color.clear
    #endif
  }

  private var macPlayerBackground: some View {
    RoundedRectangle(cornerRadius: 24, style: .continuous)
      .fill(.ultraThinMaterial)
  }

  private func transportButton(systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .frame(width: 44, height: 44)
    }
    .buttonStyle(.plain)
  }
}

#if os(iOS)
  struct MiniPlaybackBar: View {
    @ObservedObject var player: AudioPlayerController
    let onExpand: () -> Void

    var body: some View {
      HStack(spacing: 14) {
        Button(action: onExpand) {
          HStack(spacing: 14) {
            sharedPlaybackArtwork(size: 52, cornerRadius: 12, player: player)

            VStack(alignment: .leading, spacing: 3) {
              Text(player.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
              if player.author.isEmpty == false {
                Text(player.author)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }

            Spacer(minLength: 0)
          }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())

        Button(action: player.togglePlayback) {
          Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            .font(.title3.weight(.semibold))
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)

        Button {
          player.unload()
        } label: {
          Image(systemName: "xmark")
            .font(.headline.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .modifier(MiniPlaybackCloseButtonStyle())
      }
      .padding(.top, 10)
      .padding(.horizontal, 16)
      .padding(.bottom, 14)
      .modifier(MiniPlaybackGlassBarStyle())
      .overlay(alignment: .top) {
        ProgressView(value: playbackFraction(player))
          .tint(.primary.opacity(0.55))
          .padding(.horizontal, 16)
          .padding(.top, 2)
      }
    }
  }
#endif

private struct MiniPlaybackGlassBarStyle: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
      if #available(iOS 26.0, *) {
        GlassEffectContainer {
          content
            .glassEffect()
        }
      } else {
        content
          .background(.ultraThinMaterial)
      }
    #else
      content
        .background(.ultraThinMaterial)
    #endif
  }
}

private struct MiniPlaybackCloseButtonStyle: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
      if #available(iOS 26.0, *) {
        content
          .glassEffect(in: Circle())
      } else {
        content
          .background(.thinMaterial, in: Circle())
      }
    #else
      content
        .background(.thinMaterial, in: Circle())
    #endif
  }
}

@MainActor
@ViewBuilder
private func sharedPlaybackArtwork(
  size: CGFloat,
  cornerRadius: CGFloat,
  player: AudioPlayerController
)
  -> some View
{
  Group {
    if let artworkURL = player.artworkURL {
      KFImage(artworkURL)
        .placeholder {
          sharedPlaybackArtworkPlaceholder(size: size, cornerRadius: cornerRadius)
        }
        .resizable()
        .scaledToFill()
    } else {
      sharedPlaybackArtworkPlaceholder(size: size, cornerRadius: cornerRadius)
    }
  }
  .frame(width: size, height: size)
  .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
}

@MainActor
private func sharedPlaybackArtworkPlaceholder(size: CGFloat, cornerRadius: CGFloat) -> some View {
  RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    .fill(
      LinearGradient(
        colors: [
          Color(red: 0.41, green: 0.31, blue: 0.20),
          Color(red: 0.20, green: 0.16, blue: 0.11),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .overlay {
      Image(systemName: "books.vertical.fill")
        .font(.system(size: size * 0.34, weight: .medium))
        .foregroundStyle(.white.opacity(0.82))
    }
}

private func playbackFraction(_ player: AudioPlayerController) -> Double {
  guard player.duration > 0, player.duration.isFinite else { return 0 }
  return min(max(player.currentTime / player.duration, 0), 1)
}

private func formatTime(_ seconds: Double) -> String {
  guard seconds.isFinite else { return "--:--" }
  let total = max(0, Int(seconds))
  let hours = total / 3600
  let minutes = (total % 3600) / 60
  let secs = total % 60
  if hours > 0 {
    return String(format: "%d:%02d:%02d", hours, minutes, secs)
  }
  return String(format: "%d:%02d", minutes, secs)
}

#Preview {
  LocalPlaybackView(player: AudioPlayerController())
}
