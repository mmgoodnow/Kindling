import Foundation
import SwiftUI

public enum BookCollectionFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case unread
  case read

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .all:
      "All"
    case .unread:
      "Unread"
    case .read:
      "Read"
    }
  }

  public func includes(_ book: BookTileViewData) -> Bool {
    switch self {
    case .all:
      true
    case .unread:
      book.isInLibrary && book.isRead == false
    case .read:
      book.isInLibrary && book.isRead
    }
  }

  public func filtered(_ books: [BookTileViewData]) -> [BookTileViewData] {
    books.filter(includes)
  }
}

public enum BookCollectionLayout: String, CaseIterable, Identifiable, Sendable {
  case grid
  case list

  public var id: String { rawValue }
  public static var seriesDefault: Self { .list }

  public var title: String {
    switch self {
    case .grid:
      "Grid"
    case .list:
      "List"
    }
  }

  public var systemImage: String {
    switch self {
    case .grid:
      "square.grid.2x2"
    case .list:
      "list.bullet"
    }
  }
}

public struct ArtworkPalette: Hashable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double

  public init(red: Double, green: Double, blue: Double) {
    self.red = max(0, min(1, red))
    self.green = max(0, min(1, green))
    self.blue = max(0, min(1, blue))
  }

  public static let fallback = ArtworkPalette(red: 0.20, green: 0.47, blue: 0.86)

  public var background: Color {
    Color(red: red, green: green, blue: blue).opacity(0.16)
  }

  public var foreground: Color {
    Color(red: red * 0.64, green: green * 0.64, blue: blue * 0.64)
  }

  public var currentHighlight: Color {
    Color(red: red, green: green, blue: blue).opacity(0.24)
  }

  public var completedHighlight: Color {
    Color(red: red, green: green, blue: blue).opacity(0.11)
  }
}

public struct BookTileViewData: Identifiable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var author: String
  public var artworkURL: URL?
  public var usesSquareArtwork: Bool
  public var durationText: String?
  public var progress: Double?
  public var isInLibrary: Bool
  public var isRead: Bool
  public var isFavorite: Bool
  public var palette: ArtworkPalette
  public var seriesKey: String?
  public var seriesTitle: String?
  public var seriesPosition: Double?
  public var publishedYear: Int?
  public var narrator: String?
  public var description: String?

  public init(
    id: String,
    title: String,
    author: String,
    artworkURL: URL? = nil,
    usesSquareArtwork: Bool = false,
    durationText: String? = nil,
    progress: Double? = nil,
    isInLibrary: Bool = true,
    isRead: Bool = false,
    isFavorite: Bool = false,
    palette: ArtworkPalette = .fallback,
    seriesKey: String? = nil,
    seriesTitle: String? = nil,
    seriesPosition: Double? = nil,
    publishedYear: Int? = nil,
    narrator: String? = nil,
    description: String? = nil
  ) {
    self.id = id
    self.title = title
    self.author = author
    self.artworkURL = artworkURL
    self.usesSquareArtwork = usesSquareArtwork
    self.durationText = durationText
    self.progress = progress.map { min(max($0, 0), 1) }
    self.isInLibrary = isInLibrary
    self.isRead = isRead
    self.isFavorite = isFavorite
    self.palette = palette
    self.seriesKey = seriesKey
    self.seriesTitle = seriesTitle
    self.seriesPosition = seriesPosition
    self.publishedYear = publishedYear
    self.narrator = narrator
    self.description = description
  }

  public var secondaryMetadataText: String {
    guard let seriesPosition else { return author }
    return "\(author)  ·  \(KindlingUIFormatters.seriesPositionText(seriesPosition))"
  }
}

public struct BookActionViewData: Hashable, Sendable {
  public var canEmailToKindle: Bool
  public var isFavorite: Bool
  public var isRead: Bool
  public var canShare: Bool
  public var canDownload: Bool
  public var canPlay: Bool
  public var playTitle: String

  public init(
    canEmailToKindle: Bool = false,
    isFavorite: Bool = false,
    isRead: Bool = false,
    canShare: Bool = false,
    canDownload: Bool = false,
    canPlay: Bool = false,
    playTitle: String = "Play"
  ) {
    self.canEmailToKindle = canEmailToKindle
    self.isFavorite = isFavorite
    self.isRead = isRead
    self.canShare = canShare
    self.canDownload = canDownload
    self.canPlay = canPlay
    self.playTitle = playTitle
  }
}

