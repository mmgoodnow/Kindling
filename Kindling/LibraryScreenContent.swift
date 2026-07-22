import KindlingUI
import SwiftUI

struct LibraryHomeRailViewData: Identifiable {
  let collection: LibraryCollection
  let books: [BookTileViewData]
  let emptyMessage: String

  var id: LibraryCollection { collection }
}

struct LibraryHomeScreenContent<Status: View>: View {
  let rails: [LibraryHomeRailViewData]
  let artwork: (BookTileViewData, CGFloat) -> AnyView
  let onSelect: (BookTileViewData) -> Void
  let onToggleRead: (BookTileViewData) -> Void
  let onToggleFavorite: (BookTileViewData) -> Void
  let onSeeAll: (LibraryCollection) -> Void
  let status: Status

  init(
    rails: [LibraryHomeRailViewData],
    artwork: @escaping (BookTileViewData, CGFloat) -> AnyView,
    onSelect: @escaping (BookTileViewData) -> Void,
    onToggleRead: @escaping (BookTileViewData) -> Void,
    onToggleFavorite: @escaping (BookTileViewData) -> Void,
    onSeeAll: @escaping (LibraryCollection) -> Void,
    @ViewBuilder status: () -> Status
  ) {
    self.rails = rails
    self.artwork = artwork
    self.onSelect = onSelect
    self.onToggleRead = onToggleRead
    self.onToggleFavorite = onToggleFavorite
    self.onSeeAll = onSeeAll
    self.status = status()
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 28) {
        status
        ForEach(rails) { rail in
          BookRailView(
            title: rail.collection.title,
            books: rail.books,
            emptyMessage: rail.emptyMessage,
            artwork: artwork,
            onSelect: onSelect,
            onToggleRead: onToggleRead,
            onToggleFavorite: onToggleFavorite,
            onSeeAll: { onSeeAll(rail.collection) }
          )
        }
      }
      .padding(.top, 12)
      .padding(.bottom, 20)
    }
  }
}

struct LibraryCollectionScreenContent<Status: View, Controls: View, EmptyState: View>: View {
  let books: [BookTileViewData]
  let layout: BookCollectionLayout
  let filter: BookCollectionFilter
  let contentTopPadding: CGFloat
  let artwork: (BookTileViewData, CGFloat) -> AnyView
  let onSelect: (BookTileViewData) -> Void
  let onToggleRead: (BookTileViewData) -> Void
  let onToggleFavorite: (BookTileViewData) -> Void
  let onScrolledPastHeader: (Bool) -> Void
  let status: Status
  let controls: Controls
  let emptyState: EmptyState

  init(
    books: [BookTileViewData],
    layout: BookCollectionLayout,
    filter: BookCollectionFilter,
    contentTopPadding: CGFloat,
    artwork: @escaping (BookTileViewData, CGFloat) -> AnyView,
    onSelect: @escaping (BookTileViewData) -> Void,
    onToggleRead: @escaping (BookTileViewData) -> Void,
    onToggleFavorite: @escaping (BookTileViewData) -> Void,
    onScrolledPastHeader: @escaping (Bool) -> Void,
    @ViewBuilder status: () -> Status,
    @ViewBuilder controls: () -> Controls,
    @ViewBuilder emptyState: () -> EmptyState
  ) {
    self.books = books
    self.layout = layout
    self.filter = filter
    self.contentTopPadding = contentTopPadding
    self.artwork = artwork
    self.onSelect = onSelect
    self.onToggleRead = onToggleRead
    self.onToggleFavorite = onToggleFavorite
    self.onScrolledPastHeader = onScrolledPastHeader
    self.status = status()
    self.controls = controls()
    self.emptyState = emptyState()
  }

  var body: some View {
    Group {
      if books.isEmpty {
        VStack(spacing: 0) {
          status
          emptyState
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        populatedContent
      }
    }
  }

  @ViewBuilder
  private var populatedContent: some View {
    #if os(iOS)
      ZStack(alignment: .top) {
        bookCollection
        status
      }
    #else
      VStack(spacing: 0) {
        status
        controls
        bookCollection
      }
    #endif
  }

  private var bookCollection: some View {
    BookCollectionView(
      books: books,
      layout: layout,
      filter: filter,
      contentTopPadding: contentTopPadding,
      artwork: artwork,
      onSelect: onSelect,
      onToggleRead: onToggleRead,
      onToggleFavorite: onToggleFavorite,
      onScrolledPastHeader: onScrolledPastHeader
    )
  }
}
