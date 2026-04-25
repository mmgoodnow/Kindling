import SwiftData
import SwiftUI

/// Detail screen for a single book. Accepts a `PodibleLibraryItem` (which may be
/// a remote-fetched item or a local proxy) and the optional locally-mirrored
/// `LibraryBook`. Designed to push onto the parent `NavigationStack`.
///
/// First slice: hero, metadata, summary, Play action. Download/share/Kindle/etc
/// land in subsequent commits. Chapters land once `ChapterListView` is extracted
/// from `LocalPlaybackView`.
struct BookDetailView: View {
  @EnvironmentObject var userSettings: UserSettings
  @EnvironmentObject var podibleAuth: PodibleAuthController

  let item: PodibleLibraryItem
  let localBook: LibraryBook?
  let onPlay: (() -> Void)?
  let onPresentPlayer: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        hero
        metricsLine
        if let summary = displaySummary, summary.isEmpty == false {
          VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
              .font(.headline)
            Text(summary)
              .font(.body)
              .foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(item.title)
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) {
      actionBar
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
  }

  // MARK: - Hero

  private var hero: some View {
    VStack(alignment: .center, spacing: 16) {
      heroCover
        .frame(maxWidth: .infinity, alignment: .center)
      VStack(spacing: 4) {
        Text(item.title)
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)
        Text(item.author)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
    }
    .padding(.top, 8)
  }

  @ViewBuilder
  private var heroCover: some View {
    let url = remoteLibraryAssetURL(
      baseURLString: userSettings.podibleRPCURL,
      path: item.bookImagePath
    )
    if let url {
      AuthenticatedRemoteImage(
        url: url,
        rpcURLString: userSettings.podibleRPCURL,
        accessToken: podibleAuth.accessToken
      ) {
        bookCoverPlaceholder(title: item.title, author: item.author)
          .frame(width: 200, height: 290)
      }
      .scaledToFill()
      .frame(width: 200, height: 290)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .shadow(radius: 8, y: 4)
    } else {
      bookCoverPlaceholder(title: item.title, author: item.author)
        .frame(width: 200, height: 290)
    }
  }

  // MARK: - Metrics

  @ViewBuilder
  private var metricsLine: some View {
    if let text = metricsText {
      Text(text)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  private var metricsText: String? {
    let runtimeSeconds = item.runtimeSeconds ?? localBook?.runtimeSeconds
    let wordCount = item.wordCount ?? localBook?.wordCount
    var parts: [String] = []
    if let runtimeSeconds, runtimeSeconds > 0 {
      parts.append(formatRuntime(seconds: runtimeSeconds))
    }
    if let wordCount, wordCount > 0 {
      parts.append("\(formatWordCount(wordCount)) words")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " • ")
  }

  private var displaySummary: String? {
    if let summary = localBook?.summary, summary.isEmpty == false {
      return summary
    }
    return nil
  }

  // MARK: - Actions

  private var actionBar: some View {
    HStack {
      Button {
        onPlay?()
      } label: {
        Label("Play", systemImage: "play.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(onPlay == nil)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Formatting

  private func formatRuntime(seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 {
      return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    return "\(minutes)m"
  }

  private func formatWordCount(_ count: Int) -> String {
    if count >= 1000 {
      let thousands = Double(count) / 1000.0
      return String(format: thousands >= 100 ? "%.0fk" : "%.1fk", thousands)
    }
    return "\(count)"
  }
}
