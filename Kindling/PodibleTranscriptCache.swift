import Foundation

enum PodibleTranscriptCache {
  private static let folderName = "podible-transcripts"

  static func load(assetID: Int) -> PodibleTranscript? {
    guard let url = fileURL(for: assetID),
      let data = try? Data(contentsOf: url)
    else { return nil }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode(PodibleTranscript.self, from: data)
  }

  static func store(_ data: Data, assetID: Int) {
    guard let folder = folderURL() else { return }
    try? FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("\(assetID).json")
    try? data.write(to: url, options: .atomic)
  }

  private static func fileURL(for assetID: Int) -> URL? {
    folderURL()?.appendingPathComponent("\(assetID).json")
  }

  private static func folderURL() -> URL? {
    let fm = FileManager.default
    guard
      let base = try? fm.url(
        for: .cachesDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    else { return nil }
    return base.appendingPathComponent(folderName, isDirectory: true)
  }
}
