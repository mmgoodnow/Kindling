import SwiftUI

struct TranscriptView: View {
  @ObservedObject var player: AudioPlayerController
  let progress: AudioPlayerController.PlaybackProgressState
  let isTabActive: Bool

  @State private var segments: [TranscriptSegment] = []
  @State private var activeID: Int?
  @State private var activeStartMs: Int?
  @State private var isAutoFollowing: Bool = true
  @State private var lastScrolledUtteranceID: Int?
  @State private var isUserTouching: Bool = false

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if segments.isEmpty {
        emptyState
      } else {
        transcriptScroll(segments: segments, activeID: activeID, activeStartMs: activeStartMs)
      }

      if isAutoFollowing == false, activeID != nil {
        resumeButton
          .padding(.trailing, 4)
          .padding(.bottom, 8)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      if isTabActive {
        TranscriptProgressFollower(
          progress: progress,
          segments: segments,
          activeID: $activeID,
          activeStartMs: $activeStartMs
        )
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
      }
    }
    .animation(.easeInOut(duration: 0.18), value: isAutoFollowing)
    .onAppear {
      refreshSegments()
    }
    .onChange(of: isTabActive) { _, nowActive in
      if nowActive {
        withAnimation(.easeInOut(duration: 0.2)) {
          isAutoFollowing = true
        }
        lastScrolledUtteranceID = nil
      }
    }
    .onChange(of: player.transcript) { _, _ in
      refreshSegments()
      lastScrolledUtteranceID = nil
    }
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Spacer()
      switch player.transcriptLoadState {
      case .idle:
        Image(systemName: "text.page")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text("Transcript not loaded yet.")
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
        Text("Kindling will check Podible when remote playback starts.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      case .loading:
        ProgressView()
          .controlSize(.regular)
        Text("Loading transcript...")
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
        Text("Large transcripts can take a moment the first time.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      case .loaded:
        Image(systemName: "text.page")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text("Transcript loaded, but it has no displayable text.")
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
      case .unavailable(let message):
        Image(systemName: "text.page.badge.magnifyingglass")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text("No transcript available.")
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      case .failed(let message):
        Image(systemName: "exclamationmark.triangle")
          .font(.title2)
          .foregroundStyle(.orange)
        Text("Transcript could not load.")
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
  }

  private func transcriptScroll(
    segments: [TranscriptSegment],
    activeID: Int?,
    activeStartMs: Int?
  ) -> some View {
    GeometryReader { proxy in
      let topInset = proxy.size.height * 0.32
      let bottomInset = proxy.size.height * 0.5

      ScrollViewReader { scroller in
        ScrollView(showsIndicators: false) {
          LazyVStack(alignment: .leading, spacing: 18) {
            Color.clear.frame(height: topInset)
            ForEach(segments) { segment in
              TranscriptSegmentView(
                text: segment.text,
                isActive: segment.id == activeID,
                isPast: activeStartMs.map { segment.endMs <= $0 } ?? false
              ) {
                player.seek(to: Double(segment.startMs) / 1000.0)
                withAnimation(.easeInOut(duration: 0.25)) {
                  isAutoFollowing = true
                }
                lastScrolledUtteranceID = nil
              }
              .id(segment.id)
            }
            Color.clear.frame(height: bottomInset)
          }
          .padding(.horizontal, 4)
        }
        .simultaneousGesture(touchTracker)
        .onChange(of: activeID) { _, newID in
          guard let newID, newID != lastScrolledUtteranceID else { return }
          guard isAutoFollowing, isUserTouching == false else { return }
          lastScrolledUtteranceID = newID
          withAnimation(.easeInOut(duration: 0.45)) {
            scroller.scrollTo(newID, anchor: .center)
          }
        }
        .onChange(of: isAutoFollowing) { _, nowFollowing in
          guard nowFollowing, let activeID, isUserTouching == false else { return }
          lastScrolledUtteranceID = activeID
          withAnimation(.easeInOut(duration: 0.35)) {
            scroller.scrollTo(activeID, anchor: .center)
          }
        }
        .onAppear {
          if let activeID {
            lastScrolledUtteranceID = activeID
            scroller.scrollTo(activeID, anchor: .center)
          }
        }
      }
    }
  }

  private var touchTracker: some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { value in
        guard abs(value.translation.height) > abs(value.translation.width) else { return }
        if isUserTouching == false {
          isUserTouching = true
        }
        if isAutoFollowing {
          withAnimation(.easeInOut(duration: 0.18)) {
            isAutoFollowing = false
          }
        }
      }
      .onEnded { _ in
        isUserTouching = false
      }
  }

  private var resumeButton: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.25)) {
        isAutoFollowing = true
      }
    } label: {
      Label("Now Playing", systemImage: "dot.radiowaves.left.and.right")
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 0.5))
    }
    .buttonStyle(.plain)
    .foregroundStyle(.accent)
  }

  private func refreshSegments() {
    segments = Self.transcriptSegments(from: player.transcript)
  }

  private static func transcriptSegments(from transcript: PodibleTranscript?) -> [TranscriptSegment]
  {
    guard let transcript else { return [] }
    if let utterances = transcript.utterances, utterances.isEmpty == false {
      return utterances.map {
        TranscriptSegment(id: $0.startMs, startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
      }
    }
    return synthesizedSegments(from: transcript.words)
  }

  private static func synthesizedSegments(from words: [PodibleTranscript.Word])
    -> [TranscriptSegment]
  {
    guard words.isEmpty == false else { return [] }
    var result: [TranscriptSegment] = []
    var bucket: [PodibleTranscript.Word] = []
    let targetMs = 4000
    var bucketStart = words[0].startMs
    for word in words {
      if bucket.isEmpty { bucketStart = word.startMs }
      bucket.append(word)
      if word.endMs - bucketStart >= targetMs {
        result.append(makeSegment(from: bucket))
        bucket.removeAll(keepingCapacity: true)
      }
    }
    if bucket.isEmpty == false {
      result.append(makeSegment(from: bucket))
    }
    return result
  }

  private static func makeSegment(from words: [PodibleTranscript.Word]) -> TranscriptSegment {
    let start = words.first?.startMs ?? 0
    let end = words.last?.endMs ?? start
    let text = words.map(\.text).joined(separator: " ")
    return TranscriptSegment(id: start, startMs: start, endMs: end, text: text)
  }
}