public struct BookDetailViewData: Identifiable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var author: String
  public var artworkURL: URL?
  public var usesSquareArtwork: Bool
  public var palette: ArtworkPalette
  public var durationText: String?
  public var progress: Double?
  public var seriesTitle: String?
  public var seriesPosition: Double?
  public var narrator: String?
  public var publishedYear: Int?
  public var description: String?

  public init(
    id: String,
    title: String,
    author: String,
    artworkURL: URL? = nil,
    usesSquareArtwork: Bool = false,
    palette: ArtworkPalette = .fallback,
    durationText: String? = nil,
    progress: Double? = nil,
    seriesTitle: String? = nil,
    seriesPosition: Double? = nil,
    narrator: String? = nil,
    publishedYear: Int? = nil,
    description: String? = nil
  ) {
    self.id = id
    self.title = title
    self.author = author
    self.artworkURL = artworkURL
    self.usesSquareArtwork = usesSquareArtwork
    self.palette = palette
    self.durationText = durationText
    self.progress = progress.map { min(max($0, 0), 1) }
    self.seriesTitle = seriesTitle
    self.seriesPosition = seriesPosition
    self.narrator = narrator
    self.publishedYear = publishedYear
    self.description = description
  }

  public var metadataText: String? {
    let parts = [
      narrator.map { "Narrated by \($0)" },
      publishedYear.map(String.init),
    ].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "    ")
  }

  public var seriesText: String? {
    guard let seriesTitle, seriesTitle.isEmpty == false else { return nil }
    if let seriesPosition {
      return "\(KindlingUIFormatters.seriesPositionText(seriesPosition)) in \(seriesTitle)"
    }
    return seriesTitle
  }
}

public struct ChapterRowViewData: Identifiable, Hashable, Sendable {
  public var id: Int
  public var title: String
  public var durationText: String
  public var progress: Double
  public var isCompleted: Bool
  public var isCurrent: Bool

  public init(
    id: Int,
    title: String,
    durationText: String,
    progress: Double = 0,
    isCompleted: Bool = false,
    isCurrent: Bool = false
  ) {
    self.id = id
    self.title = title
    self.durationText = durationText
    self.progress = max(0, min(1, progress))
    self.isCompleted = isCompleted
    self.isCurrent = isCurrent
  }
}

public struct PlayerViewData: Hashable, Sendable {
  public var artworkURL: URL?
  public var palette: ArtworkPalette
  public var bookCompletionPercent: Int
  public var bookProgress: Double
  public var currentChapterTitle: String?
  public var currentChapterProgress: Double
  public var currentChapterElapsedText: String
  public var currentChapterRemainingText: String
  public var isPlaying: Bool
  public var playbackRateText: String
  public var chapters: [ChapterRowViewData]
  public var transcriptStatusText: String?

  public init(
    artworkURL: URL? = nil,
    palette: ArtworkPalette = .fallback,
    bookCompletionPercent: Int = 0,
    bookProgress: Double = 0,
    currentChapterTitle: String? = nil,
    currentChapterProgress: Double = 0,
    currentChapterElapsedText: String = "0:00",
    currentChapterRemainingText: String = "-0:00",
    isPlaying: Bool = false,
    playbackRateText: String = "1x",
    chapters: [ChapterRowViewData] = [],
    transcriptStatusText: String? = nil
  ) {
    self.artworkURL = artworkURL
    self.palette = palette
    self.bookCompletionPercent = max(0, min(100, bookCompletionPercent))
    self.bookProgress = max(0, min(1, bookProgress))
    self.currentChapterTitle = currentChapterTitle
    self.currentChapterProgress = max(0, min(1, currentChapterProgress))
    self.currentChapterElapsedText = currentChapterElapsedText
    self.currentChapterRemainingText = currentChapterRemainingText
    self.isPlaying = isPlaying
    self.playbackRateText = playbackRateText
    self.chapters = chapters
    self.transcriptStatusText = transcriptStatusText
  }
}

