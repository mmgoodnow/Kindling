import Foundation

@MainActor
final class LazyLibrarianViewModel: ObservableObject {
  struct DownloadProgress: Hashable {
    var ebook: Int
    var audiobook: Int
    var ebookFinished: Bool
    var audiobookFinished: Bool
    var ebookSeen: Bool
    var audiobookSeen: Bool
    var updatedAt: Date
  }

  @Published var query: String = ""
  @Published var searchResults: [PodibleBook] = []
  @Published var libraryItems: [PodibleLibraryItem] = []
  @Published var isLoading: Bool = false
  @Published var errorMessage: String?
  @Published var downloadProgressByBookID: [String: DownloadProgress] = [:]
  @Published private var pendingItemsByID: [String: PodibleLibraryItem] = [:]

  private var downloadPollingTasks: [String: Task<Void, Never>] = [:]
  private let downloadPollIntervalNanoseconds: UInt64 = 500_000_000
  private let searchCooldownInterval: TimeInterval = 20
  private var lastSearchByKey: [SearchCooldownKey: Date] = [:]
  private var searchResultsByQuery: [String: [PodibleBook]] = [:]

  private struct SearchCooldownKey: Hashable {
    let bookID: String
    let library: PodibleLibraryMedia
  }

  deinit {
    for task in downloadPollingTasks.values {
      task.cancel()
    }
  }

  func loadLibraryItems(using client: PodibleLibraryServing) async {
    isLoading = true
    errorMessage = nil
    do {
      let all = try await client.fetchLibraryItems()
      let filteredAll = filtered(all)
      prunePendingItems(matching: filteredAll)
      let filteredItems = mergePending(into: filteredAll)
      libraryItems = filteredItems
      startPollingIfNeeded(for: filteredItems, client: client)
    } catch {
      if shouldIgnoreError(error) == false {
        errorMessage = error.localizedDescription
      }
    }
    isLoading = false
  }

