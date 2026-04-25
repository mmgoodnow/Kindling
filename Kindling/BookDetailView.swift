import SwiftData
import SwiftUI

/// Bag of optional callbacks the detail view dispatches into the parent.
/// `nil` means the action isn't applicable (e.g. no remote client, or no
/// downloaded audio yet).
enum AudioDownloadState {
  case idle
  case inProgress(Double?)  // nil = indeterminate, otherwise 0...1
}

struct BookDetailActions {
  var play: (() -> Void)?
  var downloadAudio: (() -> Void)?
  var audioDownload: AudioDownloadState = .idle
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
      .padding(.top, 16)
      // Reserve room for the floating action button so the last paragraph
      // isn't hidden underneath it.
      .padding(.bottom, 96)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(item.title)
    .navigationBarTitleDisplayMode(.inline)
    .overlay(alignment: .bottom) {
      floatingActionDock
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
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

  // MARK: - Floating action dock

  /// Floating action dock anchored to the bottom of the screen. Hosts the
  /// primary play / download button plus a row of icon-only secondary
  /// actions. Uses Liquid Glass on iOS 26+, regular material as a fallback.
  @ViewBuilder
  private var floatingActionDock: some View {
    let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
    VStack(spacing: 12) {
      primaryActionContent
      if hasSecondaryActions {
        secondaryActionsRow
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity)
    .background {
      if #available(iOS 26.0, *) {
        shape.fill(.clear).glassEffect(in: shape)
      } else {
        shape.fill(.regularMaterial)
      }
    }
    .overlay {
      shape.stroke(.white.opacity(0.08), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
  }

  private var secondaryActionsRow: some View {
    HStack(spacing: 0) {
      if let shareEbook = actions.shareEbook {
        dockIconButton(
          systemImage: "square.and.arrow.up", accessibilityLabel: "Share eBook",
          action: shareEbook)
      }
      if let emailToKindle = actions.emailToKindle {
        dockIconButton(
          systemImage: "paperplane", accessibilityLabel: "Send to Kindle",
          action: emailToKindle)
      }
      if let reportIssue = actions.reportIssue {
        dockIconButton(
          systemImage: "exclamationmark.triangle", accessibilityLabel: "Report Issue",
          tint: .orange, action: reportIssue)
      }
      if let deleteRemote = actions.deleteRemote {
        dockIconButton(
          systemImage: "trash", accessibilityLabel: "Delete",
          tint: .red, action: deleteRemote)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func dockIconButton(
    systemImage: String,
    accessibilityLabel: String,
    tint: Color? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.title3)
        .frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(tint ?? .accentColor)
    .accessibilityLabel(accessibilityLabel)
  }

  @ViewBuilder
  private var primaryActionContent: some View {
    switch actions.audioDownload {
    case .inProgress(let value):
      downloadingContent(progress: value)
    case .idle:
      if let play = actions.play {
        Button(action: play) {
          Label("Play", systemImage: "play.fill")
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      } else if let downloadAudio = actions.downloadAudio {
        Button(action: downloadAudio) {
          Label("Download Audiobook", systemImage: "arrow.down.circle")
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      } else {
        Label("Audio Unavailable", systemImage: "speaker.slash")
          .font(.body.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
      }
    }
  }

  @ViewBuilder
  private func downloadingContent(progress: Double?) -> some View {
    VStack(spacing: 6) {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text(progressLabel(progress))
          .font(.body.weight(.semibold))
          .monospacedDigit()
      }
      if let progress {
        ProgressView(value: progress)
          .progressViewStyle(.linear)
      } else {
        ProgressView()
          .progressViewStyle(.linear)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func progressLabel(_ progress: Double?) -> String {
    guard let progress else { return "Downloading…" }
    return "Downloading… \(Int((progress * 100).rounded()))%"
  }

  // MARK: - Secondary actions

  private var hasSecondaryActions: Bool {
    actions.shareEbook != nil
      || actions.emailToKindle != nil
      || actions.reportIssue != nil
      || actions.deleteRemote != nil
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