public struct SeriesViewData: Identifiable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var books: [BookTileViewData]

  public init(id: String, title: String, books: [BookTileViewData]) {
    self.id = id
    self.title = title
    self.books = Self.sortedBooks(books)
  }

  public static func groups(from books: [BookTileViewData]) -> [SeriesViewData] {
    let grouped = Dictionary(grouping: books) { book in
      book.seriesKey ?? book.seriesTitle ?? ""
    }

    return grouped.compactMap { key, books in
      guard key.isEmpty == false else { return nil }
      let title = books.first?.seriesTitle ?? key
      return SeriesViewData(id: key, title: title, books: books)
    }
    .sorted { lhs, rhs in
      lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
  }

  public static func sortedBooks(_ books: [BookTileViewData]) -> [BookTileViewData] {
    books.sorted { lhs, rhs in
      switch (lhs.seriesPosition, rhs.seriesPosition) {
      case (let left?, let right?) where left != right:
        left < right
      case (_?, nil):
        true
      case (nil, _?):
        false
      default:
        lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
    }
  }
}

public enum BookCollectionHelpers {
  public static func favorites(from books: [BookTileViewData]) -> [BookTileViewData] {
    books.filter(\.isFavorite)
  }
}

public enum ReadProgressPolicy {
  public static let completionThreshold: Double = 0.995

  public static func shouldMarkRead(currentTime: Double, duration: Double) -> Bool {
    guard duration.isFinite, duration > 0, currentTime.isFinite else { return false }
    return min(max(currentTime / duration, 0), 1) >= completionThreshold
  }
}

public enum KindlingUIFormatters {
  public static func durationText(seconds: Int?) -> String? {
    guard let seconds, seconds > 0 else { return nil }
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 {
      return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    return "\(minutes)m"
  }

  public static func playbackTime(_ seconds: Double) -> String {
    let totalSeconds = max(0, Int(seconds.rounded()))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let remainingSeconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
  }

  public static func percent(currentTime: Double, duration: Double) -> Int {
    guard duration.isFinite, duration > 0, currentTime.isFinite else { return 0 }
    let progress = min(max(currentTime / duration, 0), 1)
    return Int((progress * 100).rounded())
  }

  public static func progress(currentTime: Double, duration: Double) -> Double {
    guard duration.isFinite, duration > 0, currentTime.isFinite else { return 0 }
    return min(max(currentTime / duration, 0), 1)
  }

  public static func seriesPositionText(_ value: Double) -> String {
    if value.rounded() == value {
      return "#\(Int(value))"
    }
    return "#\(String(format: "%.1f", value))"
  }
}

public struct BookCollectionView: View {
  public let books: [BookTileViewData]
  public let layout: BookCollectionLayout
  public let filter: BookCollectionFilter
  public let contentTopPadding: CGFloat
  public let onSelect: (BookTileViewData) -> Void
  public let onToggleRead: (BookTileViewData) -> Void
  public let onToggleFavorite: (BookTileViewData) -> Void
  public let onScrolledPastHeader: (Bool) -> Void
  private let artwork: ((BookTileViewData, CGFloat) -> AnyView)?

  public init(
    books: [BookTileViewData],
    layout: BookCollectionLayout,
    filter: BookCollectionFilter,
    contentTopPadding: CGFloat = 0,
    artwork: ((BookTileViewData, CGFloat) -> AnyView)? = nil,
    onSelect: @escaping (BookTileViewData) -> Void = { _ in },
    onToggleRead: @escaping (BookTileViewData) -> Void = { _ in },
    onToggleFavorite: @escaping (BookTileViewData) -> Void = { _ in },
    onScrolledPastHeader: @escaping (Bool) -> Void = { _ in }
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
  }

  public var body: some View {
    let filteredBooks = filter.filtered(books)
    Group {
      if filteredBooks.isEmpty {
        ContentUnavailableView("No Books", systemImage: "books.vertical")
      } else {
        switch layout {
        case .grid:
          ScrollView {
            LazyVGrid(
              columns: [
                GridItem(.flexible(), spacing: 18),
                GridItem(.flexible(), spacing: 18),
              ],
              spacing: 20
            ) {
              ForEach(filteredBooks) { book in
                BookGridTileView(
                  book: book,
                  artwork: { collectionArtwork(for: book, cornerRadius: $0) },
                  onSelect: { onSelect(book) },
                  onToggleRead: { onToggleRead(book) },
                  onToggleFavorite: { onToggleFavorite(book) }
                )
              }
            }
            .padding(.horizontal, 18)
            .padding(.top, contentTopPadding + 12)
            .padding(.bottom, 12)
          }
          .onScrollGeometryChange(
            for: Bool.self,
            of: { $0.contentOffset.y > 44 },
            action: { _, isScrolledPastHeader in
              onScrolledPastHeader(isScrolledPastHeader)
            }
          )
        case .list:
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(filteredBooks) { book in
                BookListRowView(
                  book: book,
                  artwork: { collectionArtwork(for: book, cornerRadius: $0) },
                  onSelect: { onSelect(book) },
                  onToggleRead: { onToggleRead(book) },
                  onToggleFavorite: { onToggleFavorite(book) }
                )

                if book.id != filteredBooks.last?.id {
                  Divider()
                    .padding(.leading, 86)
                    .padding(.trailing, 18)
                }
              }
            }
            .padding(.top, contentTopPadding + 8)
            .padding(.bottom, 8)
          }
          .onScrollGeometryChange(
            for: Bool.self,
            of: { $0.contentOffset.y > 44 },
            action: { _, isScrolledPastHeader in
              onScrolledPastHeader(isScrolledPastHeader)
            }
          )
        }
      }
    }
  }

  private func collectionArtwork(for book: BookTileViewData, cornerRadius: CGFloat) -> AnyView {
    if let artwork {
      return artwork(book, cornerRadius)
    }

    return AnyView(
      CoverArtworkView(
        title: book.title,
        author: book.author,
        url: book.artworkURL,
        cornerRadius: cornerRadius
      )
    )
  }
}

