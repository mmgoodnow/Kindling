import SwiftUI

struct TranscriptView: View {
  @ObservedObject var player: AudioPlayerController
  @ObservedObject var progress: AudioPlayerController.PlaybackProgressState
  let isTabActive: Bool

  @State private var isAutoFollowing: Bool = true
  @State private var lastScrolledUtteranceID: Int?
  @State private var isUserTouching: Bool = false

  private struct Segment: Identifiable, Equatable {
    let id: Int
    let startMs: Int
    let endMs: Int
    let text: String
  }

  private var segments: [Segment] {
    guard let transcript = player.transcript else { return [] }
    if let utterances = transcript.utterances, utterances.isEmpty == false {
      return utterances.map {
        Segment(id: $0.startMs, startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
      }
    }
    return synthesizedSegments(from: transcript.words)
  }

  private func currentSegmentID(in segments: [Segment]) -> Int? {
    let timeMs = Int(progress.currentTime * 1000)
    guard segments.isEmpty == false else { return nil }
    if timeMs < segments[0].startMs { return segments[0].id }
    var lo = 0
    var hi = segments.count - 1
    while lo <= hi {
      let mid = (lo + hi) / 2
      let s = segments[mid]
      if timeMs < s.startMs {
        hi = mid - 1
      } else if mid + 1 < segments.count, timeMs >= segments[mid + 1].startMs {
        lo = mid + 1
      } else {
        return s.id
      }
    }
    return segments.last?.id
  }

  var body: some View {
    let segments = segments
    let activeID = currentSegmentID(in: segments)

    ZStack(alignment: .bottomTrailing) {
      if segments.isEmpty {
        emptyState
      } else {
        transcriptScroll(segments: segments, activeID: activeID)
      }

      if isAutoFollowing == false, activeID != nil {
        resumeButton
          .padding(.trailing, 4)
          .padding(.bottom, 8)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.18), value: isAutoFollowing)
    .onChange(of: isTabActive) { _, nowActive in
      if nowActive {
        withAnimation(.easeInOut(duration: 0.2)) {
          isAutoFollowing = true
        }
        lastScrolledUtteranceID = nil
      }
    }
    .onChange(of: player.transcript) { _, _ in
      lastScrolledUtteranceID = nil
    }
  }

  private var emptyState: some View {
    VStack {
      Spacer()
      Text("No transcript available yet.")
        .font(.body)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private func transcriptScroll(segments: [Segment], activeID: Int?) -> some View {
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
                isPast: activeID.map { segment.endMs <= startMs(of: $0, in: segments) } ?? false
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

  private func startMs(of id: Int, in segments: [Segment]) -> Int {
    segments.first(where: { $0.id == id })?.startMs ?? 0
  }

  private func synthesizedSegments(from words: [PodibleTranscript.Word]) -> [Segment] {
    guard words.isEmpty == false else { return [] }
    var result: [Segment] = []
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

  private func makeSegment(from words: [PodibleTranscript.Word]) -> Segment {
    let start = words.first?.startMs ?? 0
    let end = words.last?.endMs ?? start
    let text = words.map(\.text).joined(separator: " ")
    return Segment(id: start, startMs: start, endMs: end, text: text)
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
