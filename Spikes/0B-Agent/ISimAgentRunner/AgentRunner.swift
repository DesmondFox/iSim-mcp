import UIKit
import XCTest

/// The agent is a UI test that never finishes: it serves XCUITest over HTTP until `/stop`.
final class AgentRunner: XCTestCase {

  func testRunAgent() throws {
    continueAfterFailure = true
    let port = UInt16(ProcessInfo.processInfo.environment["ISIM_AGENT_PORT"] ?? "") ?? 8100
    let stopped = expectation(description: "agent stopped")
    let agent = Agent(onStop: { stopped.fulfill() })
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
}

final class Agent {
  private let onStop: () -> Void
  private var currentBundleID = "com.apple.springboard"

  init(onStop: @escaping () -> Void) {
    self.onStop = onStop
  }

  func handle(_ request: HTTPRequest) -> HTTPResponse {
    let started = Date()
    let body = request.json
    let response: HTTPResponse
    switch (request.method, request.path) {
    case ("GET", "/status"):
      let device = UIDevice.current
      response = .json([
        "ok": true, "name": device.name, "model": device.model, "system": device.systemVersion,
        "current_app": currentBundleID,
      ])
    case ("POST", "/launch"):
      response = launch(body, relaunch: true)
    case ("POST", "/activate"):
      response = launch(body, relaunch: false)
    case ("POST", "/tap"):
      response = tap(body)
    case ("POST", "/type"):
      app(body["bundle_id"] as? String).typeText(body["text"] as? String ?? "")
      response = .json(["ok": true])
    case ("POST", "/button"):
      response = button(body["name"] as? String ?? "")
    case ("GET", "/tree"):
      response = tree(bundleID: request.query["bundle_id"], format: request.query["format"] ?? "compact")
    case ("POST", "/stop"):
      onStop()
      response = .json(["ok": true])
    default:
      response = .json(["ok": false, "error": "unknown endpoint \(request.method) \(request.path)"], status: 404)
    }
    NSLog("ISimAgent \(request.method) \(request.path) \(Int(-started.timeIntervalSinceNow * 1000)) ms")
    return response
  }

  private func app(_ bundleID: String?) -> XCUIApplication {
    XCUIApplication(bundleIdentifier: bundleID ?? currentBundleID)
  }

  private func launch(_ body: [String: Any], relaunch: Bool) -> HTTPResponse {
    guard let bundleID = body["bundle_id"] as? String else {
      return .json(["ok": false, "error": "bundle_id is required"], status: 400)
    }
    let target = XCUIApplication(bundleIdentifier: bundleID)
    relaunch ? target.launch() : target.activate()
    currentBundleID = bundleID
    return .json(["ok": true, "state": target.state.rawValue])
  }

  private func tap(_ body: [String: Any]) -> HTTPResponse {
    if let x = body["x"] as? Double, let y = body["y"] as? Double {
      // Screen coordinates in points, measured from SpringBoard which always spans the screen.
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
      return .json(["ok": true])
    }
    let target = app(body["bundle_id"] as? String)
    let query = target.descendants(matching: .any)
    let element: XCUIElement
    if let identifier = body["identifier"] as? String {
      element = query.matching(identifier: identifier).firstMatch
    } else if let label = body["label"] as? String {
      element = query.matching(NSPredicate(format: "label == %@", label)).firstMatch
    } else {
      return .json(["ok": false, "error": "x/y, identifier or label is required"], status: 400)
    }
    guard element.waitForExistence(timeout: 5) else {
      return .json(["ok": false, "error": "element not found"], status: 404)
    }
    let frame = element.frame
    element.tap()
    return .json(["ok": true, "frame": [frame.origin.x, frame.origin.y, frame.width, frame.height]])
  }

  private func button(_ name: String) -> HTTPResponse {
    switch name {
    case "home": XCUIDevice.shared.press(.home)
    #if !targetEnvironment(simulator)
    case "volume_up": XCUIDevice.shared.press(.volumeUp)
    case "volume_down": XCUIDevice.shared.press(.volumeDown)
    #endif
    default: return .json(["ok": false, "error": "unknown button \(name)"], status: 400)
    }
    return .json(["ok": true])
  }

