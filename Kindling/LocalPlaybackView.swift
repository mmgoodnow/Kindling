import AVKit
import Kingfisher
import SwiftUI

struct LocalPlaybackView: View {
  private static let chapterTimelineDurationExponent = 0.8
  private static let playbackTabBarHeight: CGFloat = 34
  private static let playbackTabSectionSpacing: CGFloat = 18

  @AppStorage("localPlayback.selectedContentTab") private var selectedContentTabRawValue =
    ContentTab.artwork.rawValue

  private enum ContentTab: String, CaseIterable, Identifiable {
    case about = "About"
    case artwork = "Artwork"
    case transcript = "Transcript"

    var id: String { rawValue }
  }

  @ObservedObject var player: AudioPlayerController
  @State private var chapterScrubOriginTime: Double?
  @State private var chapterScrubOriginDuration: Double?
  @State private var chapterScrubPreviewTime: Double?
  @State private var chapterScrubLastSeekTimestamp: TimeInterval = 0
  @State private var isHeroVisible = true

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
        .safeAreaInset(edge: .top, spacing: 0) {
          stickyPlaybackHeader
        }
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
    VStack(spacing: 2) {
      playbackProgressSection

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
    .padding(.top, 14)
    .padding(.bottom, 4)
    .modifier(ExpandedPlayerControlsGlassStyle())
  }

  private var floatingControlsReservedHeight: CGFloat {
    228
  }

