import Combine
import Foundation
import SwiftData
import SwiftUI

/// One runtime for UI and background intent execution. Never create a second player or store.
@MainActor
final class KindlingRuntime: ObservableObject {
  @Published var requestedBookID: String?
  static let shared = KindlingRuntime()
  let container: ModelContainer
  let repository: PlaybackRepository
  let player: AudioPlayerController
  let settings = UserSettings()
  let auth = PodibleAuthController()

  private var completionObserver: AnyCancellable?
  private var playRequest = UUID()
  private(set) var isHandlingPlaybackIntent = false

  init(container: ModelContainer? = nil, defaults: UserDefaults = .standard) {
    if let container {
      self.container = container
    } else {
      let schema = Schema(versionedSchema: KindlingSchemaV4.self)
      do {
        self.container = try ModelContainer(
          for: schema, migrationPlan: KindlingMigrationPlan.self,
          configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)])
      } catch { fatalError("Could not create ModelContainer: \(error)") }
    }
    repository = PlaybackRepository(context: self.container.mainContext, defaults: defaults)
    try? repository.migrateLegacyState()
    player = AudioPlayerController(defaults: defaults, repository: repository)
    completionObserver = NotificationCenter.default.publisher(for: .audioPlayerDidFinishItem).sink {
      [weak self] notification in
      guard let source = notification.object as? AudioPlayerController,
        let finishedIdentity = source.activePlaybackIdentity
      else { return }
      Task { @MainActor [weak self] in
        guard let self, source === self.player, let id = finishedIdentity.podibleID else { return }
        let context = self.container.mainContext
        guard let books = try? context.fetch(FetchDescriptor<LibraryBook>()),
          let book = books.first(where: { $0.podibleId == id })
        else { return }
        let identity = finishedIdentity
        let store = LibraryStore()
        store.update(
          books: [book],
          activities: (try? context.fetch(FetchDescriptor<BookActivityState>())) ?? [],
          syncStates: [])
        try? store.markFinishedPlaybackRead(
          resumeID: identity.canonicalID, identity: { _ in identity }, context: context)
      }
    }
  }

  func catalog() throws -> [AudiobookRecord] {
    var result: [AudiobookRecord] = []
    for book in try container.mainContext.fetch(FetchDescriptor<LibraryBook>()) {
      let playback = book.playbackJSON.flatMap {
        try? JSONDecoder().decode(PodiblePlayback.self, from: $0)
      }
      var options = playback?.audioOptions ?? []
      if let audio = playback?.audio,
        !options.contains(where: { $0.manifestationId == audio.manifestationId })
      {
        options.insert(audio, at: 0)
      }
      let local = book.files.first {
        $0.downloadStatus == .completed && $0.localRelativePath != nil
      }
      if options.isEmpty && local == nil { continue }
      let choices: [PodiblePlaybackAudio?] = options.isEmpty ? [nil] : options.map { $0 }
      for audio in choices {
        let identity = PlaybackIdentity(
          openLibraryWorkID: book.openLibraryWorkID, podibleID: book.podibleId,
          manifestationID: audio?.manifestationId)
        // Existing downloads belong to the book's default audio edition.
        let path =
          audio?.manifestationId == playback?.audio?.manifestationId
          ? local?.localRelativePath : nil
        let record = AudiobookRecord(
          id: identity.canonicalID, bookID: book.podibleId, title: book.title,
          author: book.author?.name, narrator: book.narrator, series: book.series?.title,
          edition: audio?.label, summary: book.summary, identity: identity, audio: audio,
          localPath: path,
          finished: book.localState?.isRead == true
            || repository.completedDuration(for: identity) != nil,
          lastPlayed: repository.lastPlayedAt(for: identity)
            ?? (audio?.manifestationId == playback?.audio?.manifestationId
              ? book.localState?.lastPlayedAt : nil))
        result.append(record)
      }
    }
    return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  func resume() async throws {
    if let id = player.activeResumeID, player.hasLoadedItem, !player.hasFinished,
      try catalog().contains(where: { $0.id == id && !$0.finished })
    {
      try await play(id: id)
      return
    }
    guard
      let record = try catalog().filter({ !$0.finished && $0.lastPlayed != nil })
        .max(by: { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) })
    else {
      throw AudiobookIntentError.noCurrentBook
    }
    try await play(id: record.id)
  }

  func play(id: String) async throws {
    let request = UUID()
    playRequest = request
    isHandlingPlaybackIntent = true
    defer { if playRequest == request { isHandlingPlaybackIntent = false } }
    let previousIdentity = player.activeResumeID
    guard let record = try catalog().first(where: { $0.id == id }) else {
      throw AudiobookIntentError.unavailable
    }
    guard !record.finished else { throw AudiobookIntentError.finished }
    if player.activeResumeID == id && player.hasLoadedItem {
      guard !player.hasFinished else { throw AudiobookIntentError.finished }
      try await player.playForIntent()
      return
    }
    let context = container.mainContext
    guard
      let book = try context.fetch(FetchDescriptor<LibraryBook>()).first(where: {
        $0.podibleId == record.bookID
      })
    else { throw AudiobookIntentError.unavailable }
    let localURL = record.localPath.flatMap { try? LibraryStorage().url(forRelativePath: $0) }
      .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    if let localURL {
      player.load(
        url: localURL, identity: record.identity, title: record.title, author: record.author,
        description: record.summary, artworkURL: nil, artworkAccessToken: nil)
    } else {
      guard let audio = record.audio else { throw AudiobookIntentError.unavailable }
      await auth.refreshStoredSession(rpcURLString: settings.podibleRPCURL)
      guard let client = auth.makeAuthenticatedClient(rpcURLString: settings.podibleRPCURL) else {
        throw AudiobookIntentError.signIn
      }
      try Task.checkCancellation()
      guard playRequest == request, player.activeResumeID == previousIdentity else {
        throw CancellationError()
      }
      guard let current = try catalog().first(where: { $0.id == id }) else {
        throw AudiobookIntentError.unavailable
      }
      guard !current.finished else { throw AudiobookIntentError.finished }
      player.loadStreaming(
        httpURL: try client.audiobookStreamURL(playback: audio), accessToken: auth.accessToken,
        identity: record.identity, title: record.title, author: record.author,
        description: record.summary,
        artworkURL: nil, artworkAccessToken: auth.accessToken)
      Task {
        await PlaybackMetadataLoader(player: player).load(
          playback: audio, identity: record.identity, client: client)
      }
    }
    try LibraryStore().markStarted(book: book, context: context)
    try await player.playForIntent()
  }
}

