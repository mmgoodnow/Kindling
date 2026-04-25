import AVFoundation
import Foundation

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
      loadingRequest.finishLoading(with: error)
      return
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      loadingRequest.finishLoading(
        with: NSError(domain: "StreamingAssetLoader", code: -1))
      return
    }

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
    }

    if let data, let dataRequest = loadingRequest.dataRequest {
      dataRequest.respond(with: data)
    }
    loadingRequest.finishLoading()
  }

  private func contentType(from response: HTTPURLResponse) -> String? {
    guard let mime = response.value(forHTTPHeaderField: "Content-Type") else { return nil }
    // Strip "; charset=..." etc. — AVFoundation wants a UTI or bare MIME.
    let mimeOnly = mime.split(separator: ";").first.map {
      String($0).trimmingCharacters(in: .whitespaces)
    }
    return mimeOnly ?? mime
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
