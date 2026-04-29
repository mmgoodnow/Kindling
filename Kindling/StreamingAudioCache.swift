import CryptoKit
import Foundation

final class StreamingAudioCache: @unchecked Sendable {
  struct CompletedFile: Sendable {
    let url: URL
    let suggestedFilename: String
    let fileSizeBytes: Int64
  }

  struct ActiveRange: Sendable, Equatable {
    let lower: Int64
    let upper: Int64
  }

  private struct Metadata: Codable {
    var sourceURLString: String
    var suggestedFilename: String
    var contentLength: Int64?
    var contentType: String?
    var ranges: [ByteRange]
  }

  private struct ByteRange: Codable, Equatable {
    var lower: Int64
    var upper: Int64
  }

  struct ResponseInfo {
    let contentLength: Int64?
    let contentType: String?
    let responseStartOffset: Int64
    let byteRangeAccessSupported: Bool
  }

  private static let folderName = "KindlingStreamCache"
  private static let chunkLength: Int64 = 2 * 1024 * 1024
  private static let maxCachedReadLength: Int64 = 8 * 1024 * 1024

  private let sourceURL: URL
  private let folderURL: URL
  private let dataURL: URL
  private let metadataURL: URL
  private let lock = NSLock()
  private var metadata: Metadata
  private var didReturnCompletion = false
  private var activeRanges: [ActiveRange] = []

  init(sourceURL: URL, suggestedFilename: String) throws {
    self.sourceURL = sourceURL
    let key = Self.cacheKey(for: sourceURL)
    let baseURL = try Self.ensureBaseDirectory()
    folderURL = baseURL.appendingPathComponent(key, isDirectory: true)
    dataURL = folderURL.appendingPathComponent("audio.data", isDirectory: false)
    metadataURL = folderURL.appendingPathComponent("metadata.json", isDirectory: false)

    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: folderURL.path) == false {
      try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }
    if fileManager.fileExists(atPath: dataURL.path) == false {
      fileManager.createFile(atPath: dataURL.path, contents: nil)
    }

