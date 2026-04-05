import SwiftUI

class UserSettings: ObservableObject {
  @AppStorage("kindleEmailAddress") var kindleEmailAddress: String = "example@kindle.com"
  @AppStorage("podibleRPCURL") var podibleRPCURL: String = ""
}
