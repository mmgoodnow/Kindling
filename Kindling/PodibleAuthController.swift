import AuthenticationServices
import Foundation
import Security
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

@MainActor
final class PodibleAuthController: ObservableObject {
  static let callbackURL = URL(string: "kindling://auth/podible")!

  @Published private(set) var session: PodibleAppSession?
  @Published private(set) var isAuthenticating = false
  @Published var errorMessage: String?

  private let keychain = PodibleSessionKeychain()
  private let webAuthenticator = PodibleWebAuthenticator()

  var accessToken: String? { session?.accessToken }
  var isAuthenticated: Bool { accessToken?.isEmpty == false }
  var currentUserDescription: String? {
    session?.user.displayName ?? session?.user.id.map(String.init)
  }

  func refreshStoredSession(rpcURLString: String) async {
    let trimmed = rpcURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false, let rpcURL = URL(string: trimmed) else {
      session = nil
      errorMessage = nil
      return
    }

    let key = PodibleClient.sessionKey(for: rpcURL)
    guard let stored = try? keychain.loadSession(for: key) else {
      session = nil
      errorMessage = nil
      return
    }

    if stored.rpcURLKey != key {
      session = nil
      errorMessage = nil
      return
    }

    session = stored
    errorMessage = nil

    do {
      let client = PodibleClient(rpcURL: rpcURL, accessToken: stored.accessToken)
      let user = try await client.fetchCurrentUser()
      let refreshed = PodibleAppSession(
        rpcURLKey: key,
        accessToken: stored.accessToken,
        expiresAt: stored.expiresAt,
        expiresIn: stored.expiresIn,
        user: user
      )
      try keychain.saveSession(refreshed, for: key)
      session = refreshed
    } catch PodibleError.unauthorized {
      clearSession()
      try? keychain.deleteSession(for: key)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func signIn(rpcURLString: String) async {
    let trimmed = rpcURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false, let rpcURL = URL(string: trimmed) else {
      errorMessage = PodibleError.badURL.localizedDescription
      return
    }

    isAuthenticating = true
    errorMessage = nil
    defer { isAuthenticating = false }

    do {
      let client = PodibleClient(rpcURL: rpcURL, accessToken: nil)
      let authorizeURL = try await client.beginAppLogin(
        redirectURI: Self.callbackURL.absoluteString)
      let callbackURL = try await webAuthenticator.authenticate(
        authorizeURL: authorizeURL,
        callbackScheme: Self.callbackURL.scheme ?? "kindling"
      )
      let code = try loginCode(from: callbackURL)
      let exchange = try await client.exchangeLoginCode(code)
      let key = PodibleClient.sessionKey(for: rpcURL)
      let session = PodibleAppSession(
        rpcURLKey: key,
        accessToken: exchange.accessToken,
        expiresAt: exchange.expiresAt,
        expiresIn: exchange.expiresIn,
        user: exchange.user
      )
      try keychain.saveSession(session, for: key)
      self.session = session
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func logout(rpcURLString: String) async {
    let trimmed = rpcURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false, let rpcURL = URL(string: trimmed) else {
      clearSession()
      return
    }

    let key = PodibleClient.sessionKey(for: rpcURL)
    defer {
      try? keychain.deleteSession(for: key)
      clearSession()
    }

    guard let token = session?.accessToken, token.isEmpty == false else { return }
    do {
      let client = PodibleClient(rpcURL: rpcURL, accessToken: token)
      try await client.logout()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func clearSession() {
    session = nil
  }

  private func loginCode(from callbackURL: URL) throws -> String {
    guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
      let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
      code.isEmpty == false
    else {
      throw PodibleError.badResponse
    }
    return code
  }
}

struct PodibleAuthUser: Codable, Equatable {
  let id: Int?
  let email: String?
  let name: String?
  let username: String?
  let plexUsername: String?

  var displayName: String? {
    [name, username, plexUsername, email]
      .compactMap { $0 }
      .first(where: { $0.isEmpty == false })
  }
}

struct PodibleAppSession: Codable, Equatable {
  let rpcURLKey: String
  let accessToken: String
  let expiresAt: Date?
  let expiresIn: Int?
  let user: PodibleAuthUser
}

private enum PodibleSessionKeychainError: LocalizedError {
  case unhandledStatus(OSStatus)

  var errorDescription: String? {
    switch self {
    case .unhandledStatus(let status):
      return "Keychain access failed (\(status))."
    }
  }
}

private struct PodibleSessionKeychain {
  private let service = "com.bebopbeluga.kindling.podible-session"
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  func saveSession(_ session: PodibleAppSession, for key: String) throws {
    let data = try encoder.encode(session)
    var query = baseQuery(for: key)
    SecItemDelete(query as CFDictionary)
    query[kSecValueData as String] = data
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw PodibleSessionKeychainError.unhandledStatus(status)
    }
  }

  func loadSession(for key: String) throws -> PodibleAppSession? {
    var query = baseQuery(for: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw PodibleSessionKeychainError.unhandledStatus(status)
    }
    guard let data = item as? Data else { return nil }
    return try decoder.decode(PodibleAppSession.self, from: data)
  }

  func deleteSession(for key: String) throws {
    let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PodibleSessionKeychainError.unhandledStatus(status)
    }
  }

  private func baseQuery(for key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }
}

private final class PodibleWebAuthenticator: NSObject,
  ASWebAuthenticationPresentationContextProviding
{
  private var session: ASWebAuthenticationSession?

  func authenticate(authorizeURL: URL, callbackScheme: String) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(
        url: authorizeURL,
        callbackURLScheme: callbackScheme
      ) { callbackURL, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let callbackURL else {
          continuation.resume(throwing: PodibleError.badResponse)
          return
        }
        continuation.resume(returning: callbackURL)
      }
      session.prefersEphemeralWebBrowserSession = true
      session.presentationContextProvider = self
      self.session = session
      if session.start() == false {
        continuation.resume(
          throwing: PodibleError.server("Could not start Podible sign-in."))
      }
    }
  }

  #if os(macOS)
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
      NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
  #else
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
  #endif
}
