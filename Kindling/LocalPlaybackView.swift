import Kingfisher
import SwiftUI

struct LocalPlaybackView: View {
  @ObservedObject var player: AudioPlayerController
  @Environment(\.dismiss) private var dismiss

  #if os(iOS)
    private static let miniDetent = PresentationDetent.height(124)
    @State private var selectedDetent: PresentationDetent = miniDetent
  #endif

  var body: some View {
    #if os(iOS)
      playerSheetView
        .presentationDetents([Self.miniDetent, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(.ultraThinMaterial)
        .onDisappear {
          player.pause()
        }
    #else
      macPlayerView
        .frame(minWidth: 420, minHeight: 560)
        .onDisappear {
          player.pause()
        }
    #endif
  }

  #if os(iOS)
    private var playerSheetView: some View {
      Group {
        if isExpanded {
          expandedPlayerView(showsDismissButton: true)
        } else {
          compactPlayerView
        }
      }
      .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    private var isExpanded: Bool {
      selectedDetent == .large
    }
  #endif

  private var macPlayerView: some View {
    expandedPlayerView(showsDismissButton: true)
      .padding(28)
      .background(macPlayerBackground)
  }

  #if os(iOS)
    private var compactPlayerView: some View {
      VStack(spacing: 10) {
        HStack(spacing: 14) {
          artworkThumbnail(size: 52, cornerRadius: 12)

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

          Button(action: player.togglePlayback) {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
              .font(.title3.weight(.semibold))
              .frame(width: 36, height: 36)
          }
          .buttonStyle(.plain)

          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.callout.weight(.bold))
              .foregroundStyle(.secondary)
              .frame(width: 28, height: 28)
              .background(.thinMaterial, in: Circle())
          }
          .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
          withAnimation(.easeInOut(duration: 0.25)) {
            selectedDetent = .large
          }
        }

        ProgressView(value: playbackFraction)
          .tint(.primary.opacity(0.55))
      }
      .padding(.top, 12)
      .padding(.horizontal, 16)
      .padding(.bottom, 14)
    }
  #endif

  private func expandedPlayerView(showsDismissButton: Bool) -> some View {
    VStack(spacing: 0) {
      HStack(alignment: .center) {
        if showsDismissButton {
          Button {
            dismiss()
          } label: {
            Image(systemName: "chevron.down")
              .font(.headline.weight(.semibold))
              .frame(width: 36, height: 36)
              .background(.thinMaterial, in: Circle())
          }
          .buttonStyle(.plain)
        }

        Spacer(minLength: 0)

        Text("Now Playing")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Spacer(minLength: 0)

        if showsDismissButton {
          Color.clear
            .frame(width: 36, height: 36)
        }
      }
      .padding(.bottom, 28)

      Spacer(minLength: 0)

      artworkThumbnail(size: 296, cornerRadius: 24)
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
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.13, green: 0.15, blue: 0.20),
          Color(red: 0.08, green: 0.09, blue: 0.12),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      RadialGradient(
        colors: [
          Color.white.opacity(0.08),
          Color.clear,
        ],
        center: .top,
        startRadius: 24,
        endRadius: 380
      )
    }
    .ignoresSafeArea()
  }

  private var macPlayerBackground: some View {
    RoundedRectangle(cornerRadius: 24, style: .continuous)
      .fill(.ultraThinMaterial)
  }

  private func artworkThumbnail(size: CGFloat, cornerRadius: CGFloat) -> some View {
    Group {
      if let artworkURL = player.artworkURL {
        KFImage(artworkURL)
          .placeholder {
            artworkPlaceholder(size: size, cornerRadius: cornerRadius)
          }
          .resizable()
          .scaledToFill()
      } else {
        artworkPlaceholder(size: size, cornerRadius: cornerRadius)
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }

  private func artworkPlaceholder(size: CGFloat, cornerRadius: CGFloat) -> some View {
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

  private func transportButton(systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .frame(width: 44, height: 44)
    }
    .buttonStyle(.plain)
  }

  private var playbackFraction: Double {
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
}

#Preview {
  LocalPlaybackView(player: AudioPlayerController())
}
