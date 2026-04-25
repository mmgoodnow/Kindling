import SwiftData
import SwiftUI

/// Bag of optional callbacks the detail view dispatches into the parent.
/// `nil` means the action isn't applicable (e.g. no remote client, or no
/// downloaded audio yet).
struct BookDetailActions {
  var play: (() -> Void)?
  var downloadAudio: (() -> Void)?
  var shareEbook: (() -> Void)?
  var emailToKindle: (() -> Void)?
  var reportIssue: (() -> Void)?
  var deleteRemote: (() -> Void)?
}

/// Detail screen for a single book. Accepts a `PodibleLibraryItem` (which may be
/// a remote-fetched item or a local proxy) and the optional locally-mirrored
/// `LibraryBook`. Designed to push onto the parent `NavigationStack`.
struct BookDetailView: View {
  @EnvironmentObject var userSettings: UserSettings
  @EnvironmentObject var podibleAuth: PodibleAuthController

  let item: PodibleLibraryItem
  let localBook: LibraryBook?
  let actions: BookDetailActions
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
    if let summary = item.summary, summary.isEmpty == false {
      return summary
    }
    if let summary = localBook?.summary, summary.isEmpty == false {
      return summary
    }
    return nil
  }

  // MARK: - Actions

  private var actionBar: some View {
    VStack(spacing: 10) {
      primaryAudioButton
      if hasSecondaryActions {
        HStack(spacing: 12) {
          if let shareEbook = actions.shareEbook {
            secondaryButton("Share eBook", systemImage: "square.and.arrow.up", action: shareEbook)
          }
          if let emailToKindle = actions.emailToKindle {
            secondaryButton("Send to Kindle", systemImage: "paperplane", action: emailToKindle)
          }
          if let reportIssue = actions.reportIssue {
            secondaryButton(
              "Report Issue", systemImage: "exclamationmark.triangle", tint: .orange,
              action: reportIssue)
          }
          if let deleteRemote = actions.deleteRemote {
            secondaryButton(
              "Delete", systemImage: "trash", tint: .red, action: deleteRemote)
          }
        }
        .frame(maxWidth: .infinity)
      }
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private var primaryAudioButton: some View {
    if let play = actions.play {
      Button(action: play) {
        Label("Play", systemImage: "play.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    } else if let downloadAudio = actions.downloadAudio {
      Button(action: downloadAudio) {
        Label("Download Audiobook", systemImage: "arrow.down.circle")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    } else {
      Button {
      } label: {
        Label("Audio Unavailable", systemImage: "speaker.slash")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .disabled(true)
    }
  }

  private var hasSecondaryActions: Bool {
    actions.shareEbook != nil
      || actions.emailToKindle != nil
      || actions.reportIssue != nil
      || actions.deleteRemote != nil
  }

  private func secondaryButton(
    _ label: String,
    systemImage: String,
    tint: Color? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(systemName: systemImage)
          .font(.body)
        Text(label)
          .font(.caption2)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.bordered)
    .tint(tint ?? .accentColor)
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
