import Foundation
import Kingfisher
import SwiftUI

struct AuthenticatedRemoteImage<Placeholder: View>: View {
  let url: URL?
  let rpcURLString: String
  let accessToken: String?
  let onSuccess: ((KFCrossPlatformImage) -> Void)?
  let placeholder: () -> Placeholder

  init(
    url: URL?,
    rpcURLString: String,
    accessToken: String?,
    onSuccess: ((KFCrossPlatformImage) -> Void)? = nil,
    @ViewBuilder placeholder: @escaping () -> Placeholder
  ) {
    self.url = url
    self.rpcURLString = rpcURLString
    self.accessToken = accessToken
    self.onSuccess = onSuccess
    self.placeholder = placeholder
  }

  var body: some View {
    if let url {
      configuredImage(for: url)
        .placeholder { placeholder() }
    } else {
      placeholder()
    }
  }

  private func configuredImage(for url: URL) -> KFImage {
    let image = KFImage.url(url)
      .onSuccess { result in
        onSuccess?(result.image)
      }
      .cancelOnDisappear(true)
      .resizable()

    guard
      let modifier = AuthenticatedRemoteImageRequest.modifier(
        for: url,
        rpcURLString: rpcURLString,
        accessToken: accessToken
      )
    else {
      return image
    }

    return image.requestModifier(modifier)
      .redirectHandler(
        AnyRedirectHandler { _, response, request, completion in
          completion(
            AuthenticatedRemoteImageRequest.redirectedRequest(
              request, from: response.url, rpcURLString: rpcURLString, accessToken: accessToken))
        })
  }
}

enum AuthenticatedRemoteImageRequest {
  static func modifier(
    for url: URL,
    rpcURLString: String,
    accessToken: String?
  ) -> AnyModifier? {
    guard let accessToken, accessToken.isEmpty == false else { return nil }
    guard shouldAuthorize(url: url, rpcURLString: rpcURLString) else { return nil }

    return AnyModifier { request in
      var request = request
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
      return request
    }
  }

  static func redirectedRequest(
    _ request: URLRequest, from sourceURL: URL?, rpcURLString: String, accessToken: String?
  ) -> URLRequest {
    var result = request
    // Never forward credentials to another origin, even if URLSession retained them.
    result.setValue(nil, forHTTPHeaderField: "Authorization")
    if let sourceURL, let destinationURL = request.url,
      shouldAuthorize(url: sourceURL, rpcURLString: rpcURLString),
      shouldAuthorize(url: destinationURL, rpcURLString: rpcURLString),
      let accessToken, !accessToken.isEmpty
    {
      result.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }
    return result
  }

  static func shouldAuthorize(url: URL, rpcURLString: String) -> Bool {
    guard let rpcURL = URL(string: rpcURLString) else { return false }
    let normalizedRPCURL = PodibleClient.normalizedRPCURL(from: rpcURL)
    var baseWebURL = normalizedRPCURL
    if baseWebURL.path.hasSuffix("/rpc") {
      baseWebURL.deleteLastPathComponent()
    }

    let sameScheme = url.scheme?.lowercased() == baseWebURL.scheme?.lowercased()
    let sameHost = url.host?.lowercased() == baseWebURL.host?.lowercased()
    let samePort = url.port == baseWebURL.port
    return sameScheme && sameHost && samePort
  }
}
