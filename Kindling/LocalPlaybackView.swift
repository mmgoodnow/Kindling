import AVKit
import KindlingUI
import Kingfisher
import SwiftUI

private func playbackEffectiveDuration(
  for chapter: AudioPlayerController.Chapter,
  at index: Int?,
  chapters: [AudioPlayerController.Chapter],
  totalDuration: Double
) -> Double {
  if chapter.duration > 0 {
    return chapter.duration
  }

  let resolvedIndex = index ?? chapters.firstIndex(where: { $0.id == chapter.id }) ?? chapters.count
  if chapters.indices.contains(resolvedIndex + 1) {
    return max(chapters[resolvedIndex + 1].startTime - chapter.startTime, 0)
  }
  return max(totalDuration - chapter.startTime, 0)
}

private func playbackCurrentChapterID(
  time: Double,
  chapters: [AudioPlayerController.Chapter],
  totalDuration: Double
) -> Int? {
  playbackCurrentChapterIndex(time: time, chapters: chapters, totalDuration: totalDuration)
    .map { chapters[$0].id }
}

private func playbackCurrentChapterIndex(
  time: Double,
  chapters: [AudioPlayerController.Chapter],
  totalDuration: Double
) -> Int? {
  guard chapters.isEmpty == false else { return nil }

  let currentTime = max(time, 0)
  if currentTime < chapters[0].startTime {
    return 0
  }

  var low = 0
  var high = chapters.count - 1
  while low <= high {
    let mid = (low + high) / 2
    let chapter = chapters[mid]
    let nextStart =
      chapters.indices.contains(mid + 1) ? chapters[mid + 1].startTime : totalDuration

    if currentTime < chapter.startTime {
      high = mid - 1
    } else if currentTime >= max(nextStart, chapter.startTime + 0.01),
      mid + 1 < chapters.count
    {
      low = mid + 1
    } else {
      return mid
    }
  }

  return chapters.indices.contains(low) ? low : chapters.indices.last
}

private func playbackCurrentChapterProgress(
  time: Double,
  chapters: [AudioPlayerController.Chapter],
  totalDuration: Double
) -> Double {
  guard
    let index = playbackCurrentChapterIndex(
      time: time, chapters: chapters, totalDuration: totalDuration),
    chapters.indices.contains(index)
  else { return 0 }

  let chapter = chapters[index]
  let duration = max(
    playbackEffectiveDuration(
      for: chapter, at: index, chapters: chapters, totalDuration: totalDuration),
    1
  )
  let elapsed = max(0, time - chapter.startTime)
  return min(max(elapsed / duration, 0), 1)
}

private func playbackBookProgress(time: Double, totalDuration: Double) -> Double {
  guard totalDuration.isFinite, totalDuration > 1 else { return 0 }
  return min(max(time / totalDuration, 0), 1)
}

private func playbackBookProgressPercent(time: Double, totalDuration: Double) -> Int {
  Int((playbackBookProgress(time: time, totalDuration: totalDuration) * 100).rounded())
}

private func formatPlaybackTime(_ seconds: Double) -> String {
  let totalSeconds = Int(seconds.rounded())
  let hours = totalSeconds / 3600
  let minutes = (totalSeconds % 3600) / 60
  let remainingSeconds = totalSeconds % 60

  if hours > 0 {
    return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
  }
  return String(format: "%d:%02d", minutes, remainingSeconds)
}

private func playbackChapterRows(
  chapters: [AudioPlayerController.Chapter],
  currentTime: Double,
  totalDuration: Double
) -> [KindlingUI.ChapterRowViewData] {
  let currentChapterID = playbackCurrentChapterID(
    time: currentTime,
    chapters: chapters,
    totalDuration: totalDuration
  )
  let currentChapterProgress = playbackCurrentChapterProgress(
    time: currentTime,
    chapters: chapters,
    totalDuration: totalDuration
  )
  let durations = chapters.enumerated().map { index, chapter in
    playbackEffectiveDuration(
      for: chapter,
      at: index,
      chapters: chapters,
      totalDuration: totalDuration
    )
  }

  return chapters.enumerated().map { index, chapter in
    let isCurrent = currentChapterID == chapter.id
    let isCompleted = chapter.startTime + durations[index] <= currentTime && isCurrent == false

    return KindlingUI.ChapterRowViewData(
      id: chapter.id,
      title: chapter.title,
      durationText: formatPlaybackTime(durations[index]),
      progress: isCurrent ? currentChapterProgress : 0,
      isCompleted: isCompleted,
      isCurrent: isCurrent
    )
  }
}

