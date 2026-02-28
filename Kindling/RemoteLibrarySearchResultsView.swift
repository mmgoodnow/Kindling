import SwiftUI

struct PodibleSearchResultsView: View {
  @ObservedObject var viewModel: RemoteLibraryViewModel
  @EnvironmentObject var userSettings: UserSettings
  let client: RemoteLibraryServing
  @State private var pendingItemIDs: Set<String> = []

  var body: some View {
    List {
      if let error = viewModel.errorMessage {
        Text(error)
          .foregroundStyle(.red)
          .font(.caption)
      }

      if viewModel.searchResults.isEmpty {
        ContentUnavailableView(
          "No Results",
          systemImage: "magnifyingglass"
        )
      } else {
        ForEach(viewModel.searchResults) { book in
          PodibleSearchResultRow(
            viewModel: viewModel,
            book: book,
            client: client,
            pendingItemIDs: $pendingItemIDs
          )
        }
      }
    }
    .navigationTitle("Search")
  }
}

struct PodibleSearchResultRow: View {
  @ObservedObject var viewModel: RemoteLibraryViewModel
  @EnvironmentObject var userSettings: UserSettings
  let book: PodibleBook
  let client: RemoteLibraryServing
  @Binding var pendingItemIDs: Set<String>

  var body: some View {
    let isPending =
      pendingItemIDs.contains(book.id)
      && viewModel.progressForBookID(book.id) == nil
    let progress = viewModel.progressForBookID(book.id)
    let matchingItem = viewModel.libraryItems.first(where: { $0.id == book.id })
    let effectiveItem =
      matchingItem
      ?? (isPending
        ? PodibleLibraryItem(
          id: book.id,
          title: book.title,
          author: book.author,
          status: .requested,
          audioStatus: .requested,
          bookAdded: .now
        )
        : nil)
    let shouldShowGetButton = effectiveItem == nil

    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        let coverURL = book.coverImageURL.flatMap { url -> URL? in
          if url.scheme != nil { return url }
          return remoteLibraryAssetURL(
            baseURLString: userSettings.podibleRPCURL,
            path: url.absoluteString
          )
        }
        bookCoverView(
          title: book.title,
          author: book.author,
          url: coverURL
        )
        VStack(alignment: .leading, spacing: 6) {
          Text(book.title)
            .font(.headline)
            .lineLimit(2)
          Text(book.author)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if let item = effectiveItem {
            remoteLibraryStatusCluster(
              item: item
            )
          }
          Button {
            guard shouldShowGetButton else { return }
            pendingItemIDs.insert(book.id)
            viewModel.beginOptimisticRequest(for: book)
            Task {
              await viewModel.request(
                book,
                using: client
              )
              let updated = viewModel
                .searchResults
                .first(where: {
                  $0.id == book.id
                })
              let shouldWait =
                updated.map {
                  viewModel
                    .shouldShowDownloadProgress(
                      status: $0.status,
                      audioStatus: $0
                        .audioStatus
                    )
                } ?? false
              if shouldWait == false
                || viewModel.progressForBookID(
                  book.id
                ) != nil
              {
                pendingItemIDs.remove(
                  book.id
                )
              }
            }
          } label: {
            Text("GET")
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 10)
              .padding(.vertical, 2)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.accentColor)
          .clipShape(Capsule())
          .disabled(
            shouldShowGetButton == false
              || isPending
              || book.status == .requested
              || book.status == .wanted
          )
        }
      }
    }
    .onChange(of: viewModel.progressForBookID(book.id)?.updatedAt) { _, _ in
      pendingItemIDs.remove(book.id)
    }
  }
}

#Preview {
  let viewModel = RemoteLibraryViewModel()
  viewModel.searchResults = [
    PodibleBook(
      id: "1",
      title: "They Both Die at the End",
      author: "Adam Silvera",
      status: .requested,
      audioStatus: .requested,
      coverImageURL: URL(
        string:
          "https://i.gr-assets.com/images/S/compressed.photo.goodreads.com/books/1315601232l/11869272._SX98_.jpg"
      )
    ),
    PodibleBook(
      id: "2",
      title: "The Secret History",
      author: "Donna Tartt",
      status: .unknown
    ),
  ]
  viewModel.downloadProgressByBookID["1"] =
    PodibleLibraryDownloadProgress(
      ebook: 42,
      audiobook: 18,
      ebookFinished: false,
      audiobookFinished: false,
      ebookSeen: true,
      audiobookSeen: true,
      updatedAt: .now
    )

  return NavigationStack {
    PodibleSearchResultsView(
      viewModel: viewModel,
      client: PodibleMockClient()
    )
    .environmentObject(UserSettings())
  }
}
