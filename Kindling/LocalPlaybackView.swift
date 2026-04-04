import AVKit
import Kingfisher
import SwiftUI

private struct MarqueeText: View {
  let text: String
  let font: Font
  let textColor: Color

  private let gap: CGFloat = 28
  private let pointsPerSecond: CGFloat = 36

  @State private var containerWidth: CGFloat = 0
  @State private var textWidth: CGFloat = 0
  @State private var xOffset: CGFloat = 0

  var body: some View {
    GeometryReader { proxy in
      Group {
        if shouldScroll {
          scrollingContent
        } else {
          Text(text)
            .font(font)
            .foregroundStyle(textColor)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .clipped()
      .onAppear {
        containerWidth = proxy.size.width
        restartAnimationIfNeeded()
      }
      .onChange(of: proxy.size.width) { _, newValue in
        containerWidth = newValue
        restartAnimationIfNeeded()
      }
    }
    .frame(height: 20)
    .background(
      Text(text)
        .font(font)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .hidden()
        .background(
          GeometryReader { proxy in
            Color.clear
              .onAppear {
                textWidth = proxy.size.width
                restartAnimationIfNeeded()
              }
              .onChange(of: proxy.size.width) { _, newValue in
                textWidth = newValue
                restartAnimationIfNeeded()
              }
          }
        )
    )
  }

  private var shouldScroll: Bool {
    textWidth > containerWidth && containerWidth > 0
  }

  private var scrollingContent: some View {
    HStack(spacing: gap) {
      marqueeLabel
      marqueeLabel
    }
    .offset(x: xOffset)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var marqueeLabel: some View {
    Text(text)
      .font(font)
      .foregroundStyle(textColor)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
  }

  private func restartAnimationIfNeeded() {
    guard shouldScroll else {
      xOffset = 0
      return
    }

    let travelDistance = textWidth + gap
    let duration = max(Double(travelDistance / pointsPerSecond), 6)

    xOffset = 0
    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
      xOffset = -travelDistance
    }
  }
}

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
  guard chapters.isEmpty == false else { return nil }

  let currentTime = max(time, 0)
  for (index, chapter) in chapters.enumerated() {
    let nextStart =
      chapters.indices.contains(index + 1) ? chapters[index + 1].startTime : totalDuration
    if currentTime >= chapter.startTime, currentTime < max(nextStart, chapter.startTime + 0.01) {
      return chapter.id
    }
  }

  return chapters.last?.id
}

private func playbackCurrentChapterIndex(
  time: Double,
  chapters: [AudioPlayerController.Chapter],
  totalDuration: Double
) -> Int? {
  guard
    let chapterID = playbackCurrentChapterID(
      time: time, chapters: chapters, totalDuration: totalDuration)
  else {
    return nil
  }
  return chapters.firstIndex { $0.id == chapterID }
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

private func playbackChapterPositionLabel(
  for chapter: AudioPlayerController.Chapter,
  chapters: [AudioPlayerController.Chapter]
) -> String {
  guard let index = chapters.firstIndex(where: { $0.id == chapter.id }) else {
    return chapter.title
  }
  return "\(index + 1)/\(chapters.count) chapters"
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

private struct ChapterRowView: View, Equatable {
  let chapter: AudioPlayerController.Chapter
  let durationText: String
  let isCurrent: Bool
  let activeProgress: Double?
  let onSelect: () -> Void

  static func == (lhs: ChapterRowView, rhs: ChapterRowView) -> Bool {
    lhs.chapter == rhs.chapter
      && lhs.durationText == rhs.durationText
      && lhs.isCurrent == rhs.isCurrent
      && lhs.activeProgress == rhs.activeProgress
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        Text(chapter.title)
          .font(.body.weight(isCurrent ? .semibold : .regular))
          .foregroundStyle(.primary)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)

        Text(durationText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)

        if isCurrent {
          Image(systemName: "speaker.wave.2.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(chapterRowBackground)
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var chapterRowBackground: some View {
    #if os(iOS)
      if isCurrent {
        GeometryReader { proxy in
          let progressWidth = max(proxy.size.width * (activeProgress ?? 0), 0)
          let rowShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

          ZStack(alignment: .leading) {
            rowShape
              .fill(Color.primary.opacity(0.08))

            Rectangle()
              .fill(Color.accentColor.opacity(0.14))
              .frame(width: progressWidth)
          }
          .clipShape(rowShape)
        }
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

private struct ChapterListView: View {
  let chapters: [AudioPlayerController.Chapter]
  let totalDuration: Double
  @ObservedObject var progress: AudioPlayerController.PlaybackProgressState
  let onSelectChapter: (AudioPlayerController.Chapter) -> Void

  var body: some View {
    let currentChapterID = playbackCurrentChapterID(
      time: progress.currentTime,
      chapters: chapters,
      totalDuration: totalDuration
    )
    let currentChapterProgress = playbackCurrentChapterProgress(
      time: progress.currentTime,
      chapters: chapters,
      totalDuration: totalDuration
    )

    LazyVStack(spacing: 6) {
      ForEach(chapters) { chapter in
        ChapterRowView(
          chapter: chapter,
          durationText: formatPlaybackTime(
            playbackEffectiveDuration(
              for: chapter,
              at: nil,
              chapters: chapters,
              totalDuration: totalDuration
            )
          ),
          isCurrent: currentChapterID == chapter.id,
          activeProgress: currentChapterID == chapter.id ? currentChapterProgress : nil
        ) {
          onSelectChapter(chapter)
        }
        .equatable()
      }
    }
  }
}

private struct PlaybackBookProgressSectionView: View {
  let player: AudioPlayerController
  @ObservedObject var progress: AudioPlayerController.PlaybackProgressState

  var body: some View {
    let chapters = player.chapters
    let currentTime = progress.currentTime
    let totalDuration = progress.duration
    let currentChapterIndex = playbackCurrentChapterIndex(
      time: currentTime,
      chapters: chapters,
      totalDuration: totalDuration
    )
    let currentChapter = currentChapterIndex.flatMap {
      chapters.indices.contains($0) ? chapters[$0] : nil
    }
    let bookProgress = playbackBookProgress(time: currentTime, totalDuration: totalDuration)

    VStack(spacing: 8) {
      GeometryReader { proxy in
        let spacing: CGFloat = 1
        let totalSpacing = spacing * CGFloat(max(chapters.count - 1, 0))
        let availableWidth = max(proxy.size.width - totalSpacing, 0)
        let minimumSegmentWidth: CGFloat = 1
        let minimumRequiredWidth =
          CGFloat(chapters.count) * minimumSegmentWidth
          + CGFloat(max(chapters.count - 1, 0)) * spacing
        let extraSegmentWidth = max(
          availableWidth - CGFloat(chapters.count) * minimumSegmentWidth,
          0
        )
        let durations = chapters.enumerated().map { index, chapter in
          playbackEffectiveDuration(
            for: chapter,
            at: index,
            chapters: chapters,
            totalDuration: totalDuration
          )
        }
        let durationTotal = max(durations.reduce(0, +), 1)
        let segmentWidths = chapterSegmentWidths(
          durations: durations,
          totalDuration: durationTotal,
          extraSegmentWidth: extraSegmentWidth,
          minimumSegmentWidth: minimumSegmentWidth
        )
        let shouldUsePlainProgressBar = minimumRequiredWidth > proxy.size.width

        Group {
          if shouldUsePlainProgressBar {
            ZStack(alignment: .leading) {
              Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.14))

              Capsule(style: .continuous)
                .fill(Color.accentColor)
                .frame(width: max(proxy.size.width * bookProgress, 10))
            }
          } else {
            HStack(spacing: spacing) {
              ForEach(Array(chapters.enumerated()), id: \.element.id) { index, _ in
                chapterSegmentShape(for: index, count: chapters.count)
                  .fill(chapterSegmentFill(for: index, currentChapterIndex: currentChapterIndex))
                  .frame(
                    width: chapterSegmentWidth(
                      for: index,
                      segmentWidths: segmentWidths,
                      minimumSegmentWidth: minimumSegmentWidth
                    ),
                    height: 10
                  )
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: 10)

      if let currentChapter {
        MarqueeText(
          text:
            "\(player.title) • \(playbackChapterPositionLabel(for: currentChapter, chapters: chapters)) • \(playbackBookProgressPercent(time: currentTime, totalDuration: totalDuration))% through book",
          font: .subheadline.weight(.semibold),
          textColor: .secondary
        )
      }
    }
  }

  private func chapterSegmentShape(for index: Int, count: Int) -> AnyShape {
    let radius: CGFloat = 4
    if count == 1 {
      return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    } else if index == 0 {
      return AnyShape(
        UnevenRoundedRectangle(
          cornerRadii: .init(topLeading: radius, bottomLeading: radius),
          style: .continuous
        )
      )
    } else if index == count - 1 {
      return AnyShape(
        UnevenRoundedRectangle(
          cornerRadii: .init(bottomTrailing: radius, topTrailing: radius),
          style: .continuous
        )
      )
    } else {
      return AnyShape(Rectangle())
    }
  }

  private func chapterSegmentFill(for index: Int, currentChapterIndex: Int?) -> Color {
    guard let currentChapterIndex else { return Color.accentColor.opacity(0.14) }
    if index == currentChapterIndex {
      return .accentColor
    }
    return Color.accentColor.opacity(index < currentChapterIndex ? 0.34 : 0.10)
  }

  private func chapterSegmentWidth(
    for index: Int,
    segmentWidths: [CGFloat],
    minimumSegmentWidth: CGFloat
  ) -> CGFloat {
    guard segmentWidths.indices.contains(index) else { return minimumSegmentWidth }
    return segmentWidths[index]
  }

  private func chapterSegmentWidths(
    durations: [Double],
    totalDuration: Double,
    extraSegmentWidth: CGFloat,
    minimumSegmentWidth: CGFloat
  ) -> [CGFloat] {
    guard durations.isEmpty == false else { return [] }

    var widths: [CGFloat] = []
    widths.reserveCapacity(durations.count)

    var accumulatedExtraWidth: CGFloat = 0
    var allocatedExtraWidth: CGFloat = 0

    for (index, duration) in durations.enumerated() {
      let fraction = CGFloat(duration / max(totalDuration, 1))
      accumulatedExtraWidth += fraction * extraSegmentWidth

      let roundedAccumulatedWidth: CGFloat
      if index == durations.count - 1 {
        roundedAccumulatedWidth = extraSegmentWidth
      } else {
        roundedAccumulatedWidth = accumulatedExtraWidth.rounded(.toNearestOrAwayFromZero)
      }

      let roundedExtraWidth = max(roundedAccumulatedWidth - allocatedExtraWidth, 0)
      allocatedExtraWidth += roundedExtraWidth
      widths.append(minimumSegmentWidth + roundedExtraWidth)
    }

    return widths
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
              .fill(Color.accentColor.opacity(0.14))

            Capsule(style: .continuous)
              .fill(Color.accentColor)
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
          .foregroundStyle(.accent)
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
  private static let playbackBookProgressSectionHeight: CGFloat = 38
  private static let playbackTabSectionSpacing: CGFloat = 18

  @AppStorage("localPlayback.selectedContentTab") private var selectedContentTabRawValue =
    ContentTab.artwork.rawValue

  private enum ContentTab: String, CaseIterable, Identifiable {
    case artwork = "Artwork"
    case chapters = "Chapters"
    case transcript = "Transcript"

    var id: String { rawValue }
  }

  @ObservedObject var player: AudioPlayerController

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
          Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 54, weight: .regular))
            .frame(width: 68, height: 68)
        }
        .buttonStyle(.plain)

        transportButton(systemName: "goforward.30", size: 68, iconFont: .title) {
          player.skip(by: 30)
        }

        playbackSpeedButton
      }
      .foregroundStyle(.accent)
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
      let artworkSize = min(UIScreen.main.bounds.width - 24, 368)
    #else
      let artworkSize: CGFloat = 296
    #endif

    VStack(spacing: 0) {
      sharedPlaybackArtwork(size: artworkSize, cornerRadius: 24, player: player)
        #if os(iOS)
          .padding(.horizontal, -16)
        #endif
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

  private var chapterListContent: some View {
    ChapterListView(
      chapters: player.chapters,
      totalDuration: player.duration,
      progress: player.progress
    ) { chapter in
      player.seek(to: chapter.startTime)
    }
  }

  private var chaptersSection: some View {
    ScrollView(showsIndicators: false) {
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
  }

  private var artworkSection: some View {
    ScrollView(showsIndicators: false) {
      VStack(alignment: .leading, spacing: 22) {
        heroSection
          .frame(maxWidth: .infinity)

        Group {
          if player.bookDescription.isEmpty {
            Text("No description available.")
          } else {
            Text(player.bookDescription)
          }
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.top, 4)
      .padding(.bottom, 8)
    }
  }

  @ViewBuilder
  private var playbackContentSection: some View {
    VStack(spacing: 12) {
      PlaybackBookProgressSectionView(player: player, progress: player.progress)

      HStack(spacing: 18) {
        ForEach([ContentTab.artwork, .chapters, .transcript]) { tab in
          let isSelected = selectedContentTab == tab
          Button {
            selectedContentTab = tab
          } label: {
            VStack(spacing: 6) {
              Text(tab.rawValue)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .accent : .secondary)

              Rectangle()
                .fill(isSelected ? Color.accentColor : .clear)
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
    ScrollView(showsIndicators: false) {
      VStack(alignment: .leading, spacing: 12) {
        if let transcript = player.transcript, transcript.text.isEmpty == false {
          Text("\(transcript.words.count) timestamped words")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

          Text(transcript.text)
            .textSelection(.enabled)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Text("No transcript available yet.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private var playbackContentHeight: CGFloat {
    #if os(iOS)
      min(UIScreen.main.bounds.height * 0.7, 620)
    #else
      520
    #endif
  }

  private var playbackPageBodyHeight: CGFloat {
    max(
      playbackContentHeight
        - Self.playbackBookProgressSectionHeight
        - Self.playbackTabBarHeight
        - (Self.playbackTabSectionSpacing * 2),
      120
    )
  }

}

#if os(iOS)
  private struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
      let view = AVRoutePickerView()
      view.activeTintColor = UIColor(Color.accentColor)
      view.tintColor = UIColor(Color.accentColor)
      view.prioritizesVideoDevices = false
      view.backgroundColor = .clear
      return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
      uiView.activeTintColor = UIColor(Color.accentColor)
      uiView.tintColor = UIColor(Color.accentColor)
    }
  }
#endif

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
          .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
          .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
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
