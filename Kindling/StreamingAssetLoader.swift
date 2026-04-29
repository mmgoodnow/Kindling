import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Bridges `AVAssetResourceLoader` to a plain HTTPS URL with a Bearer
/// token, so `AVPlayer` can stream audio that requires `Authorization`
/// headers (which `AVPlayer(url:)` cannot supply directly).
///
/// AVFoundation only invokes the resource-loader delegate when the asset's
/// URL uses a *custom* scheme (e.g. `kindling-stream://`). Use
/// `Self.proxyURL(for:)` to convert your real HTTPS URL into a custom-scheme
/// URL that triggers the delegate; the loader translates back to HTTPS for
/// every range request.
///
/// Important: each loading request is served by a dedicated `URLSession`
/// with a `URLSessionDataDelegate`, NOT a one-shot `dataTask(with:
/// completionHandler:)`. The completion-handler form buffers the entire
/// response in memory before returning — fine for a 2-byte probe, fatal for
/// `bytes=0-` against a multi-hundred-MB audio file. The delegate form
/// streams chunks as they arrive, which is what AVFoundation expects.
final class StreamingAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
  static let customScheme = "kindling-stream"

  private let httpURL: URL
  private let accessToken: String?
  private let cache: StreamingAudioCache?
  private let onCacheCompleted: (@Sendable (StreamingAudioCache.CompletedFile) -> Void)?
  private let workQueue = DispatchQueue(label: "kindling.stream-loader", qos: .userInitiated)
  private var contexts: [ObjectIdentifier: RequestContext] = [:]

  init(
    httpURL: URL,
    accessToken: String?,
    cache: StreamingAudioCache? = nil,
    onCacheCompleted: (@Sendable (StreamingAudioCache.CompletedFile) -> Void)? = nil
  ) {
    self.httpURL = httpURL
    self.accessToken = accessToken
    self.cache = cache
    self.onCacheCompleted = onCacheCompleted
    super.init()
  }

  /// Returns a URL with the custom scheme so AVFoundation routes loading
  /// through this delegate. AVFoundation requires an "unknown" scheme to
  /// skip its built-in HTTP handling.
  static func proxyURL(for httpURL: URL) -> URL? {
    var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false)
    components?.scheme = customScheme
    return components?.url
  }

  // MARK: - AVAssetResourceLoaderDelegate

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    let context = RequestContext(
      httpURL: httpURL,
      accessToken: accessToken,
      cache: cache,
      loadingRequest: loadingRequest,
      onCacheCompleted: onCacheCompleted,
      onFinish: { [weak self] key in
        self?.workQueue.sync { _ = self?.contexts.removeValue(forKey: key) }
      }
    )
    workQueue.sync {
      contexts[ObjectIdentifier(loadingRequest)] = context
    }
    context.start()
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    workQueue.sync {
      let key = ObjectIdentifier(loadingRequest)
      contexts[key]?.cancel()
      contexts[key] = nil
    }
  }
}

// MARK: - Per-request context

