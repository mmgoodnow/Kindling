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
  var searchReleases: ((PodibleReleaseMedia, String?) async throws -> PodibleReleaseSearch)?
  var createManifestationFromSearch:
    ((PodibleManifestationSearchSelection) async throws -> PodibleCreateManifestationResult)?
  var shareEbook: (() -> Void)?
  var emailToKindle: (() -> Void)?
  var reportAudioIssue: (() -> Void)?
  var reportEbookIssue: (() -> Void)?
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
  @State private var isShowingReleaseSearch = false
  @State private var releaseSearchInitialMedia: PodibleReleaseMedia = .audio
  @State private var coverImagePathOverride: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        hero
        metricsLine
        audioEditionSection
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
    .sheet(isPresented: $isShowingReleaseSearch) {
      BookReleaseSearchSheet(
        title: item.title,
        author: item.author,
        initialMedia: releaseSearchInitialMedia,
        searchReleases: actions.searchReleases,
        createManifestationFromSearch: actions.createManifestationFromSearch
      )
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
        bookCoverPlaceholder(
          title: item.title,
          author: item.author,
          width: 200,
          height: 290,
          cornerRadius: 10
        )
      }
      .scaledToFill()
      .frame(width: 200, height: 290)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .shadow(radius: 8, y: 4)
    } else {
      bookCoverPlaceholder(
        title: item.title,
        author: item.author,
        width: 200,
        height: 290,
        cornerRadius: 10
      )
      .shadow(radius: 8, y: 4)
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

  @ViewBuilder
  private var audioEditionSection: some View {
    if let audio = item.playback?.audio {
      VStack(alignment: .leading, spacing: 6) {
        Text("Audio Edition")
          .font(.caption.weight(.semibold))
          .textCase(.uppercase)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 4) {
          Text(audio.label?.isEmpty == false ? audio.label! : "Default Audio")
            .font(.subheadline.weight(.semibold))
          if let editionNote = audio.editionNote, editionNote.isEmpty == false {
            Text(editionNote)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          if audioEditionMetadata(audio).isEmpty == false {
            Text(audioEditionMetadata(audio))
              .font(.footnote)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
  }

  private func audioEditionMetadata(_ audio: PodiblePlaybackAudio) -> String {
    var parts: [String] = []
    if let durationMs = audio.durationMs, durationMs > 0 {
      parts.append(formatRuntime(seconds: Int((durationMs + 500) / 1000)))
    }
    if audio.sizeBytes > 0 {
      parts.append(ByteCountFormatter.string(fromByteCount: audio.sizeBytes, countStyle: .file))
    }
    return parts.joined(separator: " • ")
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
      } else if canSearchReleases {
        primaryGlassButton(
          title: "Find Audiobook",
          systemImage: "magnifyingglass",
          action: { openReleaseSearch(media: .audio) })
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
      || canSearchReleases
      || actions.fetchAlternateCovers != nil
      || actions.setAlternateCover != nil
      || actions.shareEbook != nil
      || actions.emailToKindle != nil
      || actions.reportAudioIssue != nil
      || actions.reportEbookIssue != nil
      || actions.deleteRemote != nil
  }

  private var canChangeCover: Bool {
    actions.fetchAlternateCovers != nil && actions.setAlternateCover != nil
  }

  private var canSearchReleases: Bool {
    actions.searchReleases != nil && actions.createManifestationFromSearch != nil
  }

  private func openReleaseSearch(media: PodibleReleaseMedia) {
    releaseSearchInitialMedia = media
    isShowingReleaseSearch = true
  }

  private var overflowMenu: some View {
    Menu {
      if canSearchReleases {
        Button {
          openReleaseSearch(media: .audio)
        } label: {
          Label("Find Audio", systemImage: "headphones")
        }
        Button {
          openReleaseSearch(media: .ebook)
        } label: {
          Label("Find eBook", systemImage: "book")
        }
      }
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
      if let reportAudioIssue = actions.reportAudioIssue {
        Button(action: reportAudioIssue) {
          Label("Report Audio Issue", systemImage: "exclamationmark.triangle")
        }
      }
      if let reportEbookIssue = actions.reportEbookIssue {
        Button(action: reportEbookIssue) {
          Label("Report eBook Issue", systemImage: "exclamationmark.triangle")
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

private struct BookReleaseSearchSheet: View {
  @Environment(\.dismiss) private var dismiss

  let title: String
  let author: String
  let initialMedia: PodibleReleaseMedia
  let searchReleases: ((PodibleReleaseMedia, String?) async throws -> PodibleReleaseSearch)?
  let createManifestationFromSearch:
    ((PodibleManifestationSearchSelection) async throws -> PodibleCreateManifestationResult)?

  @State private var media: PodibleReleaseMedia
  @State private var query = ""
  @State private var editionLabel = ""
  @State private var editionNote = ""
  @State private var search: PodibleReleaseSearch?
  @State private var selectedIndexes: [Int] = []
  @State private var isSearching = false
  @State private var isCreating = false
  @State private var errorMessage: String?

  init(
    title: String,
    author: String,
    initialMedia: PodibleReleaseMedia,
    searchReleases: ((PodibleReleaseMedia, String?) async throws -> PodibleReleaseSearch)?,
    createManifestationFromSearch:
      ((PodibleManifestationSearchSelection) async throws -> PodibleCreateManifestationResult)?
  ) {
    self.title = title
    self.author = author
    self.initialMedia = initialMedia
    self.searchReleases = searchReleases
    self.createManifestationFromSearch = createManifestationFromSearch
    _media = State(initialValue: initialMedia)
  }

  var body: some View {
    NavigationStack {
      Form {
        searchSection
        editionSection
        resultsSection
      }
      .navigationTitle("Find Releases")
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
          Button(isCreating ? "Creating…" : createButtonTitle) {
            Task {
              await createSelection()
            }
          }
          .disabled(canCreate == false)
        }
      }
      .task {
        await runSearchIfNeeded()
      }
      .onChange(of: media) { _, _ in
        search = nil
        selectedIndexes = []
        errorMessage = nil
        Task {
          await runSearch()
        }
      }
    }
  }

  private var searchSection: some View {
    Section {
      Picker("Media", selection: $media) {
        ForEach(PodibleReleaseMedia.allCases) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.segmented)

      TextField(defaultQuery, text: $query)
        #if os(iOS)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled()
        #endif

      Button {
        Task {
          await runSearch()
        }
      } label: {
        if isSearching {
          HStack(spacing: 8) {
            ProgressView()
            Text("Searching…")
          }
        } else {
          Label("Search", systemImage: "magnifyingglass")
        }
      }
      .disabled(isSearching)

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Search")
    } footer: {
      if let search {
        Text("Showing results for “\(search.query)”.")
      } else {
        Text("Search your configured indexers and choose releases in playback order.")
      }
    }
  }

  private var editionSection: some View {
    Section {
      TextField("Optional label", text: $editionLabel)
      TextField("Optional note", text: $editionNote)
    } header: {
      Text("Edition")
    }
  }

  @ViewBuilder
  private var resultsSection: some View {
    Section {
      if isSearching && search == nil {
        HStack(spacing: 8) {
          ProgressView()
          Text("Searching…")
            .foregroundStyle(.secondary)
        }
      } else if let search, search.results.isEmpty {
        ContentUnavailableView(
          "No Results",
          systemImage: "magnifyingglass",
          description: Text("Try a different search query.")
        )
      } else if let search {
        ForEach(search.results) { result in
          Button {
            toggleSelection(result.index)
          } label: {
            ReleaseSearchResultRow(
              result: result,
              selectedOrder: selectedOrder(for: result.index)
            )
          }
          .buttonStyle(.plain)
        }
      } else {
        ContentUnavailableView(
          "No Search Yet",
          systemImage: "magnifyingglass",
          description: Text("Run a search to see release options.")
        )
      }
    } header: {
      Text("Results")
    } footer: {
      if selectedIndexes.isEmpty == false {
        Text("\(selectedIndexes.count) selected. Tap selected rows again to remove them.")
      }
    }
  }

  private var defaultQuery: String {
    "\(title) \(author)"
  }

  private var canCreate: Bool {
    isCreating == false && selectedIndexes.isEmpty == false && search != nil
  }

  private var createButtonTitle: String {
    selectedIndexes.count <= 1 ? "Create" : "Create \(selectedIndexes.count)"
  }

  private func selectedOrder(for index: Int) -> Int? {
    selectedIndexes.firstIndex(of: index).map { $0 + 1 }
  }

  private func toggleSelection(_ index: Int) {
    if let existing = selectedIndexes.firstIndex(of: index) {
      selectedIndexes.remove(at: existing)
    } else {
      selectedIndexes.append(index)
    }
  }

  @MainActor
  private func runSearchIfNeeded() async {
    guard search == nil else { return }
    await runSearch()
  }

  @MainActor
  private func runSearch() async {
    guard isSearching == false else { return }
    guard let searchReleases else { return }
    isSearching = true
    errorMessage = nil
    selectedIndexes = []
    defer { isSearching = false }
    do {
      let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
      search = try await searchReleases(media, trimmed.isEmpty ? nil : trimmed)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func createSelection() async {
    guard isCreating == false else { return }
    guard let search else { return }
    guard let createManifestationFromSearch else { return }
    isCreating = true
    errorMessage = nil
    defer { isCreating = false }
    do {
      let label = editionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      let note = editionNote.trimmingCharacters(in: .whitespacesAndNewlines)
      _ = try await createManifestationFromSearch(
        PodibleManifestationSearchSelection(
          mediaType: media,
          searchId: search.searchId,
          indexes: selectedIndexes,
          label: label.isEmpty ? nil : label,
          editionNote: note.isEmpty ? nil : note
        ))
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct ReleaseSearchResultRow: View {
  let result: PodibleReleaseSearchResult
  let selectedOrder: Int?

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      selectionIndicator
      VStack(alignment: .leading, spacing: 4) {
        Text(result.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
        Text(metadata)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var selectionIndicator: some View {
    if let selectedOrder {
      Text("\(selectedOrder)")
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(Color.accentColor, in: Circle())
    } else {
      Image(systemName: "circle")
        .font(.title3)
        .foregroundStyle(.tertiary)
        .frame(width: 24, height: 24)
    }
  }

  private var metadata: String {
    var parts = [result.provider, result.mediaType.title]
    if let seeders = result.seeders {
      parts.append("\(seeders) seeders")
    }
    if let sizeBytes = result.sizeBytes, sizeBytes > 0 {
      parts.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
    }
    return parts.joined(separator: " • ")
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

  private static let coverWidth: CGFloat = 132
  private static let coverHeight: CGFloat = 192
  private static let coverSpacing: CGFloat = 16

  private var columns: [GridItem] {
    [
      GridItem(
        .adaptive(minimum: Self.coverWidth, maximum: Self.coverWidth),
        spacing: Self.coverSpacing
      )
    ]
  }

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
        LazyVGrid(columns: columns, spacing: Self.coverSpacing) {
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
      bookCoverPlaceholder(
        title: title,
        author: author,
        width: Self.coverWidth,
        height: Self.coverHeight,
        cornerRadius: 10
      )
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
    .frame(width: Self.coverWidth, height: Self.coverHeight)
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
