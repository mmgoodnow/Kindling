import Combine
import Foundation

enum LibraryDownloadKind {
  case ebook
  case audiobook
}

@MainActor
final class LibraryDownloadController: ObservableObject {
  @Published var errorMessage: String?
  @Published var remoteBookID: String?
  @Published var remoteProgress: Double?
  @Published var remoteKind: LibraryDownloadKind?
  @Published var localProgressByBookID: [String: Double] = [:]
  @Published var localBookIDs: Set<String> = []
}