/// Owns a single `AVAssetResourceLoadingRequest`, the matching
/// `URLSession`, and incrementally streams response bytes back to the
/// loading request.
private final class RequestContext: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let httpURL: URL
  private let accessToken: String?
  private let cache: StreamingAudioCache?
  private let loadingRequest: AVAssetResourceLoadingRequest
  private let onCacheCompleted: (@Sendable (StreamingAudioCache.CompletedFile) -> Void)?
  private let onFinish: (ObjectIdentifier) -> Void
  private let session: URLSession
  private let queue: OperationQueue
  private var task: URLSessionDataTask?
  private var fulfilledContentInformation = false
  private var nextWriteOffset: Int64?
  private var activeNetworkRange: StreamingAudioCache.ActiveRange?

  init(
    httpURL: URL,
    accessToken: String?,
    cache: StreamingAudioCache?,
    loadingRequest: AVAssetResourceLoadingRequest,
    onCacheCompleted: (@Sendable (StreamingAudioCache.CompletedFile) -> Void)?,
    onFinish: @escaping (ObjectIdentifier) -> Void
  ) {
    self.httpURL = httpURL
    self.accessToken = accessToken
    self.cache = cache
    self.loadingRequest = loadingRequest
    self.onCacheCompleted = onCacheCompleted
    self.onFinish = onFinish
    self.queue = OperationQueue()
    self.queue.maxConcurrentOperationCount = 1
    self.session = URLSession(
      configuration: .default,
      delegate: nil,
      delegateQueue: queue
    )
    super.init()
  }

  func start() {
    if respondFromCacheIfPossible() {
      return
    }

    var request = URLRequest(url: httpURL)
    request.httpMethod = "GET"
    if let accessToken, accessToken.isEmpty == false {
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }
    if let dataRequest = loadingRequest.dataRequest {
      let lower = dataRequest.requestedOffset
      let rangeHeader: String
      if dataRequest.requestsAllDataToEndOfResource {
        rangeHeader = "bytes=\(lower)-"
        activeNetworkRange = cache?.beginNetworkRange(lower: lower, upper: cache?.contentLength)
      } else {
        let upper = lower + Int64(dataRequest.requestedLength) - 1
        rangeHeader = "bytes=\(lower)-\(upper)"
        activeNetworkRange = cache?.beginNetworkRange(lower: lower, upper: upper + 1)
      }
      request.setValue(rangeHeader, forHTTPHeaderField: "Range")
    }

    #if DEBUG
      let kind: String
      if loadingRequest.dataRequest == nil {
        kind = "info-only"
      } else if loadingRequest.dataRequest?.requestsAllDataToEndOfResource == true {
        kind = "all"
      } else {
        kind =
          "range \(loadingRequest.dataRequest!.requestedOffset)+\(loadingRequest.dataRequest!.requestedLength)"
      }
      NSLog("[stream] request kind=%@ url=%@", kind, httpURL.absoluteString)
    #endif

    // Use a delegate-based data task so we receive bytes incrementally
    // instead of waiting for the whole response.
    let task = session.dataTask(with: request)
    task.delegate = self
    self.task = task
    task.resume()
  }

  func cancel() {
    task?.cancel()
    session.invalidateAndCancel()
  }

  // MARK: URLSessionDataDelegate

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let httpResponse = response as? HTTPURLResponse else {
      finish(with: NSError(domain: "StreamingAssetLoader", code: -1))
      completionHandler(.cancel)
      return
    }

    #if DEBUG
      NSLog(
        "[stream] response status=%d ct=%@ cl=%@ cr=%@ ar=%@",
        httpResponse.statusCode,
        httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "nil",
        httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "nil",
        httpResponse.value(forHTTPHeaderField: "Content-Range") ?? "nil",
        httpResponse.value(forHTTPHeaderField: "Accept-Ranges") ?? "nil")
    #endif

    if (200..<300).contains(httpResponse.statusCode) == false {
      finish(
        with: NSError(
          domain: "StreamingAssetLoader",
          code: httpResponse.statusCode,
          userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"]
        ))
      completionHandler(.cancel)
      return
    }

    fulfillContentInformation(from: httpResponse)
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    if let offset = nextWriteOffset {
      if let completed = cache?.write(data, at: offset) {
        onCacheCompleted?(completed)
      }
      nextWriteOffset = offset + Int64(data.count)
    }
    loadingRequest.dataRequest?.respond(with: data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error {
      // URLSession reports cancellation via NSURLErrorCancelled; that's
      // expected when AVFoundation tells us to drop a request, so don't
      // treat it as a real error.
      let nsError = error as NSError
      let isCancelled =
        nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
      if isCancelled {
        finishCleanup()
      } else {
        finish(with: error)
      }
      return
    }
    finish(with: nil)
  }

  // MARK: Helpers

  private func fulfillContentInformation(from response: HTTPURLResponse) {
    let cacheInfo = cache?.responseInfo(
      from: response,
      requestedOffset: loadingRequest.dataRequest?.requestedOffset ?? 0
    )
    if activeNetworkRange == nil,
      let dataRequest = loadingRequest.dataRequest,
      dataRequest.requestsAllDataToEndOfResource,
      let contentLength = cacheInfo?.contentLength
    {
      activeNetworkRange = cache?.beginNetworkRange(
        lower: cacheInfo?.responseStartOffset ?? dataRequest.requestedOffset,
        upper: contentLength
      )
    }
    nextWriteOffset = cacheInfo?.responseStartOffset ?? loadingRequest.dataRequest?.requestedOffset
    guard let info = loadingRequest.contentInformationRequest, fulfilledContentInformation == false
    else { return }
    info.contentType = contentType(from: response, cacheInfo: cacheInfo)
    info.contentLength = cacheInfo?.contentLength ?? totalLength(from: response) ?? 0
    info.isByteRangeAccessSupported =
      cacheInfo?.byteRangeAccessSupported
      ?? (response.statusCode == 206
        || response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes")
    fulfilledContentInformation = true
    #if DEBUG
      NSLog(
        "[stream] info contentType=%@ contentLength=%lld byteRange=%@",
        info.contentType ?? "nil",
        info.contentLength,
        info.isByteRangeAccessSupported ? "yes" : "no")
    #endif
  }

  private func respondFromCacheIfPossible() -> Bool {
    guard let cache, let dataRequest = loadingRequest.dataRequest else { return false }
    guard dataRequest.requestsAllDataToEndOfResource == false else { return false }
    let requestedLength = Int64(dataRequest.requestedLength)
    guard
      let data = cache.cachedData(offset: dataRequest.requestedOffset, length: requestedLength)
    else { return false }

    if let cacheInfo = cache.contentInformation(),
      let info = loadingRequest.contentInformationRequest
    {
      info.contentType = contentType(from: cacheInfo)
      info.contentLength = cacheInfo.contentLength ?? 0
      info.isByteRangeAccessSupported = true
    }
    dataRequest.respond(with: data)
    loadingRequest.finishLoading()
    finishCleanup()
    return true
  }

  private func finish(with error: Error?) {
    if let error {
      #if DEBUG
        NSLog("[stream] task error: %@", error.localizedDescription)
      #endif
      loadingRequest.finishLoading(with: error)
    } else {
      loadingRequest.finishLoading()
    }
    finishCleanup()
  }

  private func finishCleanup() {
    cache?.endNetworkRange(activeNetworkRange)
    activeNetworkRange = nil
    onFinish(ObjectIdentifier(loadingRequest))
    session.finishTasksAndInvalidate()
  }

  /// `AVAssetResourceLoadingContentInformationRequest.contentType` expects
  /// a UTI string ("public.mp3"), not a MIME ("audio/mpeg"). Fall back to
  /// guessing from the URL's extension if the response header is missing
  /// or unmappable.
  private func contentType(
    from response: HTTPURLResponse,
    cacheInfo: StreamingAudioCache.ResponseInfo? = nil
  ) -> String? {
    let mimeHeader = cacheInfo?.contentType ?? response.value(forHTTPHeaderField: "Content-Type")
    return contentType(fromMIMEHeader: mimeHeader)
  }

  private func contentType(from cacheInfo: StreamingAudioCache.ResponseInfo) -> String? {
    contentType(fromMIMEHeader: cacheInfo.contentType)
  }

  private func contentType(fromMIMEHeader mimeHeader: String?) -> String? {
    if let mimeHeader {
      let mimeOnly =
        mimeHeader
        .split(separator: ";")
        .first
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        ?? mimeHeader
      if let type = UTType(mimeType: mimeOnly) {
        return type.identifier
      }
    }
    let ext = httpURL.pathExtension.lowercased()
    if ext.isEmpty == false, let type = UTType(filenameExtension: ext) {
      return type.identifier
    }
    return mimeHeader
  }

  /// Parses the total resource length from `Content-Range: bytes start-end/total`
  /// (a 206 response) or `Content-Length` (a 200 response).
  private func totalLength(from response: HTTPURLResponse) -> Int64? {
    if let contentRange = response.value(forHTTPHeaderField: "Content-Range") {
      if let slash = contentRange.lastIndex(of: "/") {
        let totalSubstring = contentRange[contentRange.index(after: slash)...]
        if totalSubstring != "*", let total = Int64(totalSubstring) {
          return total
        }
      }
    }
    if let contentLengthString = response.value(forHTTPHeaderField: "Content-Length"),
      let contentLength = Int64(contentLengthString)
    {
      return contentLength
    }
    return nil
  }
}
