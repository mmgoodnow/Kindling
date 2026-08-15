import Foundation

struct PlaybackIdentity: Hashable, Sendable {
  let canonicalID: String
  let podibleID: String?
  let manifestationID: Int?
  private let legacyResumeIDs: [String]

  init(
    canonicalID: String,
    aliases: [String] = [],
    podibleID: String? = nil,
    manifestationID: Int? = nil
  ) {
    self.canonicalID = canonicalID
    self.podibleID = podibleID
    self.manifestationID = manifestationID
    self.legacyResumeIDs = Self.normalized(aliases)
      .filter { $0 != canonicalID }
  }

  init(
    openLibraryWorkID: String?,
    podibleID: String,
    manifestationID: Int?
  ) {
    let openLibraryBase = Self.nonEmpty(openLibraryWorkID)
    let canonicalID = Self.manifestationID(base: podibleID, manifestationID: manifestationID)

    self.canonicalID = canonicalID
    self.podibleID = podibleID
    self.manifestationID = manifestationID
    self.legacyResumeIDs = Self.normalized(
      openLibraryBase.map {
        [Self.manifestationID(base: $0, manifestationID: manifestationID)]
      } ?? []
    )
    .filter { $0 != canonicalID }
  }

  init(
    restoring resumeID: String,
    aliases: [String] = [],
    podibleID: String?,
    manifestationID: Int?
  ) {
    let resolvedManifestationID = manifestationID ?? Self.manifestationID(in: resumeID)
    let canonicalID =
      Self.nonEmpty(podibleID).map {
        Self.manifestationID(base: $0, manifestationID: resolvedManifestationID)
      } ?? resumeID

    self.canonicalID = canonicalID
    self.podibleID = Self.nonEmpty(podibleID)
    self.manifestationID = resolvedManifestationID
    self.legacyResumeIDs = Self.normalized([resumeID] + aliases)
      .filter { $0 != canonicalID }
  }

  var allResumeIDs: [String] {
    [canonicalID]
  }

  var migrationResumeIDs: [String] {
    let scopedIDs = Self.normalized([canonicalID] + legacyResumeIDs)
    return Self.normalized(scopedIDs + scopedIDs.compactMap(Self.fallbackResumeID(for:)))
  }

  func matches(_ resumeID: String) -> Bool {
    canonicalID == resumeID
  }

  private static func manifestationID(base: String, manifestationID: Int?) -> String {
    guard let manifestationID else { return base }
    return "\(base)#manifestation-\(manifestationID)"
  }

  static func manifestationID(in resumeID: String) -> Int? {
    guard let range = resumeID.range(of: "#manifestation-") else { return nil }
    return Int(resumeID[range.upperBound...])
  }

  private static func fallbackResumeID(for resumeID: String) -> String? {
    guard let range = resumeID.range(of: "#manifestation-") else {
      return nil
    }
    let legacyResumeID = String(resumeID[..<range.lowerBound])
    guard legacyResumeID.isEmpty == false else { return nil }
    return legacyResumeID
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