private struct ChapterPlaybackProgressSectionView: View {
  let player: AudioPlayerController
  @ObservedObject var progress: AudioPlayerController.PlaybackProgressState

  @State private var chapterScrubOriginTime: Double?
  @State private var chapterScrubOriginDuration: Double?
  @State private var chapterScrubPreviewTime: Double?
  @State private var chapterScrubLastSeekTimestamp: TimeInterval = 0

  var body: some View {
    let chapters = player.chapters
    let totalDuration = progress.duration
    let currentTime = chapterScrubPreviewTime ?? progress.currentTime
    let currentChapterIndex = playbackCurrentChapterIndex(
      time: currentTime,
      chapters: chapters,
      totalDuration: totalDuration
    )
    let currentChapter = currentChapterIndex.flatMap {
      chapters.indices.contains($0) ? chapters[$0] : nil
    }
    let currentChapterDuration = {
      if let currentChapter, let currentChapterIndex {
        return playbackEffectiveDuration(
          for: currentChapter,
          at: currentChapterIndex,
          chapters: chapters,
          totalDuration: totalDuration
        )
      }
      return max(totalDuration, 1)
    }()
    let currentChapterElapsed =
      currentChapter.map { max(0, currentTime - $0.startTime) }
      ?? min(currentTime, max(totalDuration, 0))
    let currentChapterRemaining = max(currentChapterDuration - currentChapterElapsed, 0)
    let currentChapterProgress = min(
      max(currentChapterElapsed / max(currentChapterDuration, 1), 0), 1)
    let currentChapterProgressPercent = Int((currentChapterProgress * 100).rounded())

    VStack(alignment: .leading, spacing: 8) {
      if let currentChapter {
        Text(currentChapter.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }

      HStack(spacing: 8) {
        GeometryReader { proxy in
          ZStack(alignment: .leading) {
            Capsule(style: .continuous)
              .fill(Color.primary.opacity(0.10))

            Capsule(style: .continuous)
              .fill(Color.primary)
              .frame(width: max(proxy.size.width * currentChapterProgress, 10))
          }
          .frame(height: 8)
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in
                if chapterScrubOriginTime == nil {
                  chapterScrubOriginTime = currentTime
                  chapterScrubOriginDuration = max(currentChapterDuration, 1)
                  player.rememberCurrentPositionForSeek()
                }

                let width = max(proxy.size.width, 1)
                let deltaFraction = value.translation.width / width
                let deltaSeconds =
                  Double(deltaFraction) * (chapterScrubOriginDuration ?? currentChapterDuration)
                let candidateTime = min(
                  max((chapterScrubOriginTime ?? currentTime) + deltaSeconds, 0),
                  max(totalDuration, 0)
                )
                chapterScrubPreviewTime = candidateTime

                let now = Date().timeIntervalSinceReferenceDate
                if now - chapterScrubLastSeekTimestamp >= (1.0 / 30.0) {
                  chapterScrubLastSeekTimestamp = now
                  player.seek(to: candidateTime, recordHistory: false)
                }
              }
              .onEnded { _ in
                if let chapterScrubPreviewTime {
                  player.seek(to: chapterScrubPreviewTime, recordHistory: false)
                }
                chapterScrubOriginTime = nil
                chapterScrubOriginDuration = nil
                chapterScrubPreviewTime = nil
                chapterScrubLastSeekTimestamp = 0
              }
          )
        }
        .frame(height: 8)

        if player.canRestorePreviousSeek {
          Button(action: player.restorePreviousSeek) {
            Image(systemName: "arrow.counterclockwise")
              .font(.subheadline.weight(.semibold))
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.primary)
        }
      }

      HStack {
        Text(formatPlaybackTime(currentChapterElapsed))
        Spacer()
        Text("\(currentChapterProgressPercent)%")
        Spacer()
        Text("-\(formatPlaybackTime(currentChapterRemaining))")
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
    }
  }
}

struct LocalPlaybackView: View {
  private static let playbackTabBarHeight: CGFloat = 34
  private static let playbackTabSectionSpacing: CGFloat = 12

  @AppStorage("localPlayback.selectedContentTab") private var selectedContentTabRawValue =
    ContentTab.artwork.rawValue

  private enum ContentTab: String, CaseIterable, Identifiable {
    case artwork = "Cover"
    case chapters = "Chapters"
    case transcript = "Transcript"

    var id: String { rawValue }
  }

  @ObservedObject var player: AudioPlayerController
  @EnvironmentObject private var userSettings: UserSettings
  @EnvironmentObject private var podibleAuth: PodibleAuthController