  @ViewBuilder
  private var heroSection: some View {
    #if os(iOS)
      let artworkSize = min(UIScreen.main.bounds.width - 24, 368)
    #else
      let artworkSize: CGFloat = 296
    #endif

    let hero = VStack(spacing: 0) {
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

    if #available(iOS 18.0, macOS 15.0, *) {
      hero.onScrollVisibilityChange(threshold: 0.35) { isVisible in
        isHeroVisible = isVisible
      }
    } else {
      hero
    }
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

  private var stickyPlaybackHeader: some View {
    let isVisible = !isHeroVisible

    return ZStack(alignment: .top) {
      Rectangle()
        .fill(.ultraThinMaterial)
        .mask {
          LinearGradient(
            stops: [
              .init(color: .black.opacity(0.98), location: 0.0),
              .init(color: .black.opacity(0.72), location: 0.42),
              .init(color: .black.opacity(0.22), location: 0.82),
              .init(color: .clear, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 88)

      VStack(spacing: 2) {
        Text(player.title)
          .font(.headline.weight(.semibold))
          .lineLimit(1)

        if player.author.isEmpty == false {
          Text(player.author)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(.top, 20)
      .padding(.horizontal, 48)
      .padding(.bottom, 18)
    }
    .frame(maxWidth: .infinity)
    .opacity(isVisible ? 1 : 0)
    .animation(.easeInOut(duration: 0.2), value: isVisible)
    .allowsHitTesting(false)
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
    LazyVStack(spacing: 6) {
      ForEach(player.chapters) { chapter in
        Button {
          player.seek(to: chapter.startTime)
        } label: {
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
              Text(chapter.title)
                .font(.body.weight(currentChapterID == chapter.id ? .semibold : .regular))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(formatChapterDuration(chapter))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)

            if currentChapterID == chapter.id {
              Image(systemName: "speaker.wave.2.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 9)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(chapterRowBackground(isCurrent: currentChapterID == chapter.id))
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var aboutAndChaptersSection: some View {
    ScrollView(showsIndicators: false) {
      VStack(alignment: .leading, spacing: 22) {
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
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 8)
      .padding(.bottom, 16)
    }
  }

  private var artworkSection: some View {
    ScrollView(showsIndicators: false) {
      heroSection
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
  }

  @ViewBuilder
  private var playbackContentSection: some View {
    VStack(spacing: 18) {
      HStack(spacing: 18) {
        ForEach([ContentTab.about, .artwork, .transcript]) { tab in
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
        aboutAndChaptersSection
          .tag(ContentTab.about)

        artworkSection
          .tag(ContentTab.artwork)

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

  private var playbackProgressSection: some View {
    VStack(spacing: 14) {
      chapterTimelineBar

      VStack(alignment: .leading, spacing: 8) {
        if let currentChapter {
          Text(bookProgressLabel(for: currentChapter))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
        }

        HStack(spacing: 8) {
          chapterScrubBar

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
          Text(formatTime(currentChapterElapsed))
          Spacer()
          Text("\(currentChapterProgressPercent)%")
          Spacer()
          Text("-\(formatTime(currentChapterRemaining))")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }
    }
  }

  private var chapterTimelineBar: some View {
    GeometryReader { proxy in
      let chapters = player.chapters
      let spacing: CGFloat = 1
      let totalSpacing = spacing * CGFloat(max(chapters.count - 1, 0))
      let availableWidth = max(proxy.size.width - totalSpacing, 0)
      let minimumSegmentWidth: CGFloat = 1
      let minimumRequiredWidth =
        CGFloat(chapters.count) * minimumSegmentWidth
        + CGFloat(max(chapters.count - 1, 0)) * spacing
      let scaledTotalDuration = max(chapterTimelineScaledDuration, 1)
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
            ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
              chapterSegmentShape(for: index, count: chapters.count)
                .fill(chapterSegmentColor(for: index))
                .frame(
                  width: chapterSegmentWidth(
                    for: index,
                    scaledTotalDuration: scaledTotalDuration,
                    availableWidth: availableWidth,
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
  }

  private var chapterScrubBar: some View {
    GeometryReader { proxy in
      let progress = currentChapterProgress

      ZStack(alignment: .leading) {
        Capsule(style: .continuous)
          .fill(Color.accentColor.opacity(0.14))

        Capsule(style: .continuous)
          .fill(Color.accentColor)
          .frame(width: max(proxy.size.width * progress, 10))
      }
      .frame(height: 8)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            if chapterScrubOriginTime == nil {
              chapterScrubOriginTime = currentPlaybackTime
              chapterScrubOriginDuration = max(currentChapterDuration, 1)
              player.rememberCurrentPositionForSeek()
            }

            let width = max(proxy.size.width, 1)
            let deltaFraction = value.translation.width / width
            let deltaSeconds =
              Double(deltaFraction) * (chapterScrubOriginDuration ?? currentChapterDuration)
            let candidateTime = clampToPlaybackBounds(
              (chapterScrubOriginTime ?? currentPlaybackTime) + deltaSeconds
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
  }

  private var currentPlaybackTime: Double {
    chapterScrubPreviewTime ?? player.currentTime
  }

  private var currentChapterID: Int? {
    guard player.chapters.isEmpty == false else { return nil }

    let currentTime = max(currentPlaybackTime, 0)
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

  private var currentChapterIndex: Int? {
    guard let currentChapterID else { return nil }
    return player.chapters.firstIndex { $0.id == currentChapterID }
  }

  private var currentChapter: AudioPlayerController.Chapter? {
    guard let currentChapterIndex else { return nil }
    guard player.chapters.indices.contains(currentChapterIndex) else { return nil }
    return player.chapters[currentChapterIndex]
  }

  private var chapterTimelineDuration: Double {
    let chapterDurationSum = player.chapters.reduce(0.0) { partialResult, chapter in
      partialResult + effectiveDuration(for: chapter, at: nil)
    }
    return max(chapterDurationSum, player.duration)
  }

  private var chapterTimelineScaledDuration: Double {
    player.chapters.reduce(0.0) { partialResult, chapter in
      partialResult + scaledChapterTimelineDuration(for: chapter)
    }
  }

  private var currentChapterElapsed: Double {
    guard let currentChapter else { return min(currentPlaybackTime, max(player.duration, 0)) }
    return max(0, currentPlaybackTime - currentChapter.startTime)
  }

  private var currentChapterDuration: Double {
    guard let currentChapter, let currentChapterIndex else { return max(player.duration, 1) }
    return effectiveDuration(for: currentChapter, at: currentChapterIndex)
  }

  private var currentChapterRemaining: Double {
    max(currentChapterDuration - currentChapterElapsed, 0)
  }

  private var currentChapterProgress: Double {
    let duration = max(currentChapterDuration, 1)
    return min(max(currentChapterElapsed / duration, 0), 1)
  }

  private var currentChapterProgressPercent: Int {
    Int((currentChapterProgress * 100).rounded())
  }

  private var bookProgressPercent: Int {
    let totalDuration = max(player.duration, 1)
    let percent = (currentPlaybackTime / totalDuration) * 100
    return Int(percent.rounded())
  }

  private var bookProgress: Double {
    let totalDuration = max(player.duration, 1)
    return min(max(currentPlaybackTime / totalDuration, 0), 1)
  }

  private func clampToPlaybackBounds(_ time: Double) -> Double {
    min(max(time, 0), max(player.duration, 0))
  }

  private var playbackContentHeight: CGFloat {
    #if os(iOS)
      min(UIScreen.main.bounds.height * 0.56, 520)
    #else
      520
    #endif
  }

  private var playbackPageBodyHeight: CGFloat {
    max(
      playbackContentHeight - Self.playbackTabBarHeight - Self.playbackTabSectionSpacing,
      120
    )
  }

  private func formatChapterDuration(_ chapter: AudioPlayerController.Chapter) -> String {
    let duration = effectiveDuration(for: chapter, at: nil)
    return formatTime(duration)
  }

  private func chapterPositionLabel(for chapter: AudioPlayerController.Chapter) -> String {
    guard let index = player.chapters.firstIndex(where: { $0.id == chapter.id }) else {
      return chapter.title
    }
    return "\(index + 1)/\(player.chapters.count) chapters"
  }

  private func bookProgressLabel(for chapter: AudioPlayerController.Chapter) -> String {
    "\(chapter.title) • \(chapterPositionLabel(for: chapter)) • \(bookProgressPercent)% through book"
  }

  private func effectiveDuration(
    for chapter: AudioPlayerController.Chapter,
    at index: Int?
  ) -> Double {
    if chapter.duration > 0 {
      return chapter.duration
    }

    let resolvedIndex =
      index ?? player.chapters.firstIndex(where: { $0.id == chapter.id }) ?? player.chapters.count

    if player.chapters.indices.contains(resolvedIndex + 1) {
      return max(player.chapters[resolvedIndex + 1].startTime - chapter.startTime, 0)
    }

    return max(player.duration - chapter.startTime, 0)
  }

  private func chapterSegmentColor(for index: Int) -> Color {
    guard let currentChapterIndex else { return Color.accentColor.opacity(0.14) }
    if index == currentChapterIndex {
      return .accentColor
    }
    return Color.accentColor.opacity(index < currentChapterIndex ? 0.34 : 0.10)
  }

  private func chapterSegmentWidth(
    for index: Int,
    scaledTotalDuration: Double,
    availableWidth: CGFloat,
    minimumSegmentWidth: CGFloat
  ) -> CGFloat {
    guard player.chapters.indices.contains(index) else { return 0 }
    let scaledDuration = scaledChapterTimelineDuration(for: player.chapters[index], at: index)
    let fraction = CGFloat(scaledDuration / max(scaledTotalDuration, 1))
    return max(fraction * availableWidth, minimumSegmentWidth)
  }

  private func scaledChapterTimelineDuration(
    for chapter: AudioPlayerController.Chapter,
    at index: Int? = nil
  ) -> Double {
    let duration = max(effectiveDuration(for: chapter, at: index), 1)
    return pow(duration, Self.chapterTimelineDurationExponent)
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
    }
    return AnyShape(Rectangle())
  }

  @ViewBuilder
  private func chapterRowBackground(isCurrent: Bool) -> some View {
    #if os(iOS)
      if isCurrent {
        GeometryReader { proxy in
          let progressWidth = max(proxy.size.width * currentChapterProgress, 0)
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

private struct ExpandedPlayerControlsGlassStyle: ViewModifier {
  private let bubbleShape = RoundedRectangle(cornerRadius: 28, style: .continuous)

  func body(content: Content) -> some View {
    #if os(iOS)
      if #available(iOS 26.0, *) {
        GlassEffectContainer {
          content
            .background {
              bubbleShape
                .fill(Color.black.opacity(0.001))
            }
            .contentShape(bubbleShape)
            .glassEffect(in: bubbleShape)
        }
      } else {
        content
          .background(
            .ultraThinMaterial,
            in: bubbleShape
          )
          .background {
            bubbleShape
              .fill(Color.black.opacity(0.001))
          }
          .contentShape(bubbleShape)
      }
    #else
      content
        .background(
          .ultraThinMaterial,
          in: bubbleShape
        )
        .background {
          bubbleShape
            .fill(Color.black.opacity(0.001))
        }
        .contentShape(bubbleShape)
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
