import Foundation
import Kingfisher
import SwiftUI

struct LazyLibrarianView: View {
  @EnvironmentObject var userSettings: UserSettings
  @StateObject private var viewModel = LazyLibrarianViewModel()
  @State private var isShowingShareSheet = false
  @State private var shareURL: URL?
  @State private var isShowingKindleExporter = false
  @State private var kindleExportFile: BookFile?
  @State private var isKindleExported = false
  @State private var downloadErrorMessage: String?
  @State private var downloadingBookID: String?
  @State private var downloadProgress: Double?
  @State private var downloadKind: DownloadKind?
  @State private var pendingSearchItemIDs: Set<String> = []
  @State private var searchTask: Task<Void, Never>?

  let clientOverride: LazyLibrarianServing?

  init(client: LazyLibrarianServing? = nil) {
    self.clientOverride = client
  }

  private enum DownloadKind {
    case ebook
    case audiobook
  }

  private var configuredClient: LazyLibrarianServing? {
    if let clientOverride {
      return clientOverride
    }
    guard
      let url = URL(string: userSettings.lazyLibrarianURL),
      userSettings.lazyLibrarianURL.isEmpty == false,
      userSettings.lazyLibrarianAPIKey.isEmpty == false
    else {
      return nil
    }
    return LazyLibrarianClient(
      baseURL: url,
      apiKey: userSettings.lazyLibrarianAPIKey
    )
  }

  var body: some View {
    if let client = configuredClient {
      content(client: client)
    } else {
      ContentUnavailableView {
        Label("LazyLibrarian", systemImage: "books.vertical")
      } description: {
        Text(
          "Add your LazyLibrarian URL and API key in Settings to request books and see request status."
        )
      }
      .navigationTitle("Library")
    }
  }