  private var selectedContentTab: ContentTab {
    get { ContentTab(rawValue: selectedContentTabRawValue) ?? .artwork }
    nonmutating set { selectedContentTabRawValue = newValue.rawValue }
  }

  private var selectedContentTabBinding: Binding<ContentTab> {
    Binding(
      get: { selectedContentTab },
      set: { selectedContentTab = $0 }
    )
  }

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
    #if os(iOS)
      ZStack(alignment: .bottom) {
        playbackContentSection
          .padding(.horizontal, 16)
          .padding(.top, 0)
          .padding(.bottom, floatingControlsReservedHeight)

        expandedPlayerControls
          .padding(.horizontal, 16)
          .padding(.bottom, -2)
      }
      .background(expandedPlayerBackground)
    #else
      VStack(spacing: 0) {
        playbackContentSection
          .padding(.horizontal, 24)
          .padding(.top, 28)

        expandedPlayerControls
          .padding(.horizontal, 24)
          .padding(.top, 28)
      }
      .padding(.bottom, 28)
      .background(expandedPlayerBackground)
    #endif
  }

  private var expandedPlayerControls: some View {
    VStack(spacing: 14) {
      ChapterPlaybackProgressSectionView(player: player, progress: player.progress)

      HStack(spacing: 12) {
        #if os(iOS)
          AirPlayRouteButton()
            .frame(width: 52, height: 52)
        #endif

        transportButton(systemName: "gobackward.15", size: 68, iconFont: .title) {
          player.skip(by: -15)
        }

        Button(action: player.togglePlayback) {
          ZStack {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 54, weight: .regular))
              .opacity(player.isStalled ? 0.25 : 1)
            if player.isStalled {
              ProgressView()
                .controlSize(.large)
                .tint(.primary)
            }
          }
          .frame(width: 68, height: 68)
        }
        .buttonStyle(.plain)

        transportButton(systemName: "goforward.30", size: 68, iconFont: .title) {
          player.skip(by: 30)
        }

        playbackSpeedButton
      }
      .foregroundStyle(.primary)
    }
    .padding(.horizontal, 14)
    .padding(.top, 8)
    .padding(.bottom, 4)
  }

  private var floatingControlsReservedHeight: CGFloat {
    148
  }

  @ViewBuilder
  private var heroSection: some View {
    #if os(iOS)
      let artworkSize = min(activeScreenSize().width - 24, 368)
    #else
      let artworkSize: CGFloat = 296
    #endif

    VStack(spacing: 0) {
      sharedPlaybackArtwork(
        size: artworkSize,
        cornerRadius: 24,
        player: player,
        rpcURLString: userSettings.podibleRPCURL,
        accessToken: podibleAuth.accessToken
      )
      #if os(iOS)
        .padding(.horizontal, -16)
      #endif
      .shadow(color: .black.opacity(0.16), radius: 24, y: 10)

    }
  }

  private var expandedPlayerBackground: some View {
    #if os(iOS)
      Color.clear
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

  private var playbackSpeedButton: some View {
    Menu {
      ForEach([0.8, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.75, 2.0], id: \.self) { rate in
        Button {
          player.setPlaybackRate(rate)
        } label: {
          if rate == player.playbackRate {
            Label(formatPlaybackRate(rate), systemImage: "checkmark")
          } else {
            Text(formatPlaybackRate(rate))
          }
        }
      }
    } label: {
      Text(formatPlaybackRate(player.playbackRate))
        .font(.headline.weight(.semibold))
        .monospacedDigit()
        .frame(width: 52, height: 52)
    }
    .buttonStyle(.plain)
  }

  private var chapterRows: [KindlingUI.ChapterRowViewData] {
    playbackChapterRows(
      chapters: player.chapters,
      currentTime: player.progress.currentTime,
      totalDuration: player.duration
    )
  }

  private var playerCoverViewData: PlayerViewData {
    let chapters = player.chapters
    let currentTime = player.progress.currentTime
    let totalDuration = player.progress.duration
    let currentChapterIndex = playbackCurrentChapterIndex(
      time: currentTime,
      chapters: chapters,
      totalDuration: totalDuration
    )
    let currentChapter = currentChapterIndex.flatMap {
      chapters.indices.contains($0) ? chapters[$0] : nil
    }
    let currentChapterDuration =
      currentChapter.flatMap { chapter in
        playbackEffectiveDuration(
          for: chapter,
          at: currentChapterIndex,
          chapters: chapters,
          totalDuration: totalDuration
        )
      } ?? max(totalDuration, 1)
    let currentChapterElapsed =
      currentChapter.map { max(0, currentTime - $0.startTime) }
      ?? min(currentTime, max(totalDuration, 0))
    let currentChapterRemaining = max(currentChapterDuration - currentChapterElapsed, 0)
    let currentChapterProgress = min(
      max(currentChapterElapsed / max(currentChapterDuration, 1), 0),
      1
    )

    return PlayerViewData(
      artworkURL: player.artworkURL,
      bookCompletionPercent: playbackBookProgressPercent(
        time: currentTime,
        totalDuration: totalDuration
      ),
      bookProgress: playbackBookProgress(time: currentTime, totalDuration: totalDuration),
      currentChapterTitle: currentChapter?.title,
      currentChapterProgress: currentChapterProgress,
      currentChapterElapsedText: formatPlaybackTime(currentChapterElapsed),
      currentChapterRemainingText: "-\(formatPlaybackTime(currentChapterRemaining))",
      isPlaying: player.isPlaying,
      playbackRateText: formatPlaybackRate(player.playbackRate),
      chapters: chapterRows
    )
  }

  private var chapterListContent: some View {
    KindlingUI.ChapterListView(chapters: chapterRows) { row in
      guard let chapter = player.chapters.first(where: { $0.id == row.id }) else { return }
      player.seek(to: chapter.startTime)
    }
  }

  private var chaptersSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Chapters")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)

      if player.chapters.isEmpty {
        Text("No chapters available yet.")
          .font(.body)
          .foregroundStyle(.secondary)
      } else {
        chapterListContent
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 8)
    .padding(.bottom, 16)
  }

  private var artworkSection: some View {
    ScrollView(showsIndicators: false) {
      PlayerCoverContentView(
        player: playerCoverViewData,
        artworkMaxWidth: nil,
        showsChapterProgress: false
      ) {
        heroSection
      }
      .padding(.top, 4)
      .padding(.bottom, 8)
    }
  }

  @ViewBuilder
  private var playbackContentSection: some View {
    VStack(spacing: 12) {
      HStack(spacing: 18) {
        ForEach([ContentTab.artwork, .chapters, .transcript]) { tab in
          let isSelected = selectedContentTab == tab
          Button {
            selectedContentTab = tab
          } label: {
            VStack(spacing: 6) {
              HStack(spacing: 4) {
                Text(tab.rawValue)
                  .font(.subheadline.weight(isSelected ? .semibold : .regular))
                  .foregroundStyle(isSelected ? .primary : .secondary)

                if tab == .transcript {
                  transcriptTabStatusBadge
                }
              }
              .frame(height: 18)

              Rectangle()
                .fill(isSelected ? Color.primary : .clear)
                .frame(height: 2)
            }
            .frame(width: 84, alignment: .center)
          }
          .buttonStyle(.plain)
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)

      TabView(selection: selectedContentTabBinding) {
        artworkSection
          .tag(ContentTab.artwork)

        chaptersSection
          .tag(ContentTab.chapters)

        transcriptSection
          .tag(ContentTab.transcript)
      }
      .frame(maxWidth: .infinity)
      .frame(height: playbackPageBodyHeight, alignment: .top)
      #if os(iOS)
        .tabViewStyle(.page(indexDisplayMode: .never))
      #endif
    }
    .frame(height: playbackContentHeight, alignment: .top)
  }

  private var transcriptSection: some View {
    TranscriptView(
      player: player,
      progress: player.progress,
      isTabActive: selectedContentTab == .transcript
    )
  }

  @ViewBuilder
  private var transcriptTabStatusBadge: some View {
    switch player.transcriptLoadState {
    case .idle:
      EmptyView()
    case .loading:
      ProgressView()
        .controlSize(.mini)
        .frame(width: 10, height: 10)
    case .loaded:
      Circle()
        .fill(Color.accentColor)
        .frame(width: 5, height: 5)
    case .unavailable:
      Image(systemName: "minus.circle.fill")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
    case .failed:
      Image(systemName: "exclamationmark.circle.fill")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.orange)
    }
  }

  private var playbackContentHeight: CGFloat {
    #if os(iOS)
      min(activeScreenSize().height * 0.7, 620)
    #else
      520
    #endif
  }

  private var playbackPageBodyHeight: CGFloat {
    max(
      playbackContentHeight
        - Self.playbackTabBarHeight
        - Self.playbackTabSectionSpacing,
      120
    )
  }

}

