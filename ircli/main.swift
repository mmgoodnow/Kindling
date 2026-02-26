import Foundation

@main
struct CLI {
  static func main() async {
    do {
      try await run()
    } catch {
      fputs("error: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  private static func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2, args[0] == "remote" else {
      printUsage()
      return
    }

    let env = loadRemoteEnv()
    guard
      let base = env.baseURL,
      let key = env.apiKey,
      let url = URL(string: base)
    else {
      throw LazyLibrarianError.notConfigured
    }
    let client = PodibleKindlingClient(rpcURL: url, apiKey: key)

    switch args[1] {
    case "find":
      let query = args.dropFirst(2).joined(separator: " ")
      guard query.isEmpty == false else {
        print("find requires a query")
        return
      }
      let results = try await client.searchBooks(query: query)
      for book in results {
        print("\(book.id): \(book.title) — \(book.author) [\(book.status.rawValue)]")
      }
    case "add":
      guard args.count >= 3 else {
        print("add requires an Open Library key")
        return
      }
      let id = args[2]
      let added = try await client.addLibraryBook(
        openLibraryKey: id, titleHint: nil, authorHint: nil)
      print("Added \(added.title) by \(added.author) [\(added.status.rawValue)]")
    default:
      printUsage()
    }
  }

  private static func printUsage() {
    print(
      """
      Usage:
        ircli remote find <query>
        ircli remote add <openlibrary-key>
      Env/.env: PODIBLE_RPC_URL, PODIBLE_API_KEY
      """)
  }

  private struct RemoteEnv {
    let baseURL: String?
    let apiKey: String?
  }

  private static func loadRemoteEnv() -> RemoteEnv {
    let env = ProcessInfo.processInfo.environment
    var base = env["PODIBLE_RPC_URL"]
    var key = env["PODIBLE_API_KEY"]

    if let data = try? String(contentsOfFile: ".env") {
      data.split(separator: "\n").forEach { line in
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        if parts[0] == "PODIBLE_RPC_URL" && base == nil { base = parts[1] }
        if parts[0] == "PODIBLE_API_KEY" && key == nil { key = parts[1] }
      }
    }

    return RemoteEnv(baseURL: base, apiKey: key)
  }
}
