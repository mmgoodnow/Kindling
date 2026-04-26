import CryptoKit
import Foundation

enum PodibleTranscriptCache {
  private static let folderName = "podible-transcripts"

  static func cacheKey(for url: URL) -> String {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func load(cacheKey: String) -> PodibleTranscript? {
    guard let url = fileURL(for: cacheKey),
      let data = try? Data(contentsOf: url)
    else { return nil }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode(PodibleTranscript.self, from: data)
  }

  static func store(_ data: Data, cacheKey: String) {
    guard let folder = folderURL() else { return }
    try? FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("\(cacheKey).json")
    try? data.write(to: url, options: .atomic)
  }

  private static func fileURL(for cacheKey: String) -> URL? {
    folderURL()?.appendingPathComponent("\(cacheKey).json")
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
