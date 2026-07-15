import Foundation

struct PlaybackIdentity: Hashable, Sendable {
  let canonicalID: String
  private let explicitAliases: [String]

  init(canonicalID: String, aliases: [String] = []) {
    self.canonicalID = canonicalID
    self.explicitAliases = Self.normalized([canonicalID] + aliases)
      .filter { $0 != canonicalID }
  }

  init(
    openLibraryWorkID: String?,
    podibleID: String,
    manifestationID: Int?
  ) {
    let openLibraryBase = Self.nonEmpty(openLibraryWorkID)
    let canonicalBase = openLibraryBase ?? podibleID
    let canonicalID = Self.manifestationID(base: canonicalBase, manifestationID: manifestationID)
    var aliases = [canonicalID]

    if let openLibraryBase {
      aliases.append(openLibraryBase)
      aliases.append(Self.manifestationID(base: openLibraryBase, manifestationID: manifestationID))
    }

    aliases.append(podibleID)
    aliases.append(Self.manifestationID(base: podibleID, manifestationID: manifestationID))

    self.canonicalID = canonicalID
    self.explicitAliases = Self.normalized(aliases)
      .filter { $0 != canonicalID }
  }

  var allResumeIDs: [String] {
    Self.normalized([canonicalID] + explicitAliases)
      .flatMap { [$0] + Self.fallbackResumeIDs(for: $0) }
      .reduce(into: []) { uniqueIDs, candidate in
        if uniqueIDs.contains(candidate) == false {
          uniqueIDs.append(candidate)
        }
      }
  }

  func matches(_ resumeID: String) -> Bool {
    allResumeIDs.contains(resumeID)
  }

  private static func manifestationID(base: String, manifestationID: Int?) -> String {
    guard let manifestationID else { return base }
    return "\(base)#manifestation-\(manifestationID)"
  }

  private static func fallbackResumeIDs(for resumeID: String) -> [String] {
    guard let range = resumeID.range(of: "#manifestation-") else {
      return []
    }
    let legacyResumeID = String(resumeID[..<range.lowerBound])
    guard legacyResumeID.isEmpty == false else { return [] }
    return [legacyResumeID]
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, value.isEmpty == false else { return nil }
    return value
  }

  private static func normalized(_ resumeIDs: [String]) -> [String] {
    resumeIDs.reduce(into: []) { uniqueIDs, candidate in
      guard candidate.isEmpty == false else { return }
      if uniqueIDs.contains(candidate) == false {
        uniqueIDs.append(candidate)
      }
    }
  }
}