#if os(iOS)
  /// Adds a `safeAreaInset(edge: .bottom)` containing the floating mini
  /// playback bar. Apply on each screen that should host the bar; the bar
  /// only renders when something is loaded in the player.
  ///
  /// Each screen owning its own inset keeps the bar cooperating with
  /// system bottom UI (`.searchable`, etc.) and lets the screen control
  /// whether other insets (e.g. a floating dock) sit above or below it.
  struct MiniPlaybackBarInset: ViewModifier {
    @ObservedObject var player: AudioPlayerController
    @Binding var isShowingPlayer: Bool

    func body(content: Content) -> some View {
      content.safeAreaInset(edge: .bottom, spacing: 0) {
        if player.hasLoadedItem {
          MiniPlaybackBar(player: player) {
            isShowingPlayer = true
          }
          .padding(.horizontal, 24)
          .padding(.top, 10)
        }
      }
    }
  }
#endif

extension View {
  #if os(iOS)
    func miniPlaybackBarInset(
      player: AudioPlayerController,
      isShowingPlayer: Binding<Bool>
    ) -> some View {
      modifier(MiniPlaybackBarInset(player: player, isShowingPlayer: isShowingPlayer))
    }
  #else
    func miniPlaybackBarInset(
      player: AudioPlayerController,
      isShowingPlayer: Binding<Bool>
    ) -> some View {
      self
    }
  #endif
}