  func search(using client: PodibleLibraryServing) async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    await search(using: client, query: trimmed)
  }

  func search(using client: PodibleLibraryServing, query: String) async {
    guard query.isEmpty == false else { return }
    if let cached = searchResultsByQuery[query] {
      searchResults = cached
      return
    }
    isLoading = true
    errorMessage = nil
    do {
      let results = try await client.searchBooks(query: query)
      searchResultsByQuery[query] = results
      if self.query.trimmingCharacters(in: .whitespacesAndNewlines) == query {
        searchResults = results
      }
    } catch {
      if shouldIgnoreError(error) == false {
        errorMessage = error.localizedDescription
      }
    }
    isLoading = false
  }

  func filteredLibraryItems(query: String) -> [PodibleLibraryItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return libraryItems }
    let needle = trimmed.lowercased()
    return libraryItems.filter { item in
      item.title.lowercased().contains(needle)
        || item.author.lowercased().contains(needle)
    }
  }

  func request(_ book: PodibleBook, using client: PodibleLibraryServing) async {
    isLoading = true
    errorMessage = nil
    do {
      let originalBookID = book.id
      addPendingRequestIfNeeded(for: book)
      let requested = try await client.addLibraryBook(
        openLibraryKey: book.id,
        titleHint: book.title,
        authorHint: book.author
      )
      if requested.id != originalBookID {
        if let pending = pendingItemsByID.removeValue(forKey: originalBookID) {
          pendingItemsByID[requested.id] = pending
        }
        libraryItems.removeAll { $0.id == originalBookID }
      }
      if let pending = pendingItemsByID[requested.id] {
        if requested.bookImagePath != nil {
          pendingItemsByID[requested.id] = requested
        } else {
          pendingItemsByID[requested.id] = pending
        }
      }
      // Update the library list and the search results with the new status.
      if let existingIndex = libraryItems.firstIndex(where: { $0.id == requested.id }) {
        let existing = libraryItems[existingIndex]
        let updated = PodibleLibraryItem(
          id: requested.id,
          title: requested.title,
          author: requested.author,
          status: requested.status,
          audioStatus: requested.audioStatus,
          bookAdded: requested.bookAdded ?? existing.bookAdded,
          bookLibrary: requested.bookLibrary ?? existing.bookLibrary,
          audioLibrary: requested.audioLibrary ?? existing.audioLibrary,
          bookImagePath: requested.bookImagePath ?? existing.bookImagePath
        )
        libraryItems[existingIndex] = updated
      } else {
        libraryItems.append(requested)
      }
      if let searchIndex = searchResults.firstIndex(where: {
        $0.id == originalBookID || $0.id == requested.id
      }) {
        let updated = PodibleBook(
          id: requested.id,
          title: requested.title,
          author: requested.author,
          status: requested.status,
          audioStatus: requested.audioStatus,
          coverImageURL: searchResults[searchIndex].coverImageURL
        )
        searchResults[searchIndex] = updated
      }
      libraryItems = filtered(libraryItems)
      libraryItems = mergePending(into: libraryItems)
      startPolling(bookID: requested.id, client: client)
    } catch {
      if shouldIgnoreError(error) == false {
        self.errorMessage = error.localizedDescription
        print("[LibraryBackend] request error for \(book.id): \(error.localizedDescription)")
      }
    }
    isLoading = false
  }

  func forceSearch(_ book: PodibleBook, using client: PodibleLibraryServing) async {
    isLoading = true
    errorMessage = nil
    do {
      try await client.acquireLibraryMedia(bookID: book.id, library: .ebook)
      try await client.acquireLibraryMedia(bookID: book.id, library: .audio)
      markSearchTriggered(bookID: book.id, library: .ebook)
      markSearchTriggered(bookID: book.id, library: .audio)
    } catch {
      if shouldIgnoreError(error) == false {
        self.errorMessage = error.localizedDescription
      }
    }
    isLoading = false
  }

  func triggerSearch(
    bookID: String, library: PodibleLibraryMedia, using client: PodibleLibraryServing
  ) async {
    await triggerAcquire(bookID: bookID, library: library, using: client)
  }

  func triggerAcquire(
    bookID: String, library: PodibleLibraryMedia, using client: PodibleLibraryServing
  ) async {
    guard canTriggerSearch(bookID: bookID, library: library) else { return }
    do {
      try await client.acquireLibraryMedia(bookID: bookID, library: library)
      markSearchTriggered(bookID: bookID, library: library)
    } catch {
      if shouldIgnoreError(error) == false {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func filtered(_ items: [PodibleLibraryItem]) -> [PodibleLibraryItem] {
    func isSkippedOrIgnored(_ status: PodibleLibraryItemStatus?) -> Bool {
      guard let status else { return true }
      return status == .skipped || status == .ignored
    }
    let filtered = items.filter { item in
      !(isSkippedOrIgnored(item.status) && isSkippedOrIgnored(item.audioStatus))
    }
    return filtered.sorted { lhs, rhs in
      switch (lhs.bookAdded, rhs.bookAdded) {
      case let (l?, r?):
        if l != r { return l > r }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      case (nil, nil):
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
    }
  }

  func beginOptimisticRequest(for book: PodibleBook) {
    addPendingRequestIfNeeded(for: book)
  }

  private func addPendingRequestIfNeeded(for book: PodibleBook) {
    guard pendingItemsByID[book.id] == nil else { return }
    if libraryItems.contains(where: { $0.id == book.id }) { return }
    let coverPath = book.coverImageURL?.absoluteString ?? book.coverURL?.absoluteString
    let placeholder = PodibleLibraryItem(
      id: book.id,
      title: book.title,
      author: book.author,
      status: .requested,
      audioStatus: .requested,
      bookAdded: .now,
      bookImagePath: coverPath
    )
    pendingItemsByID[book.id] = placeholder
    libraryItems.append(placeholder)
    libraryItems = filtered(libraryItems)
  }

  private func mergePending(into items: [PodibleLibraryItem]) -> [PodibleLibraryItem] {
    guard pendingItemsByID.isEmpty == false else { return items }
    var merged = items
    for (id, pending) in pendingItemsByID {
      guard merged.contains(where: { $0.id == id }) == false else {
        continue
      }
      merged.append(pending)
    }
    return filtered(merged)
  }

  private func prunePendingItems(matching items: [PodibleLibraryItem]) {
    guard pendingItemsByID.isEmpty == false else { return }
    let existingIDs = Set(items.map(\.id))
    for id in existingIDs {
      pendingItemsByID[id] = nil
    }
  }

  private func refreshLibrarySilently(using client: PodibleLibraryServing) async {
    do {
      let all = try await client.fetchLibraryItems()
      let filteredAll = filtered(all)
      prunePendingItems(matching: filteredAll)
      libraryItems = mergePending(into: filteredAll)
    } catch {
      // Ignore transient errors; this is a silent refresh during polling.
    }
  }

  func shouldShowDownloadProgress(
    status: PodibleLibraryItemStatus, audioStatus: PodibleLibraryItemStatus?
  ) -> Bool {
    isActive(status) || isActive(audioStatus)
  }

  func progressForBookID(_ id: String) -> DownloadProgress? {
    downloadProgressByBookID[id]
  }

  func shouldOfferSearch(status: PodibleLibraryItemStatus?) -> Bool {
    isActive(status)
  }

  func canTriggerSearch(bookID: String, library: PodibleLibraryMedia) -> Bool {
    let key = SearchCooldownKey(bookID: bookID, library: library)
    if let last = lastSearchByKey[key] {
      return Date.now.timeIntervalSince(last) >= searchCooldownInterval
    }
    return true
  }

  func noteSearchTriggered(bookID: String, library: PodibleLibraryMedia) {
    markSearchTriggered(bookID: bookID, library: library)
  }

  private func markSearchTriggered(bookID: String, library: PodibleLibraryMedia) {
    lastSearchByKey[SearchCooldownKey(bookID: bookID, library: library)] = .now
  }

  private func startPollingIfNeeded(
    for items: [PodibleLibraryItem], client: PodibleLibraryServing
  ) {
    for item in items
    where shouldShowDownloadProgress(status: item.status, audioStatus: item.audioStatus) {
      startPolling(bookID: item.id, client: client)
    }
  }

  private func startPolling(bookID: String, client: PodibleLibraryServing) {
    if let existing = downloadPollingTasks[bookID] {
      existing.cancel()
      downloadPollingTasks[bookID] = nil
    }

    if downloadProgressByBookID[bookID] == nil {
      downloadProgressByBookID[bookID] = DownloadProgress(
        ebook: 0,
        audiobook: 0,
        ebookFinished: false,
        audiobookFinished: false,
        ebookSeen: false,
        audiobookSeen: false,
        updatedAt: .now
      )
    }

    downloadPollingTasks[bookID] = Task { [weak self] in
      guard let self else { return }
      let deadline = Date.now.addingTimeInterval(15 * 60)
      var lastStatusRefresh = Date.distantPast
      let statusRefreshInterval: TimeInterval = 3.0
      while Task.isCancelled == false, Date.now < deadline {
        do {
          let active = try await client.fetchDownloadProgress(limit: 50)
          self.mergeProgress(active, forBookID: bookID)
          // If both tracks are finished, do a final status refresh and continue polling statuses briefly until they settle.
          if let current = self.downloadProgressByBookID[bookID], current.ebookFinished,
            current.audiobookFinished
          {
            await self.refreshLibrarySilently(using: client)
            // Continue polling request statuses a bit longer until they settle to non-active, or timeout.
            let settleDeadline = deadline
            while Task.isCancelled == false, Date.now < settleDeadline {
              if let item = self.libraryItems.first(where: { $0.id == bookID }) {
                if self.shouldShowDownloadProgress(
                  status: item.status, audioStatus: item.audioStatus) == false
                {
                  break
                }
              }
              try? await Task.sleep(nanoseconds: self.downloadPollIntervalNanoseconds * 4)
              await self.refreshLibrarySilently(using: client)
            }
            // Clear progress so UI hides bars once statuses settle.
            self.downloadProgressByBookID[bookID] = nil
            break
          }
          // Periodically refresh request statuses to reflect transitions (e.g., Snatched -> Downloaded)
          if Date.now.timeIntervalSince(lastStatusRefresh) >= statusRefreshInterval {
            await self.refreshLibrarySilently(using: client)
            lastStatusRefresh = .now
          }
        } catch {
          // Keep polling; transient failures are expected while downloads are being created.
        }

        try? await Task.sleep(nanoseconds: self.downloadPollIntervalNanoseconds)
      }
      self.downloadPollingTasks[bookID] = nil
    }
  }

  private func mergeProgress(_ items: [PodibleDownloadProgressItem], forBookID bookID: String) {
    var current =
      downloadProgressByBookID[bookID]
      ?? DownloadProgress(
        ebook: 0,
        audiobook: 0,
        ebookFinished: false,
        audiobookFinished: false,
        ebookSeen: false,
        audiobookSeen: false,
        updatedAt: .now
      )

    for item in items where item.bookID == bookID {
      let library = item.auxInfo
      let value = max(0, min(100, item.progress ?? 0))
      let finished = item.finished ?? (value >= 100)
      if library == PodibleLibraryMedia.ebook.rawValue {
        current.ebook = value
        current.ebookFinished = finished
        current.ebookSeen = true
      } else if library == PodibleLibraryMedia.audio.rawValue {
        current.audiobook = value
        current.audiobookFinished = finished
        current.audiobookSeen = true
      }
    }
    current.updatedAt = .now
    downloadProgressByBookID[bookID] = current
  }

  private func isActive(_ status: PodibleLibraryItemStatus?) -> Bool {
    guard let status else { return false }
    switch status {
    case .requested, .wanted, .snatched, .seeding:
      return true
    case .downloaded, .failed, .have, .skipped, .open, .processed, .ignored, .okay, .unknown:
      return false
    }
  }

  private func shouldIgnoreError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled {
      return true
    }
    return false
  }
}

typealias RemoteLibraryViewModel = LazyLibrarianViewModel
typealias PodibleLibraryViewModel = LazyLibrarianViewModel
typealias PodibleLibraryDownloadProgress = LazyLibrarianViewModel.DownloadProgress