private struct TranscriptSegment: Identifiable, Equatable {
  let id: Int
  let startMs: Int
  let endMs: Int
  let text: String
}

private struct TranscriptProgressFollower: View {
  @ObservedObject var progress: AudioPlayerController.PlaybackProgressState
  let segments: [TranscriptSegment]
  @Binding var activeID: Int?
  @Binding var activeStartMs: Int?

  var body: some View {
    Color.clear
      .onAppear {
        updateActiveSegment()
      }
      .onChange(of: progress.currentTime) { _, _ in
        updateActiveSegment()
      }
      .onChange(of: segments) { _, _ in
        updateActiveSegment()
      }
  }

  private func updateActiveSegment() {
    let segment = currentSegment()
    guard activeID != segment?.id || activeStartMs != segment?.startMs else { return }
    activeID = segment?.id
    activeStartMs = segment?.startMs
  }

  private func currentSegment() -> TranscriptSegment? {
    let timeMs = Int(progress.currentTime * 1000)
    guard segments.isEmpty == false else { return nil }
    if timeMs < segments[0].startMs { return segments[0] }
    var lo = 0
    var hi = segments.count - 1
    while lo <= hi {
      let mid = (lo + hi) / 2
      let segment = segments[mid]
      if timeMs < segment.startMs {
        hi = mid - 1
      } else if mid + 1 < segments.count, timeMs >= segments[mid + 1].startMs {
        lo = mid + 1
      } else {
        return segment
      }
    }
    return segments.last
  }
}

private struct TranscriptSegmentView: View {
  let text: String
  let isActive: Bool
  let isPast: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      Text(text)
        .font(.title3.weight(.semibold))
        .foregroundStyle(foreground)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.25), value: isActive)
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
  }

  private var foreground: Color {
    if isActive { return .primary }
    return Color.primary.opacity(isPast ? 0.28 : 0.42)
  }
}
