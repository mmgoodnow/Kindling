import Foundation
import Observation

enum LibraryDownloadKind {
  case ebook
  case audiobook
}

@MainActor
@Observable
final class LibraryDownloadController {
  var errorMessage: String?
  var remoteBookID: String?
  var remoteProgress: Double?
  var remoteKind: LibraryDownloadKind?
  var localProgressByBookID: [String: Double] = [:]
  var localBookIDs: Set<String> = []
}
