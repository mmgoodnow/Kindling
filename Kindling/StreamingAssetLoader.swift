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
final class StreamingAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
  static let customScheme = "kindling-stream"

  private let httpURL: URL
  private let accessToken: String?
  private let urlSession: URLSession
  private let workQueue = DispatchQueue(label: "kindling.stream-loader", qos: .userInitiated)
  private var pendingTasks: [ObjectIdentifier: URLSessionDataTask] = [:]

  init(
    httpURL: URL,
    accessToken: String?,
    urlSession: URLSession = .shared
  ) {
    self.httpURL = httpURL
    self.accessToken = accessToken
    self.urlSession = urlSession
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
    var request = URLRequest(url: httpURL)
    request.httpMethod = "GET"
    if let accessToken, accessToken.isEmpty == false {
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }
    if let dataRequest = loadingRequest.dataRequest {
      let lower = dataRequest.requestedOffset
      // requestsAllDataToEndOfResource: AVFoundation wants everything from `lower` onward.
      let upper: Int64? =
        dataRequest.requestsAllDataToEndOfResource
        ? nil
        : lower + Int64(dataRequest.requestedLength) - 1
      let rangeValue: String
      if let upper {
        rangeValue = "bytes=\(lower)-\(upper)"
      } else {
        rangeValue = "bytes=\(lower)-"
      }
      request.setValue(rangeValue, forHTTPHeaderField: "Range")
    }

    let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.handleResponse(
        loadingRequest: loadingRequest,
        data: data,
        response: response,
        error: error
      )
    }

    workQueue.sync {
      pendingTasks[ObjectIdentifier(loadingRequest)] = task
    }
    task.resume()
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    workQueue.sync {
      let key = ObjectIdentifier(loadingRequest)
      pendingTasks[key]?.cancel()
      pendingTasks[key] = nil
    }
  }

  // MARK: - Response handling

  private func handleResponse(
    loadingRequest: AVAssetResourceLoadingRequest,
    data: Data?,
    response: URLResponse?,
    error: Error?
  ) {
    workQueue.sync {
      pendingTasks[ObjectIdentifier(loadingRequest)] = nil
    }

    if let error {
      #if DEBUG
        NSLog("[stream] task error: %@", error.localizedDescription)
      #endif
      loadingRequest.finishLoading(with: error)
      return
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      #if DEBUG
        NSLog("[stream] no http response")
      #endif
      loadingRequest.finishLoading(
        with: NSError(domain: "StreamingAssetLoader", code: -1))
      return
    }

    #if DEBUG
      NSLog(
        "[stream] response status=%d ct=%@ cl=%@ cr=%@ ar=%@ bytes=%d",
        httpResponse.statusCode,
        httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "nil",
        httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "nil",
        httpResponse.value(forHTTPHeaderField: "Content-Range") ?? "nil",
        httpResponse.value(forHTTPHeaderField: "Accept-Ranges") ?? "nil",
        data?.count ?? 0)
    #endif

    if (200..<300).contains(httpResponse.statusCode) == false {
      loadingRequest.finishLoading(
        with: NSError(
          domain: "StreamingAssetLoader",
          code: httpResponse.statusCode,
          userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"]
        ))
      return
    }

    if let info = loadingRequest.contentInformationRequest {
      info.contentType = contentType(from: httpResponse)
      info.contentLength = totalLength(from: httpResponse) ?? Int64(data?.count ?? 0)
      info.isByteRangeAccessSupported =
        httpResponse.statusCode == 206
        || httpResponse.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
      #if DEBUG
        NSLog(
          "[stream] info status=%d contentType=%@ contentLength=%lld byteRange=%@",
          httpResponse.statusCode,
          info.contentType ?? "nil",
          info.contentLength,
          info.isByteRangeAccessSupported ? "yes" : "no")
      #endif
    }

    if let data, let dataRequest = loadingRequest.dataRequest {
      dataRequest.respond(with: data)
    }
    loadingRequest.finishLoading()
  }

  /// `AVAssetResourceLoadingContentInformationRequest.contentType` expects
  /// a UTI string ("public.mp3"), not a MIME ("audio/mpeg"). Fall back to
  /// guessing from the URL's extension if the response header is missing
  /// or unmappable.
  private func contentType(from response: HTTPURLResponse) -> String? {
    let mimeHeader = response.value(forHTTPHeaderField: "Content-Type")
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
      // e.g. "bytes 0-1023/12345"
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
