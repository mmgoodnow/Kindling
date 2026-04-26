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
  var fetchAlternateCovers: (() async throws -> [PodibleAlternateCover])?
  var setAlternateCover: ((PodibleAlternateCover) async throws -> PodibleLibraryItem)?
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
  @EnvironmentObject var player: AudioPlayerController

  let item: PodibleLibraryItem
  let localBook: LibraryBook?
  let actions: BookDetailActions
  /// True if the audio is available remotely but not on disk (streamed only).
  let isStreamOnly: Bool
  @Binding var isShowingPlayer: Bool
  @State private var isShowingCoverPicker = false
  @State private var coverImagePathOverride: String?

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
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if hasMenuActions {
          ToolbarItem(placement: .topBarTrailing) {
            overflowMenu
          }
        }
      }
    #else
      .toolbar {
        if hasMenuActions {
          ToolbarItem(placement: .primaryAction) {
            overflowMenu
          }
        }
      }
    #endif
    // Modifier order is outermost-wins: the LAST applied `.safeAreaInset`
    // sits closest to the screen edge. Mini bar applied first → ends up
    // ABOVE the dock; dock applied second → hugs the screen edge.
    .miniPlaybackBarInset(player: player, isShowingPlayer: $isShowingPlayer)
    // `spacing: 8` puts the gap between the dock and whatever sits above it
    // in the safe-area stack (the mini bar). Localizes the gap so the mini
    // bar doesn't carry padding it shouldn't on screens without a dock.
    .safeAreaInset(edge: .bottom, spacing: 8) {
      floatingActionDock
        .padding(.leading, 20)
        // Slightly more trailing padding than leading: the mini bar's
        // play/pause glass-circle button carries built-in slop on its right
        // edge, so the dock's right edge looks misaligned with it without
        // a small extra nudge here.
        .padding(.trailing, 28)
    }
    .sheet(isPresented: $isShowingCoverPicker) {
      BookCoverPickerSheet(
        title: item.title,
        author: item.author,
        currentImagePath: currentCoverImagePath,
        fetchAlternateCovers: actions.fetchAlternateCovers,
        applyAlternateCover: { cover in
          let updated = try await actions.setAlternateCover?(cover)
          await MainActor.run {
            coverImagePathOverride = updated?.bookImagePath
          }
        }
      )
      .environmentObject(userSettings)
      .environmentObject(podibleAuth)
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

  private var currentCoverImagePath: String? {
    coverImagePathOverride ?? localBook?.coverURLString ?? item.bookImagePath
  }

  private var currentCoverVersionToken: String? {
    let date = localBook?.updatedAt ?? item.updatedAt
    return date.map { String(Int($0.timeIntervalSince1970)) }
  }

  @ViewBuilder
  private var heroCover: some View {
    let url = remoteLibraryAssetURL(
      baseURLString: userSettings.podibleRPCURL,
      path: currentCoverImagePath,
      versionToken: currentCoverVersionToken
    )
    if canChangeCover {
      Button {
        isShowingCoverPicker = true
      } label: {
        heroCoverArtwork(url: url)
          .overlay(alignment: .bottomTrailing) {
            Image(systemName: "photo.badge.plus")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.primary)
              .padding(8)
              .background(.ultraThinMaterial, in: Circle())
              .padding(10)
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Change Cover")
    } else {
      heroCoverArtwork(url: url)
    }
  }

  @ViewBuilder
  private func heroCoverArtwork(url: URL?) -> some View {
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
    if metricsText != nil || isStreamOnly {
      HStack(spacing: 8) {
        if let text = metricsText {
          Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        if isStreamOnly {
          Image(systemName: "cloud")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Not downloaded")
        }
      }
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
  private var floatingActionDock: some View {
    GlassEffectContainer(spacing: 12) {
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
      // Standalone "save offline" affordance — only when the user could
      // also play (= is currently streaming). When there's no play action
      // (audio not available), don't surface a lone download here — the
      // primaryButton already collapses to the download state.
      if actions.play != nil, let downloadAudio = actions.downloadAudio {
        secondaryGlassButton(
          systemImage: "arrow.down.circle",
          accessibilityLabel: "Download for Offline",
          action: downloadAudio)
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

    button
      .buttonStyle(.glass)
      .buttonBorderShape(.capsule)
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

    button
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
  }

  private func downloadingCapsule(progress: Double?) -> some View {
    VStack(spacing: 6) {
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
    .glassEffect(.regular, in: Capsule())
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
    canChangeCover
      || actions.fetchAlternateCovers != nil
      || actions.setAlternateCover != nil
      || actions.shareEbook != nil
      || actions.emailToKindle != nil
      || actions.reportIssue != nil
      || actions.deleteRemote != nil
  }

  private var canChangeCover: Bool {
    actions.fetchAlternateCovers != nil && actions.setAlternateCover != nil
  }

  private var overflowMenu: some View {
    Menu {
      if canChangeCover {
        Button {
          isShowingCoverPicker = true
        } label: {
          Label("Change Cover", systemImage: "photo.badge.plus")
        }
      }
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

private struct BookCoverPickerSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var userSettings: UserSettings
  @EnvironmentObject private var podibleAuth: PodibleAuthController

  let title: String
  let author: String
  let currentImagePath: String?
  let fetchAlternateCovers: (() async throws -> [PodibleAlternateCover])?
  let applyAlternateCover: ((PodibleAlternateCover) async throws -> Void)?

  @State private var covers: [PodibleAlternateCover] = []
  @State private var selectedCoverID: Int?
  @State private var isLoading = false
  @State private var isApplying = false
  @State private var errorMessage: String?

  private let columns = [
    GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 14)
  ]

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        selectedPreview
        if let errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        content
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .padding(.bottom, 20)
      .navigationTitle("Change Cover")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Use This Cover") {
            Task {
              await applySelection()
            }
          }
          .disabled(selectedCover == nil || isApplying)
        }
      }
      .task {
        await loadCoversIfNeeded()
      }
    }
  }

  @ViewBuilder
  private var selectedPreview: some View {
    VStack(spacing: 12) {
      previewImage(path: selectedCover?.imagePath ?? currentImagePath)
      VStack(spacing: 4) {
        Text(title)
          .font(.headline)
          .multilineTextAlignment(.center)
        Text(author)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if isLoading {
      Spacer(minLength: 0)
      ProgressView("Loading Covers…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Spacer(minLength: 0)
    } else if covers.isEmpty {
      ContentUnavailableView(
        "No Alternate Covers",
        systemImage: "photo.on.rectangle",
        description: Text("Open Library doesn't have any alternate covers for this book.")
      )
    } else {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 14) {
          ForEach(covers) { cover in
            Button {
              selectedCoverID = cover.id
            } label: {
              previewImage(path: cover.imagePath)
                .overlay(alignment: .topTrailing) {
                  if selectedCoverID == cover.id {
                    Image(systemName: "checkmark.circle.fill")
                      .font(.title3)
                      .foregroundStyle(.white, .accent)
                      .padding(8)
                  }
                }
                .overlay {
                  RoundedRectangle(cornerRadius: 10)
                    .stroke(
                      selectedCoverID == cover.id ? Color.accentColor : Color.clear,
                      lineWidth: 3
                    )
                }
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.bottom, 8)
      }
    }
  }

  private var selectedCover: PodibleAlternateCover? {
    covers.first(where: { $0.id == selectedCoverID })
  }

  @ViewBuilder
  private func previewImage(path: String?) -> some View {
    let url = remoteLibraryAssetURL(
      baseURLString: userSettings.podibleRPCURL,
      path: path
    )
    ZStack {
      bookCoverPlaceholder(title: title, author: author)
      if let url {
        AuthenticatedRemoteImage(
          url: url,
          rpcURLString: userSettings.podibleRPCURL,
          accessToken: podibleAuth.accessToken
        ) {
          Color.clear
        }
        .scaledToFill()
      }
    }
    .frame(width: 132, height: 192)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .shadow(radius: 6, y: 3)
  }

  @MainActor
  private func loadCoversIfNeeded() async {
    guard covers.isEmpty, isLoading == false else { return }
    guard let fetchAlternateCovers else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      let fetched = try await fetchAlternateCovers()
      covers = fetched
      if selectedCoverID == nil {
        selectedCoverID = fetched.first?.id
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func applySelection() async {
    guard isApplying == false else { return }
    guard let selectedCover else { return }
    guard let applyAlternateCover else { return }
    isApplying = true
    errorMessage = nil
    defer { isApplying = false }
    do {
      try await applyAlternateCover(selectedCover)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
