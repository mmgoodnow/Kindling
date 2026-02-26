import SwiftUI

class UserSettings: ObservableObject {
  @AppStorage("ircNick") var ircNick: String = "happygolucky"
  @AppStorage("ircServer") var ircServer: String = "irc.irchighway.net"
  @AppStorage("ircPort") var ircPort: Int = 6667
  @AppStorage("ircChannel") var ircChannel: String = "#ebooks"
  @AppStorage("searchBot") var searchBot: String = "Search"
  @AppStorage("kindleEmailAddress") var kindleEmailAddress: String = "example@kindle.com"
  @AppStorage("podibleRPCURL") var podibleRPCURL: String = ""
  @AppStorage("podibleAPIKey") var podibleAPIKey: String = ""
}
