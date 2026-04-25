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

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        hero
        metricsLine
        if let summary = displaySummary, summary.isEmpty == false {
          Text(summary)
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .padding(.bottom, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(item.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if hasMenuActions {
        ToolbarItem(placement: .topBarTrailing) {
          overflowMenu
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      floatingActionDock
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
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

  /// Bottom dock pinned via `.safeAreaInset` so scroll content insets behind
  /// it. Uses `GlassEffectContainer` on iOS 26+ so the buttons sample the
  /// background coherently and morph correctly during animations. Each
  /// button gets its own glass shape via the system button styles.
  @ViewBuilder
  private var floatingActionDock: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: 12) {
        dockButtons
      }
    } else {
      dockButtons
    }
  }

  private var dockButtons: some View {
    HStack(spacing: 12) {
      if let shareEbook = actions.shareEbook {
        secondaryGlassButton(
          systemImage: "square.and.arrow.up",
          accessibilityLabel: "Share eBook",
          action: shareEbook)
      }
      if let emailToKindle = actions.emailToKindle {
        secondaryGlassButton(
          systemImage: "paperplane",
          accessibilityLabel: "Send to Kindle",
          action: emailToKindle)
      }
      primaryButton
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: Primary

  @ViewBuilder
  private var primaryButton: some View {
    switch actions.audioDownload {
    case .inProgress(let progress):
      downloadingCapsule(progress: progress)
    case .idle:
      if let play = actions.play {
        primaryGlassButton(
          title: "Play", systemImage: "play.fill", action: play)
      } else if let downloadAudio = actions.downloadAudio {
        primaryGlassButton(
          title: "Download Audiobook",
          systemImage: "arrow.down.circle",
          action: downloadAudio)
      } else {
        primaryGlassButton(
          title: "Audio Unavailable",
          systemImage: "speaker.slash",
          isEnabled: false,
          action: {})
      }
    }
  }

  @ViewBuilder
  private func primaryGlassButton(
    title: String,
    systemImage: String,
    isEnabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    let button = Button(action: action) {
      Label {
        Text(title).font(.title3.weight(.semibold))
      } icon: {
        Image(systemName: systemImage).font(.title2.weight(.semibold))
      }
      .frame(maxWidth: .infinity)
    }
    .controlSize(.large)
    .disabled(isEnabled == false)

    if #available(iOS 26.0, *) {
      button
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    } else {
      button
        .buttonStyle(.bordered)
        .clipShape(Capsule())
    }
  }

  // MARK: Secondary

  @ViewBuilder
  private func secondaryGlassButton(
    systemImage: String,
    accessibilityLabel: String,
    tint: Color? = nil,
    action: @escaping () -> Void
  ) -> some View {
    let button = Button(action: action) {
      Image(systemName: systemImage)
        .font(.title2.weight(.semibold))
    }
    .controlSize(.large)
    .accessibilityLabel(accessibilityLabel)
    .tint(tint ?? .accentColor)

    if #available(iOS 26.0, *) {
      button
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    } else {
      button
        .buttonStyle(.bordered)
        .clipShape(Circle())
    }
  }

  @ViewBuilder
  private func downloadingCapsule(progress: Double?) -> some View {
    let content = VStack(spacing: 6) {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text(progressLabel(progress))
          .font(.body.weight(.semibold))
          .monospacedDigit()
      }
      if let progress {
        ProgressView(value: progress, total: 1.0)
          .progressViewStyle(.linear)
      } else {
        ProgressView()
          .progressViewStyle(.linear)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity)

    if #available(iOS 26.0, *) {
      content.glassEffect(.regular, in: Capsule())
    } else {
      content.background(Capsule().fill(.regularMaterial))
    }
  }

  private func progressLabel(_ progress: Double?) -> String {
    guard let progress else { return "Downloading…" }
    return "Downloading… \(Int((progress * 100).rounded()))%"
  }

  // MARK: - Overflow menu

  /// True if at least one of the menu-eligible actions is present.
  /// Share + Kindle are duplicated in the overflow menu (they also live in
  /// the dock as icons) so users have text-labelled access to them. Report
  /// and Delete only live here.
  private var hasMenuActions: Bool {
    actions.shareEbook != nil
      || actions.emailToKindle != nil
      || actions.reportIssue != nil
      || actions.deleteRemote != nil
  }

  private var overflowMenu: some View {
    Menu {
      if let shareEbook = actions.shareEbook {
        Button(action: shareEbook) {
          Label("Share eBook", systemImage: "square.and.arrow.up")
        }
      }
      if let emailToKindle = actions.emailToKindle {
        Button(action: emailToKindle) {
          Label("Send to Kindle", systemImage: "paperplane")
        }
      }
      if let reportIssue = actions.reportIssue {
        Button(action: reportIssue) {
          Label("Report Issue", systemImage: "exclamationmark.triangle")
        }
      }
      if let deleteRemote = actions.deleteRemote {
        Button(role: .destructive, action: deleteRemote) {
          Label("Delete", systemImage: "trash")
        }
      }
    } label: {
      Image(systemName: "ellipsis")
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