public struct BookGridTileView: View {
  public let book: BookTileViewData
  public let onSelect: () -> Void
  public let onToggleRead: () -> Void
  public let onToggleFavorite: () -> Void
  private let artwork: ((CGFloat) -> AnyView)?

  public init(
    book: BookTileViewData,
    artwork: ((CGFloat) -> AnyView)? = nil,
    onSelect: @escaping () -> Void = {},
    onToggleRead: @escaping () -> Void = {},
    onToggleFavorite: @escaping () -> Void = {}
  ) {
    self.book = book
    self.artwork = artwork
    self.onSelect = onSelect
    self.onToggleRead = onToggleRead
    self.onToggleFavorite = onToggleFavorite
  }

  public var body: some View {
    Group {
      if book.isInLibrary {
        Button(action: onSelect) {
          tileContent
        }
        .buttonStyle(.plain)
      } else {
        tileContent
      }
    }
  }

  private var tileContent: some View {
    VStack(alignment: .leading, spacing: 6) {
      statusStrip
      artworkView
      metadata
    }
    .contentShape(Rectangle())
  }

  private var statusStrip: some View {
    HStack(spacing: 6) {
      Image(systemName: book.isInLibrary ? "music.note" : "books.vertical")
      if let durationText = book.durationText {
        Text(durationText)
          .monospacedDigit()
      }
      Spacer(minLength: 0)
      if book.isInLibrary {
        Button(action: onToggleRead) {
          Image(systemName: book.isRead ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(book.isRead ? "Mark as unread" : "Mark as read")
      } else {
        Text("Not in Library")
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
    }
    .font(.caption2.weight(.semibold))
    .foregroundStyle(book.palette.foreground)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(book.palette.background, in: RoundedRectangle(cornerRadius: 3))
  }

  private var metadata: some View {
    VStack(spacing: 2) {
      Text(book.title)
        .font(.caption.weight(.bold))
        .foregroundStyle(.primary)
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
      Text(book.secondaryMetadataText)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 46, alignment: .top)
  }

  @ViewBuilder
  private var artworkView: some View {
    CoverCropFrame(cornerRadius: 4) {
      artworkContent(cornerRadius: 4)
    }
    .overlay(alignment: .bottom) {
      ArtworkProgressBar(progress: book.progress)
        .padding(.horizontal, 5)
        .padding(.bottom, 5)
    }
    .aspectRatio(artworkAspectRatio, contentMode: .fit)
    .frame(maxWidth: .infinity)
  }

  private var artworkAspectRatio: CGFloat {
    book.usesSquareArtwork ? 1 : 2 / 3
  }

  @ViewBuilder
  private func artworkContent(cornerRadius: CGFloat) -> some View {
    if let artwork {
      artwork(cornerRadius)
    } else {
      CoverArtworkView(
        title: book.title,
        author: book.author,
        url: book.artworkURL,
        cornerRadius: cornerRadius
      )
    }
  }
}

public struct BookListRowView: View {
  public let book: BookTileViewData
  public let onSelect: () -> Void
  public let onToggleRead: () -> Void
  public let onToggleFavorite: () -> Void
  private let artwork: ((CGFloat) -> AnyView)?

  public init(
    book: BookTileViewData,
    artwork: ((CGFloat) -> AnyView)? = nil,
    onSelect: @escaping () -> Void = {},
    onToggleRead: @escaping () -> Void = {},
    onToggleFavorite: @escaping () -> Void = {}
  ) {
    self.book = book
    self.artwork = artwork
    self.onSelect = onSelect
    self.onToggleRead = onToggleRead
    self.onToggleFavorite = onToggleFavorite
  }

  public var body: some View {
    Group {
      if book.isInLibrary {
        Button(action: onSelect) {
          rowContent
        }
        .buttonStyle(.plain)
      } else {
        rowContent
      }
    }
  }

  private var rowContent: some View {
    HStack(spacing: 12) {
      CoverCropFrame(cornerRadius: 5) {
        artworkContent(cornerRadius: 5)
      }
      .frame(width: 56, height: book.usesSquareArtwork ? 56 : 82)

      VStack(alignment: .leading, spacing: 4) {
        Text(book.title)
          .font(.headline)
          .lineLimit(2)
        Text(book.secondaryMetadataText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let durationText = book.durationText {
          Label(durationText, systemImage: "music.note")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      if book.isInLibrary {
        Button(action: onToggleFavorite) {
          Image(systemName: book.isFavorite ? "heart.fill" : "heart")
        }
        .buttonStyle(.plain)
        Button(action: onToggleRead) {
          Image(systemName: book.isRead ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.plain)
      } else {
        Text("Not in Library")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .foregroundStyle(.primary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private func artworkContent(cornerRadius: CGFloat) -> some View {
    if let artwork {
      artwork(cornerRadius)
    } else {
      CoverArtworkView(
        title: book.title,
        author: book.author,
        url: book.artworkURL,
        cornerRadius: cornerRadius
      )
    }
  }
}

public struct BookDetailHeroView<Artwork: View, SeriesBar: View>: View {
  public let book: BookDetailViewData
  private let onAuthor: (() -> Void)?
  private let artwork: Artwork
  private let seriesBar: SeriesBar

  public init(
    book: BookDetailViewData,
    onAuthor: (() -> Void)? = nil,
    @ViewBuilder artwork: () -> Artwork,
    @ViewBuilder seriesBar: () -> SeriesBar
  ) {
    self.book = book
    self.onAuthor = onAuthor
    self.artwork = artwork()
    self.seriesBar = seriesBar()
  }

  public var body: some View {
    VStack(alignment: .center, spacing: 16) {
      artwork
        .frame(maxWidth: .infinity, alignment: .center)

      VStack(alignment: .center, spacing: 4) {
        BookDetailTitleBlockView(book: book, onAuthor: onAuthor)
        seriesBar
        if let metadataText = book.metadataText {
          Text(metadataText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
      }
    }
    .padding(.top, 8)
  }
}

extension BookDetailHeroView where SeriesBar == EmptyView {
  public init(
    book: BookDetailViewData,
    onAuthor: (() -> Void)? = nil,
    @ViewBuilder artwork: () -> Artwork
  ) {
    self.init(book: book, onAuthor: onAuthor, artwork: artwork) {
      EmptyView()
    }
  }
}

public struct BookDetailSeriesBarView: View {
  public let text: String
  public let showsDisclosureIndicator: Bool

  public init(
    text: String,
    showsDisclosureIndicator: Bool = false
  ) {
    self.text = text
    self.showsDisclosureIndicator = showsDisclosureIndicator
  }

  public var body: some View {
    HStack(spacing: 6) {
      Text(text)
        .frame(maxWidth: .infinity, alignment: .center)
      if showsDisclosureIndicator {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.bold))
          .accessibilityHidden(true)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }
}

public struct BookDetailTitleBlockView: View {
  public let book: BookDetailViewData
  private let onAuthor: (() -> Void)?

  public init(book: BookDetailViewData, onAuthor: (() -> Void)? = nil) {
    self.book = book
    self.onAuthor = onAuthor
  }

  public var body: some View {
    VStack(alignment: .center, spacing: 4) {
      Text(book.title)
        .font(.headline.weight(.bold))
        .multilineTextAlignment(.center)
      if let onAuthor {
        Button(action: onAuthor) {
          HStack(spacing: 3) {
            Text(book.author)
            Image(systemName: "chevron.right")
              .font(.caption2.weight(.semibold))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .accessibilityLabel("Works by \(book.author)")
      } else {
        Text(book.author)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

public struct BookDetailContentView: View {
  public let book: BookDetailViewData
  public let actions: BookActionViewData
  public let onSeries: () -> Void
  public let onAuthor: () -> Void
  public let onEmailToKindle: () -> Void
  public let onToggleFavorite: () -> Void
  public let onToggleRead: () -> Void
  public let onShare: () -> Void
  public let onDownload: () -> Void
  public let onPlay: () -> Void
  public let onMore: () -> Void

  public init(
    book: BookDetailViewData,
    actions: BookActionViewData,
    onSeries: @escaping () -> Void = {},
    onAuthor: @escaping () -> Void = {},
    onEmailToKindle: @escaping () -> Void = {},
    onToggleFavorite: @escaping () -> Void = {},
    onToggleRead: @escaping () -> Void = {},
    onShare: @escaping () -> Void = {},
    onDownload: @escaping () -> Void = {},
    onPlay: @escaping () -> Void = {},
    onMore: @escaping () -> Void = {}
  ) {
    self.book = book
    self.actions = actions
    self.onSeries = onSeries
    self.onAuthor = onAuthor
    self.onEmailToKindle = onEmailToKindle
    self.onToggleFavorite = onToggleFavorite
    self.onToggleRead = onToggleRead
    self.onShare = onShare
    self.onDownload = onDownload
    self.onPlay = onPlay
    self.onMore = onMore
  }

  public var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          detailHero

          if let description = book.description, description.isEmpty == false {
            Text(description)
              .font(.footnote)
              .foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, 6)
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
      }

      BookActionToolbar(
        actions: actions,
        onEmailToKindle: onEmailToKindle,
        onToggleFavorite: onToggleFavorite,
        onToggleRead: onToggleRead,
        onShare: onShare,
        onDownload: onDownload,
        onPlay: onPlay,
        onMore: onMore
      )
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
    }
  }

  @ViewBuilder
  private var detailHero: some View {
    if let seriesText = book.seriesText {
      BookDetailHeroView(book: book, onAuthor: onAuthor) {
        detailArtwork
      } seriesBar: {
        Button(action: onSeries) {
          BookDetailSeriesBarView(text: seriesText)
        }
        .buttonStyle(.plain)
      }
    } else {
      BookDetailHeroView(book: book, onAuthor: onAuthor) {
        detailArtwork
      }
    }
  }

  private var detailArtwork: some View {
    CoverCropFrame(cornerRadius: 5) {
      CoverArtworkView(
        title: book.title,
        author: book.author,
        url: book.artworkURL,
        cornerRadius: 5
      )
    }
    .aspectRatio(book.usesSquareArtwork ? 1 : 2 / 3, contentMode: .fit)
    .frame(maxWidth: 216)
  }
}

public struct BookActionToolbar: View {
  public let actions: BookActionViewData
  public let onEmailToKindle: () -> Void
  public let onToggleFavorite: () -> Void
  public let onToggleRead: () -> Void
  public let onShare: () -> Void
  public let onDownload: () -> Void
  public let onPlay: () -> Void
  public let onMore: () -> Void

  public init(
    actions: BookActionViewData,
    onEmailToKindle: @escaping () -> Void = {},
    onToggleFavorite: @escaping () -> Void = {},
    onToggleRead: @escaping () -> Void = {},
    onShare: @escaping () -> Void = {},
    onDownload: @escaping () -> Void = {},
    onPlay: @escaping () -> Void = {},
    onMore: @escaping () -> Void = {}
  ) {
    self.actions = actions
    self.onEmailToKindle = onEmailToKindle
    self.onToggleFavorite = onToggleFavorite
    self.onToggleRead = onToggleRead
    self.onShare = onShare
    self.onDownload = onDownload
    self.onPlay = onPlay
    self.onMore = onMore
  }

  public var body: some View {
    HStack(spacing: 10) {
      if actions.canEmailToKindle {
        toolbarButton("paperplane", label: "Send to Kindle", action: onEmailToKindle)
      }
      toolbarButton(
        actions.isFavorite ? "heart.fill" : "heart",
        label: actions.isFavorite ? "Unfavorite" : "Favorite",
        action: onToggleFavorite
      )
      toolbarButton(
        actions.isRead ? "checkmark.circle.fill" : "circle",
        label: actions.isRead ? "Mark as unread" : "Mark as read",
        action: onToggleRead
      )
      if actions.canShare {
        toolbarButton("square.and.arrow.up", label: "Share", action: onShare)
      }
      if actions.canDownload {
        toolbarButton("ellipsis", label: "More", action: onMore)
      }
      Button(action: onPlay) {
        Label(actions.playTitle, systemImage: "play.fill")
          .font(.headline.weight(.semibold))
          .frame(maxWidth: .infinity)
          .frame(height: 44)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .disabled(actions.canPlay == false)
    }
  }

  private func toolbarButton(
    _ systemImage: String,
    label: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .frame(width: 34, height: 44)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

public struct SeriesContentView: View {
  public let series: SeriesViewData
  public let layout: BookCollectionLayout
  public let filter: BookCollectionFilter
  public let contentTopPadding: CGFloat
  public let onSelect: (BookTileViewData) -> Void
  public let onToggleRead: (BookTileViewData) -> Void
  public let onToggleFavorite: (BookTileViewData) -> Void
  private let artwork: ((BookTileViewData, CGFloat) -> AnyView)?

  public init(
    series: SeriesViewData,
    layout: BookCollectionLayout,
    filter: BookCollectionFilter,
    contentTopPadding: CGFloat = 0,
    artwork: ((BookTileViewData, CGFloat) -> AnyView)? = nil,
    onSelect: @escaping (BookTileViewData) -> Void = { _ in },
    onToggleRead: @escaping (BookTileViewData) -> Void = { _ in },
    onToggleFavorite: @escaping (BookTileViewData) -> Void = { _ in }
  ) {
    self.series = series
    self.layout = layout
    self.filter = filter
    self.contentTopPadding = contentTopPadding
    self.artwork = artwork
    self.onSelect = onSelect
    self.onToggleRead = onToggleRead
    self.onToggleFavorite = onToggleFavorite
  }

  public var body: some View {
    BookGroupContentView(
      title: series.title,
      books: series.books,
      layout: layout,
      filter: filter,
      contentTopPadding: contentTopPadding,
      artwork: artwork,
      onSelect: onSelect,
      onToggleRead: onToggleRead,
      onToggleFavorite: onToggleFavorite
    )
  }
}

public struct BookGroupContentView: View {
  public let title: String
  public let books: [BookTileViewData]
  public let layout: BookCollectionLayout
  public let filter: BookCollectionFilter
  public let contentTopPadding: CGFloat
  public let onSelect: (BookTileViewData) -> Void
  public let onToggleRead: (BookTileViewData) -> Void
  public let onToggleFavorite: (BookTileViewData) -> Void
  private let artwork: ((BookTileViewData, CGFloat) -> AnyView)?

  public init(
    title: String,
    books: [BookTileViewData],
    layout: BookCollectionLayout,
    filter: BookCollectionFilter,
    contentTopPadding: CGFloat = 0,
    artwork: ((BookTileViewData, CGFloat) -> AnyView)? = nil,
    onSelect: @escaping (BookTileViewData) -> Void = { _ in },
    onToggleRead: @escaping (BookTileViewData) -> Void = { _ in },
    onToggleFavorite: @escaping (BookTileViewData) -> Void = { _ in }
  ) {
    self.title = title
    self.books = books
    self.layout = layout
    self.filter = filter
    self.contentTopPadding = contentTopPadding
    self.artwork = artwork
    self.onSelect = onSelect
    self.onToggleRead = onToggleRead
    self.onToggleFavorite = onToggleFavorite
  }

  public var body: some View {
    BookCollectionView(
      books: books,
      layout: layout,
      filter: filter,
      contentTopPadding: contentTopPadding,
      artwork: artwork,
      onSelect: onSelect,
      onToggleRead: onToggleRead,
      onToggleFavorite: onToggleFavorite
    )
    .navigationTitle(title)
  }
}

public enum PlayerContentTab: String, CaseIterable, Identifiable, Sendable {
  case cover = "Cover"
  case chapters = "Chapters"
  case transcript = "Transcript"

  public var id: String { rawValue }
}

public struct PlayerCoverContentView<Artwork: View>: View {
  public let player: PlayerViewData
  public let artworkMaxWidth: CGFloat?
  public let showsChapterProgress: Bool
  private let artwork: Artwork

  public init(
    player: PlayerViewData,
    artworkMaxWidth: CGFloat? = 240,
    showsChapterProgress: Bool = true,
    @ViewBuilder artwork: () -> Artwork
  ) {
    self.player = player
    self.artworkMaxWidth = artworkMaxWidth
    self.showsChapterProgress = showsChapterProgress
    self.artwork = artwork()
  }

  public var body: some View {
    VStack(spacing: 14) {
      VStack(spacing: 6) {
        Text("\(player.bookCompletionPercent)% of book completed")
          .font(.caption.weight(.semibold))
          .frame(maxWidth: .infinity, alignment: .center)
        ProgressView(value: player.bookProgress)
          .tint(.primary)
      }

      framedArtwork

      if let chapterTitle = player.currentChapterTitle {
        Text(chapterTitle)
          .font(.headline)
          .multilineTextAlignment(.center)
      }

      if showsChapterProgress {
        VStack(spacing: 6) {
          ProgressView(value: player.currentChapterProgress)
            .tint(.primary)
          HStack {
            Text(player.currentChapterElapsedText)
            Spacer()
            Text(player.currentChapterRemainingText)
          }
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder
  private var framedArtwork: some View {
    if let artworkMaxWidth {
      artwork
        .frame(maxWidth: artworkMaxWidth)
    } else {
      artwork
    }
  }
}

public struct PlayerContentView: View {
  public let player: PlayerViewData
  public let selectedTab: PlayerContentTab
  public let onSelectTab: (PlayerContentTab) -> Void
  public let onPlayPause: () -> Void
  public let onBack: () -> Void
  public let onForward: () -> Void
  public let onSelectChapter: (ChapterRowViewData) -> Void

  public init(
    player: PlayerViewData,
    selectedTab: PlayerContentTab = .cover,
    onSelectTab: @escaping (PlayerContentTab) -> Void = { _ in },
    onPlayPause: @escaping () -> Void = {},
    onBack: @escaping () -> Void = {},
    onForward: @escaping () -> Void = {},
    onSelectChapter: @escaping (ChapterRowViewData) -> Void = { _ in }
  ) {
    self.player = player
    self.selectedTab = selectedTab
    self.onSelectTab = onSelectTab
    self.onPlayPause = onPlayPause
    self.onBack = onBack
    self.onForward = onForward
    self.onSelectChapter = onSelectChapter
  }

  public var body: some View {
    VStack(spacing: 14) {
      Picker("Player", selection: Binding(get: { selectedTab }, set: onSelectTab)) {
        ForEach(PlayerContentTab.allCases) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      switch selectedTab {
      case .cover:
        PlayerCoverContentView(player: player) {
          CoverCropFrame(cornerRadius: 5) {
            CoverArtworkView(
              title: "",
              author: "",
              url: player.artworkURL,
              cornerRadius: 5
            )
          }
          .aspectRatio(1, contentMode: .fit)
        }
      case .chapters:
        ChapterListView(
          chapters: player.chapters,
          palette: player.palette,
          onSelectChapter: onSelectChapter
        )
      case .transcript:
        Text(player.transcriptStatusText ?? "Transcript")
          .font(.body)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      transportControls
    }
    .padding(16)
  }

  private var transportControls: some View {
    HStack(spacing: 26) {
      Button(action: onBack) {
        Image(systemName: "gobackward.15")
          .font(.title2.weight(.semibold))
      }
      Button(action: onPlayPause) {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 42, weight: .regular))
          .frame(width: 58, height: 58)
      }
      Button(action: onForward) {
        Image(systemName: "goforward.30")
          .font(.title2.weight(.semibold))
      }
      Text(player.playbackRateText)
        .font(.headline.weight(.semibold))
        .monospacedDigit()
        .frame(width: 42)
    }
    .foregroundStyle(.primary)
  }
}

public struct ChapterListView: View {
  public let chapters: [ChapterRowViewData]
  public let palette: ArtworkPalette
  public let onSelectChapter: (ChapterRowViewData) -> Void

  public init(
    chapters: [ChapterRowViewData],
    palette: ArtworkPalette = .fallback,
    onSelectChapter: @escaping (ChapterRowViewData) -> Void = { _ in }
  ) {
    self.chapters = chapters
    self.palette = palette
    self.onSelectChapter = onSelectChapter
  }

  public var body: some View {
    ScrollView {
      LazyVStack(spacing: 7) {
        ForEach(chapters) { chapter in
          ChapterRowView(
            chapter: chapter,
            palette: palette,
            onSelect: { onSelectChapter(chapter) }
          )
        }
      }
      .padding(.vertical, 4)
    }
  }
}

public struct ChapterRowView: View {
  public let chapter: ChapterRowViewData
  public let palette: ArtworkPalette
  public let onSelect: () -> Void

  public init(
    chapter: ChapterRowViewData,
    palette: ArtworkPalette = .fallback,
    onSelect: @escaping () -> Void = {}
  ) {
    self.chapter = chapter
    self.palette = palette
    self.onSelect = onSelect
  }

  public var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 10) {
        Text(chapter.title)
          .font(.subheadline.weight(chapter.isCurrent ? .semibold : .regular))
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(chapter.durationText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
  }

  private var rowBackground: Color {
    if chapter.isCurrent {
      palette.currentHighlight
    } else if chapter.isCompleted {
      palette.completedHighlight
    } else {
      Color.primary.opacity(0.04)
    }
  }
}

private struct CoverArtworkView: View {
  let title: String
  let author: String
  let url: URL?
  let cornerRadius: CGFloat

  var body: some View {
    Group {
      if let url {
        AsyncImage(url: url) { image in
          image
            .resizable()
            .scaledToFill()
        } placeholder: {
          placeholder
        }
      } else {
        placeholder
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
  }

  private var placeholder: some View {
    ZStack {
      Rectangle()
        .fill(.quaternary)
      VStack(spacing: 6) {
        Text(title.isEmpty ? "Kindling" : title)
          .font(.caption.weight(.bold))
          .multilineTextAlignment(.center)
          .lineLimit(4)
        if author.isEmpty == false {
          Text(author)
            .font(.caption2)
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }
      }
      .padding(10)
      .foregroundStyle(.secondary)
    }
  }
}

private struct CoverCropFrame<Artwork: View>: View {
  let cornerRadius: CGFloat
  private let artwork: Artwork

  init(cornerRadius: CGFloat, @ViewBuilder artwork: () -> Artwork) {
    self.cornerRadius = cornerRadius
    self.artwork = artwork()
  }

  var body: some View {
    GeometryReader { proxy in
      artwork
        .frame(width: proxy.size.width, height: proxy.size.height)
        .clipped()
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }
}

private struct ArtworkProgressBar: View {
  let progress: Double?

  var body: some View {
    if let progress, progress > 0, progress < 1 {
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(.black.opacity(0.18))
          Capsule()
            .fill(.white.opacity(0.86))
            .frame(width: proxy.size.width * progress)
        }
      }
      .frame(height: 3)
    }
  }
}