  @ViewBuilder
  private func content(client: LazyLibrarianServing) -> some View {
    List {
      if let error = viewModel.errorMessage {
        Text(error)
          .foregroundStyle(.red)
          .font(.caption)
      }

      if let downloadError = downloadErrorMessage {
        Text(downloadError)
          .foregroundStyle(.red)
          .font(.caption)
      }

      if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if viewModel.libraryItems.isEmpty {
          Text("No books yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(viewModel.libraryItems) { item in
            libraryRow(item, client: client)
          }
        }
      } else {
        let filteredLibrary = viewModel.filteredLibraryItems(query: viewModel.query)
        let libraryByID = Dictionary(uniqueKeysWithValues: filteredLibrary.map { ($0.id, $0) })
        let remoteResults = viewModel.searchResults
        let matchedIDs = Set(remoteResults.map(\.id)).intersection(libraryByID.keys)
        let remainingLibrary = filteredLibrary.filter { matchedIDs.contains($0.id) == false }

        if remoteResults.isEmpty && remainingLibrary.isEmpty {
          ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass"
          )
        } else {
          ForEach(remoteResults) { book in
            if let item = libraryByID[book.id] {
              libraryRow(item, client: client)
            } else {
              LazyLibrarianSearchResultRow(
                viewModel: viewModel,
                book: book,
                client: client,
                pendingItemIDs: $pendingSearchItemIDs
              )
            }
          }
          ForEach(remainingLibrary) { item in
            libraryRow(item, client: client)
          }
        }
      }
    }
    #if os(iOS)
      .listStyle(.grouped)
    #endif
    .navigationTitle("Library")
    .toolbar {
      ToolbarItem {
        NavigationLink(destination: LocalLibraryView(client: client)) {
          Image(systemName: "tray.full")
        }
        .help("Local Library")
      }
    }
    .onAppear {
      Task {
        await viewModel.loadLibraryItems(using: client)
      }
    }
    .refreshable {
      await viewModel.loadLibraryItems(using: client)
    }
    .searchable(text: $viewModel.query, prompt: "Search")
    .onSubmit(of: .search) {
      Task {
        await viewModel.search(using: client)
      }
    }
    .onChange(of: viewModel.query) { _, newValue in
      searchTask?.cancel()
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        viewModel.searchResults = []
        pendingSearchItemIDs.removeAll()
        return
      }
      searchTask = Task {
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard Task.isCancelled == false else { return }
        await viewModel.search(using: client, query: trimmed)
      }
    }
    #if os(iOS)
      .sheet(isPresented: $isShowingShareSheet) {
        if let shareURL {
          ActivityShareSheet(items: [shareURL])
        }
      }
    #else
      .background(
        ShareSheetPresenter(
          isPresented: $isShowingShareSheet,
          items: shareURL.map { [$0] } ?? []
        )
      )
    #endif
    .exporter(
      downloadedFile: kindleExportFile,
      kindleEmailAddress: userSettings.kindleEmailAddress,
      isExportModalOpen: $isShowingKindleExporter,
      isExported: $isKindleExported
    )
  }

  private func startEbookDownload(
    bookID: String,
    title: String,
    client: LazyLibrarianServing
  ) async {
    if let cachedURL = cachedEbookURL(title: title) {
      let filename = sanitizeFilename(title).appending(".\(cachedURL.pathExtension)")
      shareURL = makeShareableCopy(of: cachedURL, filename: filename) ?? cachedURL
      isShowingShareSheet = true
      return
    }
    downloadingBookID = bookID
    downloadKind = .ebook
    downloadProgress = 0
    downloadErrorMessage = nil
    do {
      let localURL = try await client.downloadEpub(bookID: bookID) { value in
        Task { @MainActor in
          downloadProgress = value
        }
      }
      let filename = sanitizeFilename(title).appending(".\(localURL.pathExtension)")
      shareURL = makeShareableCopy(of: localURL, filename: filename) ?? localURL
      isShowingShareSheet = true
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
    downloadingBookID = nil
    downloadKind = nil
    downloadProgress = nil
  }

  private func startKindleExport(
    bookID: String,
    title: String,
    client: LazyLibrarianServing
  ) async {
    if let cachedURL = cachedEbookURL(title: title) {
      let filename = sanitizeFilename(title).appending(".\(cachedURL.pathExtension)")
      do {
        let data = try Data(contentsOf: cachedURL)
        kindleExportFile = BookFile(filename: filename, data: data)
        isShowingKindleExporter = true
      } catch {
        downloadErrorMessage = error.localizedDescription
      }
      return
    }
    downloadingBookID = bookID
    downloadKind = .ebook
    downloadProgress = 0
    downloadErrorMessage = nil
    do {
      let localURL = try await client.downloadEpub(bookID: bookID) { value in
        Task { @MainActor in
          downloadProgress = value
        }
      }
      let filename = sanitizeFilename(title).appending(".\(localURL.pathExtension)")
      let data = try Data(contentsOf: localURL)
      kindleExportFile = BookFile(filename: filename, data: data)
      isShowingKindleExporter = true
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
    downloadingBookID = nil
    downloadKind = nil
    downloadProgress = nil
  }

  private func startAudiobookDownload(
    bookID: String,
    title: String,
    client: LazyLibrarianServing
  ) async {
    downloadingBookID = bookID
    downloadKind = .audiobook
    downloadProgress = 0
    downloadErrorMessage = nil
    do {
      let localURL = try await client.downloadAudiobook(bookID: bookID) { value in
        Task { @MainActor in
          downloadProgress = value
        }
      }
      let filename = localURL.lastPathComponent
      shareURL = makeShareableCopy(of: localURL, filename: filename) ?? localURL
      isShowingShareSheet = true
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
    downloadingBookID = nil
    downloadKind = nil
    downloadProgress = nil
  }

  private func sanitizeFilename(_ value: String) -> String {
    let sanitized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "[\\\\/:*?\"<>|]", with: "-", options: .regularExpression)
    return sanitized.isEmpty ? "untitled" : sanitized
  }

  private func makeShareableCopy(of url: URL, filename: String) -> URL? {
    guard url.lastPathComponent != filename else { return url }
    let destination = url.deletingLastPathComponent().appendingPathComponent(filename)
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: url, to: destination)
      return destination
    } catch {
      return nil
    }
  }

  private func cachedEbookURL(title: String) -> URL? {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("lazy-librarian", isDirectory: true)
    let prefix = sanitizeFilename(title).appending(".")
    guard
      let contents = try? fm.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }
    let matches = contents.filter { $0.lastPathComponent.hasPrefix(prefix) }
    guard matches.isEmpty == false else { return nil }
    return matches.max { lhs, rhs in
      let lhsDate =
        (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      let rhsDate =
        (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return lhsDate < rhsDate
    }
  }

  private func libraryRow(
    _ item: LazyLibrarianLibraryItem,
    client: LazyLibrarianServing
  ) -> some View {
    let progress = viewModel.progressForBookID(item.id)
    let isDownloadingThisBook = downloadingBookID == item.id

    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        bookCoverView(
          title: item.title,
          author: item.author,
          url: lazyLibrarianAssetURL(
            baseURLString: userSettings.lazyLibrarianURL,
            path: item.bookImagePath
          )
        )
        VStack(alignment: .leading, spacing: 6) {
          Text(item.title)
            .font(.headline)
            .lineLimit(2)
          Text(item.author)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          rowControls(
            item: item,
            client: client,
            isDownloadingThisBook: isDownloadingThisBook
          )
        }
        Spacer(minLength: 0)
        lazyLibrarianStatusCluster(
          item: item,
          progress: progress,
          shouldOfferSearch: { status in
            viewModel.shouldOfferSearch(status: status)
          }
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func rowControls(
    item: LazyLibrarianLibraryItem,
    client: LazyLibrarianServing,
    isDownloadingThisBook: Bool
  ) -> some View {
    let canEbookSearch = viewModel.shouldOfferSearch(status: item.status)
    let canAudioSearch = viewModel.shouldOfferSearch(status: item.audioStatus)
    let canTriggerEbookSearch =
      canEbookSearch
      && viewModel.canTriggerSearch(bookID: item.id, library: .ebook)
    let canTriggerAudioSearch =
      canAudioSearch
      && viewModel.canTriggerSearch(bookID: item.id, library: .audio)
    let canDownload = isDownloadingThisBook == false
    let canExport = item.status == .open && canDownload
    let canAudioExport = item.audioStatus == .open && canDownload
    let canKindleExport =
      canExport && userSettings.kindleEmailAddress.isEmpty == false

    let canRefresh = canEbookSearch || canAudioSearch
    let canTriggerRefresh = canTriggerEbookSearch || canTriggerAudioSearch
    let controls = HStack(spacing: 8) {
      trailingControlButton(
        label: "Download & Export",
        systemName: "square.and.arrow.up",
        isEnabled: canExport,
        action: {
          Task {
            await startEbookDownload(
              bookID: item.id,
              title: item.title,
              client: client
            )
          }
        }
      )
      if item.audioStatus == .open {
        trailingControlButton(
          label: "Download Audiobook",
          systemName: "waveform",
          isEnabled: canAudioExport,
          action: {
            Task {
              await startAudiobookDownload(
                bookID: item.id,
                title: item.title,
                client: client
              )
            }
          }
        )
      }
      trailingControlButton(
        label: "Email to Kindle",
        systemName: "paperplane",
        isEnabled: canKindleExport,
        action: {
          Task {
            await startKindleExport(
              bookID: item.id,
              title: item.title,
              client: client
            )
          }
        }
      )
      if isDownloadingThisBook, let progress = downloadProgress, let kind = downloadKind {
        lazyLibrarianProgressCircle(
          value: Int(progress * 100),
          tint: .secondary,
          icon: kind == .ebook ? "book" : "waveform.mid",
          snoring: false
        )
      }
      if canRefresh {
        trailingControlButton(
          label: "Refresh",
          systemName: "arrow.clockwise",
          isEnabled: canTriggerRefresh,
          action: {
            Task {
              if canTriggerEbookSearch {
                await viewModel.triggerSearch(
                  bookID: item.id,
                  library: .ebook,
                  using: client
                )
              }
              if canTriggerAudioSearch {
                await viewModel.triggerSearch(
                  bookID: item.id,
                  library: .audio,
                  using: client
                )
              }
            }
          }
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: 44)
    controls
  }

  private func trailingControlButton(
    label: String,
    systemName: String,
    isEnabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.title3.weight(.medium))
        .foregroundStyle(.accent)
        .imageScale(.large)
        .frame(width: 44, height: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .disabled(!isEnabled)
    .accessibilityLabel(label)
  }

  private func trailingControlButton(
    label: String,
    isEnabled: Bool = true,
    @ViewBuilder content: () -> some View,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      content()
        .foregroundStyle(.accent)
        .frame(width: 44, height: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .disabled(!isEnabled)
    .accessibilityLabel(label)
  }

  private func searchActionIcon(base: String) -> some View {
    ZStack {
      Image(systemName: base)
        .font(.title3.weight(.medium))
      Image(systemName: "magnifyingglass")
        .font(.system(size: 9, weight: .bold))
        .offset(x: 10, y: 10)
    }
  }
}

@ViewBuilder
func lazyLibrarianEbookStatusRow(
  status: LazyLibrarianLibraryItemStatus?,
  progressValue: Int?,
  progressFinished: Bool,
  progressSeen: Bool,
  shouldOfferSearch: Bool
) -> some View {
  let isComplete = status?.isComplete ?? false
  Group {
    if isComplete == false {
      if progressSeen {
        lazyLibrarianProgressCircle(
          value: progressValue ?? 0,
          tint: progressFinished ? .green : .blue,
          icon: "book",
          snoring: false
        )
      } else {
        lazyLibrarianProgressCircle(
          value: 0,
          tint: .blue,
          icon: "book",
          snoring: true
        )
        .opacity(shouldOfferSearch ? 1 : 0)
      }
    }
  }
  .transition(.opacity)
  .animation(.easeInOut(duration: 0.2), value: isComplete)
}

@ViewBuilder
func lazyLibrarianAudioStatusRow(
  status: LazyLibrarianLibraryItemStatus?,
  progressValue: Int?,
  progressFinished: Bool,
  progressSeen: Bool,
  shouldOfferSearch: Bool
) -> some View {
  let isComplete = status?.isComplete ?? false
  Group {
    if isComplete == false {
      if progressSeen {
        lazyLibrarianProgressCircle(
          value: progressValue ?? 0,
          tint: progressFinished ? .green : .blue,
          icon: "waveform.mid",
          snoring: false
        )
      } else {
        lazyLibrarianProgressCircle(
          value: 0,
          tint: .blue,
          icon: "waveform.mid",
          snoring: true
        )
        .opacity(shouldOfferSearch ? 1 : 0)
      }
    }
  }
  .transition(.opacity)
  .animation(.easeInOut(duration: 0.2), value: isComplete)
}

@ViewBuilder
func lazyLibrarianProgressCircles(
  progress: LazyLibrarianViewModel.DownloadProgress
) -> some View {
  VStack(alignment: .trailing, spacing: 6) {
    HStack(spacing: 6) {
      lazyLibrarianProgressCircle(
        value: progress.ebook,
        tint: progress.ebookFinished ? .green : .blue,
        icon: "book",
        snoring: false
      )
    }
    HStack(spacing: 6) {
      lazyLibrarianProgressCircle(
        value: progress.audiobook,
        tint: progress.audiobookFinished ? .green : .blue,
        icon: "waveform.mid",
        snoring: false
      )
    }
  }
}

@ViewBuilder
func lazyLibrarianStatusCluster(
  item: LazyLibrarianLibraryItem,
  progress: LazyLibrarianViewModel.DownloadProgress?,
  shouldOfferSearch: (LazyLibrarianLibraryItemStatus?) -> Bool
) -> some View {
  let showEbook = item.status.isComplete == false
  let showAudio = item.audioStatus?.isComplete == false
  HStack(spacing: 10) {
    if showEbook {
      lazyLibrarianEbookStatusRow(
        status: item.status,
        progressValue: progress?.ebook,
        progressFinished: progress?.ebookFinished ?? false,
        progressSeen: progress?.ebookSeen ?? false,
        shouldOfferSearch: shouldOfferSearch(item.status)
      )
    }
    if showAudio {
      lazyLibrarianAudioStatusRow(
        status: item.audioStatus,
        progressValue: progress?.audiobook,
        progressFinished: progress?.audiobookFinished ?? false,
        progressSeen: progress?.audiobookSeen ?? false,
        shouldOfferSearch: shouldOfferSearch(item.audioStatus)
      )
    }
  }
}

@ViewBuilder
func lazyLibrarianProgressCircle(
  value: Int,
  tint: Color,
  icon: String?,
  snoring: Bool
) -> some View {
  let clamped = max(0, min(100, value))
  let progress = Double(clamped) / 100.0
  let base = ZStack {
    Circle()
      .stroke(.tertiary, lineWidth: 1.5)
    Circle()
      .trim(from: 0, to: progress)
      .stroke(
        .secondary,
        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
      )
      .rotationEffect(.degrees(-90))
      .animation(.easeInOut(duration: 0.25), value: clamped)
    if let icon {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.secondary)
    }
  }
  .frame(width: 22, height: 22)

  if snoring {
    TimelineView(.animation) { context in
      let phase = context.date.timeIntervalSinceReferenceDate * 2.0
      let opacity = 0.35 + 0.65 * (sin(phase) + 1.0) / 2.0
      base.opacity(opacity)
    }
  } else {
    base
  }
}

@MainActor
@ViewBuilder
func bookCoverView(title: String, author: String, url: URL?) -> some View {
  if let url {
    KFImage(url)
      .placeholder {
        bookCoverPlaceholder(title: title, author: author)
      }
      .resizable()
      .scaledToFill()
      .frame(width: 88, height: 128)
      .clipShape(RoundedRectangle(cornerRadius: 6))
  } else {
    bookCoverPlaceholder(title: title, author: author)
  }
}

func bookCoverPlaceholder(title: String, author: String) -> some View {
  RoundedRectangle(cornerRadius: 6)
    .fill(coverPlaceholderColor(title: title, author: author))
    .frame(width: 88, height: 128)
    .overlay(
      VStack(spacing: 6) {
        Text(title)
          .font(.caption.weight(.semibold))
          .multilineTextAlignment(.center)
          .lineLimit(3)
        Text(author)
          .font(.caption2)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
      .padding(8)
      .foregroundStyle(.white.opacity(0.9))
    )
}

func coverPlaceholderColor(title: String, author: String) -> Color {
  let palette: [Color] = [
    Color(red: 0.36, green: 0.25, blue: 0.20),
    Color(red: 0.16, green: 0.33, blue: 0.52),
    Color(red: 0.46, green: 0.22, blue: 0.28),
    Color(red: 0.18, green: 0.43, blue: 0.36),
    Color(red: 0.42, green: 0.36, blue: 0.18),
    Color(red: 0.28, green: 0.28, blue: 0.48),
  ]
  var hash = 5381
  for scalar in (title + "|" + author).unicodeScalars {
    hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
  }
  let index = abs(hash) % palette.count
  return palette[index]
}

func lazyLibrarianAssetURL(baseURLString: String, path: String?) -> URL? {
  guard let path, let baseURL = URL(string: baseURLString) else { return nil }
  let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.lowercased().hasSuffix("nocover.png") {
    return nil
  }
  var base = baseURL
  if base.path.hasSuffix("/api") {
    base.deleteLastPathComponent()
  }
  if base.path.hasSuffix("/") == false {
    base.appendPathComponent("")
  }
  guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
    return nil
  }
  return url
}

struct ActivityShareSheet: View {
  let items: [Any]

  var body: some View {
    ActivityShareSheetController(items: items)
  }
}

#if os(iOS)
  struct ActivityShareSheetController: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
      UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
  }
#else
  struct ActivityShareSheetController: NSViewRepresentable {
    let items: [Any]

    func makeNSView(context: Context) -> NSView {
      NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
    }
  }

  struct ShareSheetPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let items: [Any]

    func makeNSView(context: Context) -> NSView {
      NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
      guard isPresented, items.isEmpty == false else { return }
      DispatchQueue.main.async {
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
        isPresented = false
      }
    }
  }
#endif

#Preview {
  NavigationStack {
    LazyLibrarianView(client: LazyLibrarianMockClient())
      .environmentObject(UserSettings())
  }
}
