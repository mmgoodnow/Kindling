import Foundation

struct BuildMetadata: Decodable, Equatable, Sendable {
  let buildTimestamp: String
  let configuration: String
  let commitSHA: String
  let shortSHA: String
  let branch: String
  let author: String
  let commitTimestamp: String
  let commitSubject: String
  let isDirty: Bool

  static let current = load()

  static func load(from bundle: Bundle = .main) -> BuildMetadata? {
    guard
      let url = bundle.url(forResource: "BuildMetadata", withExtension: "plist"),
      let data = try? Data(contentsOf: url)
    else {
      return nil
    }

    return decode(data)
  }

  static func decode(_ data: Data) -> BuildMetadata? {
    try? PropertyListDecoder().decode(BuildMetadata.self, from: data)
  }

  static func appVersion(from bundle: Bundle = .main) -> String {
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    switch (version, build) {
    case (.some(let version), .some(let build)):
      return "\(version) (\(build))"
    case (.some(let version), .none):
      return version
    case (.none, .some(let build)):
      return build
    case (.none, .none):
      return "Unavailable"
    }
  }

  var commitDescription: String {
    "\(shortSHA)\(isDirty ? " + local changes" : "")"
  }

  var formattedBuildTimestamp: String {
    Self.format(timestamp: buildTimestamp)
  }

  var formattedCommitTimestamp: String {
    Self.format(timestamp: commitTimestamp)
  }

  private static func format(timestamp: String) -> String {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: timestamp) else {
      return timestamp
    }

    return date.formatted(date: .abbreviated, time: .shortened)
  }
}
