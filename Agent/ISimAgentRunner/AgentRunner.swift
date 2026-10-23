import XCTest

/// The agent is a UI test that never finishes: it serves XCUITest over HTTP until `/stop`.
final class AgentRunner: XCTestCase {
  private var agent: Agent?

  func testRunAgent() throws {
    continueAfterFailure = true
    let environment = ProcessInfo.processInfo.environment
    let port = UInt16(environment["ISIM_AGENT_PORT"] ?? "") ?? 8100
    let stopped = expectation(description: "agent stopped")
    let agent = Agent(build: environment["ISIM_AGENT_BUILD"] ?? "", onStop: { stopped.fulfill() })
    self.agent = agent
    let server = try HTTPServer(port: port) { request in
      // Requests arrive on the listener queue; XCUITest must run on the main thread, which
      // `wait(for:)` keeps spinning.
      DispatchQueue.main.sync { agent.handle(request) }
    }
    server.start()
    NSLog("ISimAgent listening on \(port)")
    wait(for: [stopped], timeout: 365 * 24 * 3600)
    server.stop()
  }

  /// XCUITest reports a failed interaction (no element has keyboard focus, the app is not running) as a test
  /// failure. The request that caused it answers with the failure instead, and the test itself goes on.
  override func record(_ issue: XCTIssue) {
    if agent?.capture(issue) == true { return }
    super.record(issue)
  }
}