    if let data = try? Data(contentsOf: metadataURL),
      let decoded = try? JSONDecoder().decode(Metadata.self, from: data),
      decoded.sourceURLString == sourceURL.absoluteString
    {
      metadata = decoded
    } else {
      let filename =
        suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? Self.defaultFilename(for: sourceURL)
        : suggestedFilename
      metadata = Metadata(
        sourceURLString: sourceURL.absoluteString,
        suggestedFilename: filename,
        contentLength: nil,
        contentType: nil,
        ranges: []
      )
      try saveMetadataLocked()
    }
  }

  var contentLength: Int64? {
    lock.withLock { metadata.contentLength }
  }

  var cachedByteCount: Int64 {
    lock.withLock {
      metadata.ranges.reduce(0) { $0 + max($1.upper - $1.lower, 0) }
    }
  }

  var isComplete: Bool {
    lock.withLock { isCompleteLocked }
  }

  func cachedData(offset: Int64, length: Int64) -> Data? {
    guard length > 0, length <= Self.maxCachedReadLength else { return nil }
    return lock.withLock {
      guard containsLocked(lower: offset, length: length) else { return nil }
      guard let handle = try? FileHandle(forReadingFrom: dataURL) else { return nil }
      defer { try? handle.close() }
      do {
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: Int(length))
      } catch {
        return nil
      }
    }
  }

  func responseInfo(from response: HTTPURLResponse, requestedOffset: Int64) -> ResponseInfo {
    lock.withLock {
      let parsedContentRange = Self.parseContentRange(response)
      let totalLength =
        parsedContentRange?.total
        ?? Self.int64Header("Content-Length", in: response)
      let responseStartOffset: Int64
      if let parsedContentRange {
        responseStartOffset = parsedContentRange.lower
      } else if response.statusCode == 200 {
        responseStartOffset = 0
      } else {
        responseStartOffset = requestedOffset
      }

      if let totalLength {
        metadata.contentLength = totalLength
      }
      if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
        metadata.contentType = contentType
      }
      try? saveMetadataLocked()

      let byteRangeAccessSupported =
        response.statusCode == 206
        || response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
      return ResponseInfo(
        contentLength: metadata.contentLength,
        contentType: metadata.contentType,
        responseStartOffset: responseStartOffset,
        byteRangeAccessSupported: byteRangeAccessSupported
      )
    }
  }

  func contentInformation() -> ResponseInfo? {
    lock.withLock {
      guard metadata.contentLength != nil || metadata.contentType != nil else { return nil }
      return ResponseInfo(
        contentLength: metadata.contentLength,
        contentType: metadata.contentType,
        responseStartOffset: 0,
        byteRangeAccessSupported: true
      )
    }
  }

  func write(_ data: Data, at offset: Int64) -> CompletedFile? {
    guard data.isEmpty == false else { return nil }
    return lock.withLock {
      guard let handle = try? FileHandle(forWritingTo: dataURL) else { return nil }
      defer { try? handle.close() }
      do {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        insertRangeLocked(ByteRange(lower: offset, upper: offset + Int64(data.count)))
        try saveMetadataLocked()
      } catch {
        return nil
      }
      return completedFileLocked(markReturned: true)
    }
  }

  func completedFile() -> CompletedFile? {
    lock.withLock { completedFileLocked(markReturned: false) }
  }

  func beginNetworkRange(lower: Int64, upper: Int64?) -> ActiveRange? {
    lock.withLock {
      let resolvedUpper = upper ?? metadata.contentLength
      guard let resolvedUpper, resolvedUpper > lower else { return nil }
      let range = ActiveRange(lower: lower, upper: resolvedUpper)
      activeRanges.append(range)
      return range
    }
  }

  func endNetworkRange(_ activeRange: ActiveRange?) {
    guard let activeRange else { return }
    lock.withLock {
      if let index = activeRanges.firstIndex(of: activeRange) {
        activeRanges.remove(at: index)
      }
    }
  }

  func fillAll(accessToken: String?, progress: @escaping @Sendable (Double) -> Void) async throws
    -> CompletedFile
  {
    if let completed = completedFile() {
      progress(1)
      return completed
    }

    if contentLength == nil {
      try await fetchAndCache(lower: 0, upperInclusive: 0, accessToken: accessToken)
    }

    while true {
      if let completed = completedFile() {
        progress(1)
        return completed
      }

      if let range = nextMissingRange(maxLength: Self.chunkLength) {
        try await fetchAndCache(
          lower: range.lower,
          upperInclusive: range.upper - 1,
          accessToken: accessToken
        )
        if let contentLength, contentLength > 0 {
          progress(min(max(Double(cachedByteCount) / Double(contentLength), 0), 1))
        }
      } else if hasActiveRanges {
        try await Task.sleep(nanoseconds: 150_000_000)
      } else {
        break
      }
    }

    guard let completed = completedFile() else {
      throw URLError(.cannotDecodeContentData)
    }
    progress(1)
    return completed
  }

  private func nextMissingRange(maxLength: Int64) -> ByteRange? {
    lock.withLock {
      guard let contentLength = metadata.contentLength, contentLength > 0 else { return nil }
      var cursor: Int64 = 0
      for range in coveredRangesLocked {
        if cursor < range.lower {
          return ByteRange(lower: cursor, upper: min(range.lower, cursor + maxLength))
        }
        cursor = max(cursor, range.upper)
        if cursor >= contentLength { return nil }
      }
      guard cursor < contentLength else { return nil }
      return ByteRange(lower: cursor, upper: min(contentLength, cursor + maxLength))
    }
  }

  private func fetchAndCache(lower: Int64, upperInclusive: Int64, accessToken: String?) async throws
  {
    let activeRange = beginNetworkRange(lower: lower, upper: upperInclusive + 1)
    defer { endNetworkRange(activeRange) }

    var request = URLRequest(url: sourceURL)
    request.httpMethod = "GET"
    request.setValue("bytes=\(lower)-\(upperInclusive)", forHTTPHeaderField: "Range")
    if let accessToken, accessToken.isEmpty == false {
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    let info = responseInfo(from: http, requestedOffset: lower)
    if http.statusCode == 200, lower > 0 {
      throw URLError(.badServerResponse)
    }
    _ = write(data, at: info.responseStartOffset)
  }

  private var hasActiveRanges: Bool {
    lock.withLock { activeRanges.isEmpty == false }
  }

  private var isCompleteLocked: Bool {
    guard let contentLength = metadata.contentLength, contentLength > 0 else { return false }
    return metadata.ranges.contains { $0.lower == 0 && $0.upper >= contentLength }
  }

  private func completedFileLocked(markReturned: Bool) -> CompletedFile? {
    guard isCompleteLocked else { return nil }
    if markReturned {
      guard didReturnCompletion == false else { return nil }
      didReturnCompletion = true
    }
    let length = metadata.contentLength ?? Int64((try? Data(contentsOf: dataURL).count) ?? 0)
    guard length > 0 else { return nil }
    return CompletedFile(
      url: dataURL,
      suggestedFilename: metadata.suggestedFilename,
      fileSizeBytes: length
    )
  }

  private func containsLocked(lower: Int64, length: Int64) -> Bool {
    let upper = lower + length
    return metadata.ranges.contains { $0.lower <= lower && upper <= $0.upper }
  }

  private func insertRangeLocked(_ newRange: ByteRange) {
    guard newRange.upper > newRange.lower else { return }
    var merged = newRange
    var output: [ByteRange] = []
    var didInsert = false

    for range in metadata.ranges {
      if range.upper < merged.lower {
        output.append(range)
      } else if merged.upper < range.lower {
        if didInsert == false {
          output.append(merged)
          didInsert = true
        }
        output.append(range)
      } else {
        merged.lower = min(merged.lower, range.lower)
        merged.upper = max(merged.upper, range.upper)
      }
    }

    if didInsert == false {
      output.append(merged)
    }
    metadata.ranges = output
  }

  private var coveredRangesLocked: [ByteRange] {
    var ranges = metadata.ranges
    ranges.append(
      contentsOf: activeRanges.map { ByteRange(lower: $0.lower, upper: $0.upper) })
    ranges.sort {
      if $0.lower == $1.lower { return $0.upper < $1.upper }
      return $0.lower < $1.lower
    }

    var output: [ByteRange] = []
    for range in ranges {
      guard range.upper > range.lower else { continue }
      if var last = output.last, range.lower <= last.upper {
        last.upper = max(last.upper, range.upper)
        output[output.count - 1] = last
      } else {
        output.append(range)
      }
    }
    return output
  }

  private func saveMetadataLocked() throws {
    let data = try JSONEncoder().encode(metadata)
    try data.write(to: metadataURL, options: [.atomic])
  }

  private static func ensureBaseDirectory() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let target = base.appendingPathComponent(folderName, isDirectory: true)
    if FileManager.default.fileExists(atPath: target.path) == false {
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }
    return target
  }

  private static func cacheKey(for sourceURL: URL) -> String {
    let digest = SHA256.hash(data: Data(sourceURL.absoluteString.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func defaultFilename(for sourceURL: URL) -> String {
    let name = sourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "audiobook" : name
  }

  private static func int64Header(_ name: String, in response: HTTPURLResponse) -> Int64? {
    guard let value = response.value(forHTTPHeaderField: name) else { return nil }
    return Int64(value)
  }

  private static func parseContentRange(_ response: HTTPURLResponse) -> (
    lower: Int64, upper: Int64, total: Int64?
  )? {
    guard let value = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
    let parts = value.split(separator: " ")
    guard parts.count == 2 else { return nil }
    let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1)
    guard rangeAndTotal.count == 2 else { return nil }
    let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
    guard bounds.count == 2,
      let lower = Int64(bounds[0]),
      let upperInclusive = Int64(bounds[1])
    else { return nil }
    let total = rangeAndTotal[1] == "*" ? nil : Int64(rangeAndTotal[1])
    return (lower, upperInclusive + 1, total)
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
