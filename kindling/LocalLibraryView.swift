import SwiftData
import SwiftUI

struct LocalLibraryView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(
    sort: [
      SortDescriptor(\LibraryBook.addedAt, order: .reverse),
      SortDescriptor(\LibraryBook.title, order: .forward),
    ]
  )
  private var books: [LibraryBook]

  let client: LazyLibrarianServing

  @State private var isSyncing = false
  @State private var errorMessage: String?
  @State private var lastSync: Date?
  @State private var lastSummary: LibrarySyncService.Summary?

  var body: some View {
    List {
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.caption)
      }

      if let lastSync {
        HStack(spacing: 8) {
          Text("Last sync")
          Text(lastSync, style: .time)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
      }

      if let lastSummary {
        summaryRow(lastSummary)
      }

      if books.isEmpty {
        ContentUnavailableView(
          "No Local Books",
          systemImage: "tray",
          description: Text("Tap Sync to pull your LazyLibrarian library.")
        )
      } else {
        ForEach(books) { book in
          VStack(alignment: .leading, spacing: 4) {
            Text(book.title)
            Text(book.author?.name ?? "Unknown Author")
              .foregroundStyle(.secondary)
              .font(.caption)
          }
        }
      }
    }
    .navigationTitle("Local Library")
    .toolbar {
      ToolbarItem {
        Button(action: startSync) {
          if isSyncing {
            ProgressView()
          } else {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
        }
        .disabled(isSyncing)
        .help("Sync from LazyLibrarian")
      }
    }
    .onAppear {
      if books.isEmpty {
        startSync()
      }
    }
  }

  @ViewBuilder
  private func summaryRow(_ summary: LibrarySyncService.Summary) -> some View {
    let totalAdded = summary.insertedBooks + summary.insertedAuthors
    let totalUpdated = summary.updatedBooks + summary.updatedAuthors
    HStack(spacing: 8) {
      Text("Last sync result")
      Text("\(totalAdded) added, \(totalUpdated) updated")
        .foregroundStyle(.secondary)
    }
    .font(.caption)
  }

  private func startSync() {
    guard isSyncing == false else { return }
    isSyncing = true
    errorMessage = nil
    Task {
      do {
        let summary = try await LibrarySyncService().syncLibrary(
          using: client,
          modelContext: modelContext
        )
        lastSummary = summary
        lastSync = Date()
      } catch {
        errorMessage = error.localizedDescription
      }
      isSyncing = false
    }
  }
}

#if DEBUG
  #Preview {
    NavigationStack {
      LocalLibraryView(client: PreviewLazyLibrarianClient())
    }
    .modelContainer(
      for: [Author.self, Series.self, LibraryBook.self, LibraryBookFile.self, LocalBookState.self],
      inMemory: true
    )
  }

  private struct PreviewLazyLibrarianClient: LazyLibrarianServing {
    func searchBooks(query: String) async throws -> [LazyLibrarianBook] {
      []
    }

    func requestBook(id: String, titleHint: String?, authorHint: String?) async throws
      -> LazyLibrarianLibraryItem
    {
      throw LazyLibrarianError.notConfigured
    }

    func fetchLibraryItems() async throws -> [LazyLibrarianLibraryItem] {
      [
        LazyLibrarianLibraryItem(
          id: "demo-1",
          title: "The Left Hand of Darkness",
          author: "Ursula K. Le Guin",
          status: .downloaded,
          audioStatus: .downloaded,
          bookAdded: Date().addingTimeInterval(-86400),
          bookLibrary: Date().addingTimeInterval(-86400),
          audioLibrary: Date().addingTimeInterval(-86400),
          bookImagePath: nil
        ),
        LazyLibrarianLibraryItem(
          id: "demo-2",
          title: "Ancillary Justice",
          author: "Ann Leckie",
          status: .downloaded,
          audioStatus: .downloaded,
          bookAdded: Date().addingTimeInterval(-172800),
          bookLibrary: Date().addingTimeInterval(-172800),
          audioLibrary: Date().addingTimeInterval(-172800),
          bookImagePath: nil
        ),
      ]
    }

    func fetchBookCovers(wait: Bool) async throws {}

    func searchBook(id: String, library: LazyLibrarianLibrary) async throws {}

    func fetchDownloadProgress(limit: Int?) async throws -> [LazyLibrarianDownloadProgressItem] {
      []
    }

    func downloadEpub(bookID: String, progress: @escaping (Double) -> Void) async throws
      -> URL
    {
      throw LazyLibrarianError.notConfigured
    }

    func downloadAudiobook(bookID: String, progress: @escaping (Double) -> Void) async throws
      -> URL
    {
      throw LazyLibrarianError.notConfigured
    }
  }
#endif