#if os(iOS)
  /// Replacement for `UIScreen.main.bounds.size`, deprecated in iOS 26.
  /// Walks the foreground active scenes for the first window scene's screen
  /// dimensions. Falls back to a reasonable default if none is connected.
  @MainActor
  private func activeScreenSize() -> CGSize {
    let scene =
      UIApplication.shared.connectedScenes
      .first { $0.activationState == .foregroundActive } as? UIWindowScene
      ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
    return scene?.screen.bounds.size ?? CGSize(width: 390, height: 844)
  }

  private struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
      let view = AVRoutePickerView()
      view.activeTintColor = .label
      view.tintColor = .label
      view.prioritizesVideoDevices = false
      view.backgroundColor = .clear
      return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
      uiView.activeTintColor = .label
      uiView.tintColor = .label
    }
  }
#endif

#if os(iOS)
  struct MiniPlaybackBar: View {
    @ObservedObject var player: AudioPlayerController
    @EnvironmentObject private var userSettings: UserSettings
    @EnvironmentObject private var podibleAuth: PodibleAuthController
    let onExpand: () -> Void

    var body: some View {
      GlassEffectContainer(spacing: 12) {
        HStack(spacing: 12) {
          nowPlayingCapsule
          playPauseButton
        }
      }
    }

    private var nowPlayingCapsule: some View {
      Button(action: onExpand) {
        HStack(spacing: 10) {
          sharedPlaybackArtwork(
            size: 32,
            cornerRadius: 6,
            player: player,
            rpcURLString: userSettings.podibleRPCURL,
            accessToken: podibleAuth.accessToken
          )

          VStack(alignment: .leading, spacing: 2) {
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
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open Now Playing")
      .modifier(NowPlayingGlassEffect())
    }

    private var playPauseButton: some View {
      Button {
        player.togglePlayback()
      } label: {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
          .font(.title3.weight(.semibold))
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
    }
  }

  private struct NowPlayingGlassEffect: ViewModifier {
    func body(content: Content) -> some View {
      content.glassEffect(.regular.interactive(), in: Capsule())
    }
  }
#endif

@MainActor
@ViewBuilder
private func sharedPlaybackArtwork(
  size: CGFloat,
  cornerRadius: CGFloat,
  player: AudioPlayerController,
  rpcURLString: String,
  accessToken: String?
)
  -> some View
{
  Group {
    if let artworkURL = player.artworkURL {
      AuthenticatedRemoteImage(
        url: artworkURL,
        rpcURLString: rpcURLString,
        accessToken: accessToken
      ) {
        sharedPlaybackArtworkPlaceholder(size: size, cornerRadius: cornerRadius)
      }
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

private func formatPlaybackRate(_ rate: Double) -> String {
  let roundedRate = (rate * 100).rounded() / 100
  if roundedRate.rounded() == roundedRate {
    return String(format: "%.0f×", roundedRate)
  }
  if (roundedRate * 10).rounded() == roundedRate * 10 {
    return String(format: "%.1f×", roundedRate)
  }
  return String(format: "%.2f×", roundedRate)
}

#Preview {
  LocalPlaybackView(player: AudioPlayerController())
}
