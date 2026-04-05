import Foundation
import Kingfisher
import SwiftUI

struct AuthenticatedRemoteImage<Placeholder: View>: View {
  let url: URL?
  let rpcURLString: String
  let accessToken: String?
  let placeholder: () -> Placeholder

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
      .cancelOnDisappear(true)
      .resizable()

    guard let accessToken, accessToken.isEmpty == false else {
      return image
    }
    guard shouldAuthorize(url: url) else {
      return image
    }

    return image.requestModifier { request in
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }
  }

  private func shouldAuthorize(url: URL) -> Bool {
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
