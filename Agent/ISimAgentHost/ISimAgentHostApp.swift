import SwiftUI

// Empty host: XCUITest needs a target application, the agent itself lives in the UI-test runner.
@main
struct ISimAgentHostApp: App {
  var body: some Scene {
    WindowGroup {
      Text("iSim-mcp agent host")
    }
  }
}
