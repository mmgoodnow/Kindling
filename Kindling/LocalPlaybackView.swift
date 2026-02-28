import Kingfisher
import SwiftUI

struct LocalPlaybackView: View {
  @ObservedObject var player: AudioPlayerController

  var body: some View {
    #if os(iOS)
      expandedPlayerView()
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(.ultraThinMaterial)
    #else
      expandedPlayerView()
        .frame(minWidth: 420, minHeight: 560)
        .padding(28)
        .background(macPlayerBackground)
    #endif
  }

  private func expandedPlayerView() -> some View {
    VStack(spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(spacing: 0) {
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

          if player.chapters.isEmpty == false {
            chapterListSection
              .padding(.top, 28)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
      }

      VStack(spacing: 24) {
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

        HStack(spacing: 36) {
          transportButton(systemName: "gobackward.15", size: 72, iconFont: .title2) {
            player.skip(by: -15)
          }

          Button(action: player.togglePlayback) {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 88))
          }
          .buttonStyle(.plain)

          transportButton(systemName: "goforward.30", size: 72, iconFont: .title2) {
            player.skip(by: 30)
          }
        }
      }
      .padding(.top, 28)
    }
    .padding(.horizontal, 24)
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

  private func transportButton(
    systemName: String,
    size: CGFloat = 44,
    iconFont: Font = .body,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(iconFont.weight(.semibold))
        .frame(width: size, height: size)
    }
    .buttonStyle(.plain)
  }

  private var chapterListSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Chapters")
        .font(.headline.weight(.semibold))
        .foregroundStyle(.secondary)

      LazyVStack(spacing: 6) {
        ForEach(player.chapters) { chapter in
          Button {
            player.seek(to: chapter.startTime)
          } label: {
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 3) {
                Text(chapter.title)
                  .font(.body.weight(currentChapterID == chapter.id ? .semibold : .regular))
                  .foregroundStyle(.primary)
                  .multilineTextAlignment(.leading)
                  .frame(maxWidth: .infinity, alignment: .leading)

                Text(formatTime(chapter.startTime))
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }

              if currentChapterID == chapter.id {
                Image(systemName: "speaker.wave.2.fill")
                  .font(.footnote.weight(.semibold))
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(chapterRowBackground(isCurrent: currentChapterID == chapter.id))
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var currentChapterID: Int? {
    guard player.chapters.isEmpty == false else { return nil }

    let currentTime = max(player.currentTime, 0)
    for (index, chapter) in player.chapters.enumerated() {
      let nextStart =
        player.chapters.indices.contains(index + 1)
        ? player.chapters[index + 1].startTime
        : player.duration
      if currentTime >= chapter.startTime, currentTime < max(nextStart, chapter.startTime + 0.01) {
        return chapter.id
      }
    }

    return player.chapters.last?.id
  }

  @ViewBuilder
  private func chapterRowBackground(isCurrent: Bool) -> some View {
    #if os(iOS)
      if isCurrent {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(Color.primary.opacity(0.08))
      } else {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(Color.primary.opacity(0.04))
      }
    #else
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(isCurrent ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05))
    #endif
  }
}

#if os(iOS)
  struct MiniPlaybackBar: View {
    @ObservedObject var player: AudioPlayerController
    let onExpand: () -> Void

    var body: some View {
      HStack(spacing: 10) {
        Button(action: onExpand) {
          HStack(spacing: 10) {
            sharedPlaybackArtwork(size: 38, cornerRadius: 8, player: player)

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

        miniPlayerControlButton(systemName: "gobackward.15") {
          player.skip(by: -15)
        }

        miniPlayerControlButton(
          systemName: player.isPlaying ? "pause.fill" : "play.fill",
          extraTrailingHitArea: 16
        ) {
          player.togglePlayback()
        }
      }
      .padding(.top, 5)
      .padding(.horizontal, 16)
      .padding(.bottom, 6)
      .modifier(MiniPlaybackGlassBarStyle())
    }
  }
#endif

@ViewBuilder
private func miniPlayerControlButton(
  systemName: String,
  extraTrailingHitArea: CGFloat = 0,
  action: @escaping () -> Void
) -> some View {
  Button(action: action) {
    Image(systemName: systemName)
      .font(.system(size: 25, weight: .semibold))
      .frame(width: 52, height: 44)
  }
  .padding(.vertical, 8)
  .padding(.horizontal, 4)
  .padding(.trailing, extraTrailingHitArea)
  .contentShape(Rectangle())
  .padding(.vertical, -8)
  .padding(.horizontal, -4)
  .padding(.trailing, -extraTrailingHitArea)
  .buttonStyle(.plain)
}

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
