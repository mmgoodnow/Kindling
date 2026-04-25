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
    .toolbar {
      if hasSecondaryActions {
        ToolbarItem(placement: .topBarTrailing) {
          secondaryActionsMenu
        }
      }
    }
    .overlay(alignment: .bottom) {
      floatingPrimaryButton
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

  // MARK: - Floating primary action

  /// Pill-shaped floating button anchored to the bottom of the screen.
  /// Uses Liquid Glass on iOS 26+, regular material as a fallback.
  @ViewBuilder
  private var floatingPrimaryButton: some View {
    primaryActionContent
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity)
      .background {
        if #available(iOS 26.0, *) {
          Capsule().fill(.clear).glassEffect(in: Capsule())
        } else {
          Capsule().fill(.regularMaterial)
        }
      }
      .overlay {
        Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5)
      }
      .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
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

  // MARK: - Secondary actions menu

  private var hasSecondaryActions: Bool {
    actions.shareEbook != nil
      || actions.emailToKindle != nil
      || actions.reportIssue != nil
      || actions.deleteRemote != nil
  }

  private var secondaryActionsMenu: some View {
    Menu {
      if let shareEbook = actions.shareEbook {
        Button {
          shareEbook()
        } label: {
          Label("Share eBook", systemImage: "square.and.arrow.up")
        }
      }
      if let emailToKindle = actions.emailToKindle {
        Button {
          emailToKindle()
        } label: {
          Label("Send to Kindle", systemImage: "paperplane")
        }
      }
      if let reportIssue = actions.reportIssue {
        Button {
          reportIssue()
        } label: {
          Label("Report Issue", systemImage: "exclamationmark.triangle")
        }
      }
      if let deleteRemote = actions.deleteRemote {
        Button(role: .destructive) {
          deleteRemote()
        } label: {
          Label("Delete", systemImage: "trash")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
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