struct AudiobookRecord: Sendable {
  let id: String
  let bookID: String
  let title: String
  let author: String?
  let narrator: String?
  let series: String?
  let edition: String?
  let summary: String?
  let identity: PlaybackIdentity
  let audio: PodiblePlaybackAudio?
  let localPath: String?
  let finished: Bool
  let lastPlayed: Date?

  func matches(_ text: String) -> Bool {
    let terms = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let searchable = [title, author, narrator, series, edition].compactMap { $0 }.joined(
      separator: " ")
    return !terms.isEmpty && terms.allSatisfy { searchable.localizedStandardContains($0) }
  }
}

enum AudiobookIntentError: LocalizedError {
  case unavailable, finished, noCurrentBook, signIn, unsupportedPlayback
  var errorDescription: String? {
    switch self {
    case .unavailable:
      "This audiobook is no longer available. Open Kindling to refresh your library."
    case .finished:
      "You’ve finished this audiobook. Choose an unfinished book to continue listening."
    case .noCurrentBook: "There’s no unfinished audiobook to resume. Choose a book in Kindling."
    case .signIn: "Open Kindling and sign in before streaming this audiobook."
    case .unsupportedPlayback: "Kindling does not support shuffle, repeat, or a playback queue."
    }
  }
}

#if os(iOS)
  import AppIntents
  import CoreSpotlight
  import MediaIntents
  import UniformTypeIdentifiers

  @AppEntity(schema: .audio.audiobook)
  struct KindlingAudiobook: IndexedEntity {
    static let defaultQuery = AudiobookQuery()
    let id: String
    var title: String?
    var author: String?
    var narrator: String?
    var seriesTitle: String?
    var genre: String?
    var publisher: String?
    var releaseDate: Date?
    var purchaseDate: Date?
    var edition: String?
    var summary: String?

    init(_ record: AudiobookRecord) {
      id = record.id
      title = record.title
      author = record.author
      narrator = record.narrator
      seriesTitle = record.series
      edition = record.edition
      summary = record.summary
    }

    var displayRepresentation: DisplayRepresentation {
      DisplayRepresentation(
        title: "\(title ?? "Audiobook")",
        subtitle: "\([author, edition].compactMap { $0 }.joined(separator: " · "))")
    }
    var attributeSet: CSSearchableItemAttributeSet {
      let attributes = CSSearchableItemAttributeSet(contentType: .audio)
      attributes.title = title
      attributes.contentDescription = summary
      attributes.authorNames = author.map { [$0] }
      attributes.keywords = [narrator, seriesTitle, edition].compactMap { $0 }
      return attributes
    }
  }

  struct AudiobookQuery: EntityStringQuery, IntentValueQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [KindlingAudiobook] {
      let records = try KindlingRuntime.shared.catalog()
      return identifiers.compactMap { id in
        records.first(where: { $0.id == id }).map(KindlingAudiobook.init)
      }
    }
    @MainActor func entities(matching string: String) async throws -> [KindlingAudiobook] {
      try KindlingRuntime.shared.catalog().filter { $0.matches(string) }.map(KindlingAudiobook.init)
    }
    @MainActor func suggestedEntities() async throws -> [KindlingAudiobook] {
      try KindlingRuntime.shared.catalog().filter { !$0.finished }.sorted {
        ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast)
      }.prefix(20).map(KindlingAudiobook.init)
    }
    @MainActor func values(for input: AudioSearch) async throws -> [KindlingAudiobook] {
      switch input.criteria {
      case .searchQuery(let query): return try await entities(matching: query)
      case .unspecified:
        let records = try KindlingRuntime.shared.catalog().filter { !$0.finished }
        let activeID = KindlingRuntime.shared.player.activeResumeID
        if let active = records.first(where: { $0.id == activeID }) {
          return [KindlingAudiobook(active)]
        }
        if let latest = records.filter({ $0.lastPlayed != nil }).max(by: {
          ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast)
        }) {
          return [KindlingAudiobook(latest)]
        }
        return try await suggestedEntities()
      case .url: return []
      @unknown default: return []
      }
    }
  }

  @AppEnum(schema: .audio.playbackAttributes)
  enum KindlingPlaybackAttributes: String {
    case shuffle
    case `repeat`
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
      .shuffle: "Shuffle", .repeat: "Repeat",
    ]
  }

  @UnionValue
  enum KindlingAudioItem {
    case audiobook(KindlingAudiobook)
  }

  @AppEnum(schema: .audio.queueInsertionLocation)
  enum KindlingQueueLocation: String {
    case next, tail
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
      .next: "Play Next", .tail: "Play Last",
    ]
  }

  @AppEntity(schema: .audio.warmupAudioQueueResult)
  struct KindlingWarmupResult {
    let id: String
    static let defaultQuery = Query()
    var displayRepresentation: DisplayRepresentation { "Prepared Audiobook" }
    struct Query: EntityStringQuery {
      func entities(matching string: String) async throws -> [KindlingWarmupResult] { [] }
      func entities(for identifiers: [String]) async throws -> [KindlingWarmupResult] { [] }
    }
  }

  @AppIntent(schema: .audio.playAudio)
  struct PlayKindlingAudiobook: AudioPlaybackIntent {
    var audioEntity: KindlingAudioItem
    var queueLocation: KindlingQueueLocation?
    var warmupAudioQueueResult: KindlingWarmupResult?
    var playbackAttributes: Set<KindlingPlaybackAttributes>
    @MainActor func perform() async throws -> some IntentResult {
      guard playbackAttributes.isEmpty, queueLocation == nil, warmupAudioQueueResult == nil else {
        throw AudiobookIntentError.unsupportedPlayback
      }
      switch audioEntity {
      case .audiobook(let book): try await KindlingRuntime.shared.play(id: book.id)
      }
      return .result()
    }
  }

  struct ResumeKindlingAudiobook: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Audiobook"
    static let description = IntentDescription(
      "Continue your most recent unfinished audiobook in Kindling.")
    @MainActor func perform() async throws -> some IntentResult {
      try await KindlingRuntime.shared.resume()
      return .result()
    }
  }

  struct FindKindlingAudiobooks: AppIntent {
    static let title: LocalizedStringResource = "Find Audiobooks"
    static let description = IntentDescription(
      "Search your local Kindling library by title, author, narrator, or series.")
    @Parameter(title: "Search") var search: String
    func perform() async throws -> some IntentResult & ReturnsValue<[KindlingAudiobook]> {
      .result(value: try await AudiobookQuery().entities(matching: search))
    }
  }

  struct OpenKindlingAudiobook: OpenIntent {
    static let title: LocalizedStringResource = "Open Audiobook"
    static let supportedModes: IntentModes = .foreground
    @Parameter(title: "Audiobook") var target: KindlingAudiobook
    @MainActor func perform() async throws -> some IntentResult {
      guard let record = try KindlingRuntime.shared.catalog().first(where: { $0.id == target.id })
      else {
        throw AudiobookIntentError.unavailable
      }
      KindlingRuntime.shared.requestedBookID = record.bookID
      return .result()
    }
  }

  struct KindlingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
      AppShortcut(
        intent: ResumeKindlingAudiobook(),
        phrases: [
          "Resume my audiobook in \(.applicationName)", "Play my audiobook in \(.applicationName)",
        ], shortTitle: "Resume Audiobook", systemImageName: "book.closed")
    }
  }

  @MainActor
  final class AudiobookSpotlightIndexer {
    static let shared = AudiobookSpotlightIndexer()
    private var pending: Task<Void, Never>?
    private var dirty = false
    private var lastSnapshot: [String]?
    func schedule() {
      dirty = true
      guard pending == nil else { return }
      pending = Task {
        defer { pending = nil }
        while dirty {
          try? await Task.sleep(for: .seconds(1))
          dirty = false
          do {
            let records = try KindlingRuntime.shared.catalog()
            let snapshot = records.map {
              [
                $0.id, $0.title, $0.author ?? "", $0.narrator ?? "", $0.series ?? "",
                $0.edition ?? "", $0.summary ?? "",
              ].joined(separator: "\u{0}")
            }
            guard snapshot != lastSnapshot else { continue }
            let entities = records.map(KindlingAudiobook.init)
            let previous =
              UserDefaults.standard.stringArray(forKey: "siri.indexedAudiobookIDs") ?? []
            let current = Set(entities.map(\.id))
            let removed = previous.filter { !current.contains($0) }
            let index = CSSearchableIndex.default()
            try await index.indexAppEntities(entities)
            try await index.deleteAppEntities(identifiedBy: removed, ofType: KindlingAudiobook.self)
            UserDefaults.standard.set(Array(current), forKey: "siri.indexedAudiobookIDs")
            lastSnapshot = snapshot
          } catch { print("Audiobook Spotlight indexing failed: \(error.localizedDescription)") }
        }
      }
    }
  }
#endif