  private func tree(bundleID: String?, format: String) -> HTTPResponse {
    let started = Date()
    do {
      let snapshot = try app(bundleID).snapshot()
      let elapsed = Int(-started.timeIntervalSinceNow * 1000)
      if format == "json" {
        return .json(["ok": true, "snapshot_ms": elapsed, "tree": node(snapshot)])
      }
      var lines: [String] = []
      compact(snapshot, depth: 0, into: &lines)
      return .json(["ok": true, "snapshot_ms": elapsed, "tree": lines.joined(separator: "\n")])
    } catch {
      return .json(["ok": false, "error": "\(error)"], status: 500)
    }
  }

  private func node(_ s: XCUIElementSnapshot) -> [String: Any] {
    var n: [String: Any] = [
      "type": typeName(s.elementType),
      "frame": [s.frame.origin.x, s.frame.origin.y, s.frame.width, s.frame.height],
      "enabled": s.isEnabled,
    ]
    if !s.identifier.isEmpty { n["identifier"] = s.identifier }
    if !s.label.isEmpty { n["label"] = s.label }
    if let value = s.value { n["value"] = "\(value)" }
    if !s.children.isEmpty { n["children"] = s.children.map(node) }
    return n
  }

  private func compact(_ s: XCUIElementSnapshot, depth: Int, into lines: inout [String]) {
    // Anonymous containers carry no information for an agent: hoist their children.
    if s.elementType == .other, s.label.isEmpty, s.identifier.isEmpty, s.value == nil {
      for child in s.children { compact(child, depth: depth, into: &lines) }
      return
    }
    var line = String(repeating: "  ", count: depth) + "[\(typeName(s.elementType))]"
    if !s.label.isEmpty { line += " \"\(s.label)\"" }
    if !s.identifier.isEmpty { line += " id=\(s.identifier)" }
    if let value = s.value, !"\(value)".isEmpty { line += " value=\"\(value)\"" }
    let f = s.frame
    line += String(format: " (%.0f,%.0f %.0f×%.0f)", f.origin.x, f.origin.y, f.width, f.height)
    lines.append(line)
    for child in s.children { compact(child, depth: depth + 1, into: &lines) }
  }

  private static let typeNames = [
    "Any", "Other", "Application", "Group", "Window", "Sheet", "Drawer", "Alert", "Dialog", "Button",
    "RadioButton", "RadioGroup", "CheckBox", "DisclosureTriangle", "PopUpButton", "ComboBox", "MenuButton",
    "ToolbarButton", "Popover", "Keyboard", "Key", "NavigationBar", "TabBar", "TabGroup", "Toolbar", "StatusBar",
    "Table", "TableRow", "TableColumn", "Outline", "OutlineRow", "Browser", "CollectionView", "Slider",
    "PageIndicator", "ProgressIndicator", "ActivityIndicator", "SegmentedControl", "Picker", "PickerWheel",
    "Switch", "Toggle", "Link", "Image", "Icon", "SearchField", "ScrollView", "ScrollBar", "StaticText",
    "TextField", "SecureTextField", "DatePicker", "TextView", "Menu", "MenuItem", "MenuBar", "MenuBarItem", "Map",
    "WebView", "IncrementArrow", "DecrementArrow", "Timeline", "RatingIndicator", "ValueIndicator", "SplitGroup",
    "Splitter", "RelevanceIndicator", "ColorWell", "HelpTag", "Matte", "DockItem", "Ruler", "RulerMarker", "Grid",
    "LevelIndicator", "Cell", "LayoutArea", "LayoutItem", "Handle", "Stepper", "Tab", "TouchBar", "StatusItem",
  ]

  private func typeName(_ type: XCUIElement.ElementType) -> String {
    let raw = Int(type.rawValue)
    return raw < Self.typeNames.count ? Self.typeNames[raw] : "Type\(raw)"
  }
}
