import UIKit
import XCTest

/// A request that cannot be served, with the HTTP status the host sees.
struct AgentError: Error {
  var message: String
  var status = 400
}

/// Answers the host's requests with XCUITest. Every handler runs on the main thread.
///
/// Endpoints (JSON in and out, `ok` in every reply):
///   GET  /status                 agent version, device, which private APIs work
///   GET  /apps                   the active applications
///   GET  /tree?max_depth=&bundle_id=   the frontmost app's UI tree
///   POST /tap     {x, y, count, hold_ms}
///   POST /swipe   {from_x, from_y, to_x, to_y, duration_ms}
///   POST /type    {text}
///   POST /keys    {keys: [{key, modifiers: [command|shift|option|control]}]}
///   POST /button  {name}
///   POST /stop
final class Agent {
  /// Bumped whenever a request or reply changes; the host restarts an agent of another version.
  static let protocolVersion = 1
  static let springboard = "com.apple.springboard"
  /// Enough for any real screen; a runaway tree (a huge collection view) is cut here.
  static let maxElements = 3000

  private let build: String
  private let onStop: () -> Void
  /// Failures XCUITest records while a request runs; nil between requests.
  private var issues: [String]?
  private var bundleIDs: [pid_t: String] = [:]

  init(build: String, onStop: @escaping () -> Void) {
    self.build = build
    self.onStop = onStop
  }

  func capture(_ issue: XCTIssue) -> Bool {
    guard issues != nil else { return false }
    issues?.append(issue.compactDescription)
    return true
  }

  func handle(_ request: HTTPRequest) -> HTTPResponse {
    let started = Date()
    issues = []
    var response: HTTPResponse
    do {
      response = .json(try route(request).merging(["ok": true]) { $1 })
    } catch let error as AgentError {
      response = .json(["ok": false, "error": error.message], status: error.status)
    } catch {
      response = .json(["ok": false, "error": "\(error)"], status: 500)
    }
    if let issues, !issues.isEmpty, response.status == 200 {
      response = .json(["ok": false, "error": issues.joined(separator: "; ")], status: 500)
    }
    issues = nil
    NSLog("ISimAgent \(request.method) \(request.path) \(response.status) \(Int(-started.timeIntervalSinceNow * 1000)) ms")
    return response
  }

  private func route(_ request: HTTPRequest) throws -> [String: Any] {
    let body = request.json
    switch (request.method, request.path) {
    case ("GET", "/status"): return status()
    case ("GET", "/apps"): return ["apps": try activeApplications().map { ["pid": Int($0.pid), "bundle_id": $0.bundleID] }]
    case ("GET", "/tree"): return try tree(maxDepth: request.query["max_depth"].flatMap { Int($0) }, bundleID: request.query["bundle_id"])
    case ("POST", "/tap"): return try tap(body)
    case ("POST", "/swipe"): return try swipe(body)
    case ("POST", "/type"): return try type(body)
    case ("POST", "/keys"): return try keys(body)
    case ("POST", "/button"): return try button(body)
    case ("POST", "/stop"):
      // Reply first: the test finishes once the expectation is met.
      DispatchQueue.main.async(execute: onStop)
      return [:]
    default:
      throw AgentError(message: "unknown endpoint \(request.method) \(request.path)", status: 404)
    }
  }

  // MARK: Status and applications

  private func status() -> [String: Any] {
    let device = UIDevice.current
    let screen = UIScreen.main
    return [
      "version": Self.protocolVersion,
      "build": build,
      "name": device.name,
      "model": device.model,
      "system": device.systemVersion,
      "screen": [screen.bounds.width, screen.bounds.height],
      "scale": screen.scale,
      "private": [
        "events": ISimXCT.canSynthesizeEvents,
        "apps": ISimXCT.canListActiveApplications,
        "typing": ISimXCT.canTypeText,
      ],
    ]
  }

  struct ActiveApp {
    var pid: pid_t
    var bundleID: String
  }

  private func activeApplications() throws -> [ActiveApp] {
    guard ISimXCT.canListActiveApplications else {
      throw AgentError(message: "this Xcode's XCTest cannot list active applications", status: 501)
    }
    return ISimXCT.activeApplicationPIDs().compactMap { number in
      let pid = number.int32Value
      if let known = bundleIDs[pid] { return ActiveApp(pid: pid, bundleID: known) }
      guard let bundleID = try? ISimXCT.bundleIdentifier(forPID: pid) else { return nil }
      bundleIDs[pid] = bundleID
      return ActiveApp(pid: pid, bundleID: bundleID)
    }
  }

  /// The app the user sees: the active one that is not SpringBoard, or SpringBoard. SpringBoard alone is active
  /// on the home screen and while a system alert (which it owns) covers an app.
  private func frontmost() throws -> (XCUIApplication, ActiveApp) {
    let active = try activeApplications()
    let springboard = active.first { $0.bundleID == Self.springboard }
    let front = active.first { $0.bundleID != Self.springboard } ?? springboard
    guard let front else { throw AgentError(message: "no active application", status: 503) }
    return (XCUIApplication(bundleIdentifier: front.bundleID), front)
  }

  // MARK: UI tree

  private func tree(maxDepth: Int?, bundleID: String?) throws -> [String: Any] {
    settleKeyboard()
    let started = Date()
    let (app, active): (XCUIApplication, ActiveApp?)
    if let bundleID, !bundleID.isEmpty {
      (app, active) = (XCUIApplication(bundleIdentifier: bundleID), nil)
    } else {
      let front = try frontmost()
      (app, active) = (front.0, front.1)
    }
    let snapshot: XCUIElementSnapshot
    do {
      snapshot = try app.snapshot()
    } catch {
      throw AgentError(message: "cannot read the UI of \(active?.bundleID ?? bundleID ?? "the app"): \(error.localizedDescription)", status: 500)
    }
    var budget = Self.maxElements
    var root = node(snapshot, depth: 0, maxDepth: maxDepth, budget: &budget)
    if let active { root["pid"] = Int(active.pid) }
    return [
      "bundle_id": active?.bundleID ?? bundleID ?? "",
      "orientation": ISimXCT.interfaceOrientation(ofApplication: app).rawValue,
      "tree": root,
      "snapshot_ms": Int(-started.timeIntervalSinceNow * 1000),
    ]
  }

  private func node(_ snapshot: XCUIElementSnapshot, depth: Int, maxDepth: Int?, budget: inout Int) -> [String: Any] {
    budget -= 1
    let frame = snapshot.frame
    var node: [String: Any] = [
      "type": Self.typeName(snapshot.elementType),
      "frame": [frame.origin.x, frame.origin.y, frame.width, frame.height],
    ]
    if !snapshot.label.isEmpty { node["label"] = snapshot.label }
    if !snapshot.identifier.isEmpty { node["identifier"] = snapshot.identifier }
    if let value = snapshot.value {
      let text = "\(value)"
      if !text.isEmpty { node["value"] = text }
    }
    if let placeholder = snapshot.placeholderValue, !placeholder.isEmpty { node["placeholder"] = placeholder }
    if !snapshot.isEnabled { node["enabled"] = false }
    if snapshot.isSelected { node["selected"] = true }
    if ISimXCT.snapshot(snapshot, boolForKey: "hasKeyboardFocus") { node["focused"] = true }

    let children = snapshot.children
    if children.isEmpty { return node }
    if let maxDepth, depth >= maxDepth {
      node["truncated"] = true
      return node
    }
    var nodes: [[String: Any]] = []
    for child in children {
      guard budget > 0 else {
        node["truncated"] = true
        break
      }
      nodes.append(self.node(child, depth: depth + 1, maxDepth: maxDepth, budget: &budget))
    }
    node["children"] = nodes
    return node
  }

  // MARK: Touch

  private func tap(_ body: [String: Any]) throws -> [String: Any] {
    settleKeyboard()
    let point = try Self.point(body, "x", "y")
    let count = max(1, body["count"] as? Int ?? 1)
    let hold = Double(body["hold_ms"] as? Int ?? 60) / 1000
    let orientation = try? frontmost().0
    if ISimXCT.canSynthesizeEvents {
      try ISimXCT.tap(
        at: point, count: count, hold: hold,
        orientation: orientation.map(ISimXCT.interfaceOrientation(ofApplication:)) ?? .portrait)
      return ["method": "synthesized"]
    }
    // Public API: XCUITest waits for the app to go idle around the tap.
    let coordinate = Self.screenCoordinate(point)
    if hold >= 0.5 {
      coordinate.press(forDuration: hold)
    } else if count == 2 {
      coordinate.doubleTap()
    } else {
      for _ in 0..<count { coordinate.tap() }
    }
    return ["method": "xcuitest"]
  }

  private func swipe(_ body: [String: Any]) throws -> [String: Any] {
    settleKeyboard()
    let start = try Self.point(body, "from_x", "from_y")
    let end = try Self.point(body, "to_x", "to_y")
    let duration = Double(body["duration_ms"] as? Int ?? 300) / 1000
    let orientation = try? frontmost().0
    if ISimXCT.canSynthesizeEvents {
      try ISimXCT.swipe(
        from: start, to: end, duration: duration,
        orientation: orientation.map(ISimXCT.interfaceOrientation(ofApplication:)) ?? .portrait)
      return ["method": "synthesized"]
    }
    let distance = hypot(end.x - start.x, end.y - start.y)
    Self.screenCoordinate(start).press(
      forDuration: 0.05, thenDragTo: Self.screenCoordinate(end),
      withVelocity: XCUIGestureVelocity(rawValue: distance / max(duration, 0.05)), thenHoldForDuration: 0)
    return ["method": "xcuitest"]
  }

  /// A point of the screen in points, measured from SpringBoard, which always spans it.
  private static func screenCoordinate(_ point: CGPoint) -> XCUICoordinate {
    XCUIApplication(bundleIdentifier: springboard).coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: point.x, dy: point.y))
  }

  private static func point(_ body: [String: Any], _ x: String, _ y: String) throws -> CGPoint {
    guard let px = (body[x] as? NSNumber)?.doubleValue, let py = (body[y] as? NSNumber)?.doubleValue else {
      throw AgentError(message: "\(x) and \(y) are required")
    }
    return CGPoint(x: px, y: py)
  }

  // MARK: Keyboard and buttons

  private func type(_ body: [String: Any]) throws -> [String: Any] {
    guard let text = body["text"] as? String else { throw AgentError(message: "text is required") }
    try noteTyping()
    return ["method": try type(text)]
  }

  /// Typing reaches the app as a hardware keyboard, so iOS hides the software keyboard and brings it back
  /// about a second later, moving the layout twice. Reads of the screen and touches wait for it to come back,
  /// so they see (and hit) what the screen settles to; typing in a row does not wait in between.
  private var hiddenKeyboard: (app: XCUIApplication, pid: pid_t, typedAt: Date)?

  private func noteTyping() throws {
    if hiddenKeyboard != nil {
      hiddenKeyboard?.typedAt = Date()
    } else {
      let (app, active) = try frontmost()
      if Self.isKeyboardVisible(app) { hiddenKeyboard = (app, active.pid, Date()) }
    }
  }

  private func settleKeyboard() {
    guard let hidden = hiddenKeyboard else { return }
    hiddenKeyboard = nil
    // Querying an app that something covers (a system alert the typing brought up, such as "Allow Paste")
    // makes XCUITest handle the interruption, which takes many seconds.
    let inFront = { (try? self.frontmost().1.pid) == hidden.pid }
    // It goes a moment after the typing, if it goes at all, and is back within about a second.
    let gone = Self.wait(until: hidden.typedAt.addingTimeInterval(0.5)) { !inFront() || !Self.isKeyboardVisible(hidden.app) }
    if gone { _ = Self.wait(until: hidden.typedAt.addingTimeInterval(2)) { !inFront() || Self.isKeyboardVisible(hidden.app) } }
  }

  static func isKeyboardVisible(_ app: XCUIApplication) -> Bool {
    guard let keyboard = try? app.keyboards.firstMatch.snapshot() else { return false }
    return keyboard.frame.height > 0 && keyboard.frame.minY < UIScreen.main.bounds.maxY - 1
  }

  /// Polls on the main run loop; false when the deadline passed first.
  static func wait(until deadline: Date, for condition: () -> Bool) -> Bool {
    while !condition() {
      if Date() >= deadline { return false }
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    return true
  }

  /// Types into whatever has keyboard focus, any script.
  private func type(_ text: String) throws -> String {
    if ISimXCT.canTypeText {
      try ISimXCT.typeText(text, frequency: 60)
      return "synthesized"
    }
    try frontmost().0.typeText(text)
    return "xcuitest"
  }

  private static let namedKeys: [String: XCUIKeyboardKey] = [
    "return": .return, "enter": .enter, "escape": .escape, "delete": .delete, "tab": .tab, "space": .space,
    "forward_delete": .forwardDelete, "home": .home, "end": .end, "page_up": .pageUp, "page_down": .pageDown,
    "right": .rightArrow, "left": .leftArrow, "down": .downArrow, "up": .upArrow,
    "f1": .F1, "f2": .F2, "f3": .F3, "f4": .F4, "f5": .F5, "f6": .F6,
    "f7": .F7, "f8": .F8, "f9": .F9, "f10": .F10, "f11": .F11, "f12": .F12,
  ]

  /// Keys without modifiers that go as typed text: a key press of Delete, synthesized or through typeKey,
  /// leaves the field as it was (Xcode 27), while typing the character deletes.
  private static let typedKeys: [String: String] = [
    "return": "\n", "enter": "\n", "delete": "\u{7f}", "tab": "\t", "space": " ",
  ]

  private static let modifierFlags: [String: XCUIElement.KeyModifierFlags] = [
    "command": .command, "shift": .shift, "option": .option, "control": .control,
  ]

  private func keys(_ body: [String: Any]) throws -> [String: Any] {
    guard let keys = body["keys"] as? [[String: Any]] else { throw AgentError(message: "keys is required") }
    try noteTyping()
    var pending = ""
    for entry in keys {
      guard let name = entry["key"] as? String, !name.isEmpty else { throw AgentError(message: "every key needs a name") }
      guard Self.namedKeys[name] != nil || name.count == 1 else { throw AgentError(message: "unknown key \(name)") }
      var flags: XCUIElement.KeyModifierFlags = []
      for modifier in entry["modifiers"] as? [String] ?? [] {
        guard let flag = Self.modifierFlags[modifier] else { throw AgentError(message: "unknown modifier \(modifier)") }
        flags.insert(flag)
      }
      if flags.isEmpty, let text = Self.typedKeys[name] ?? (name.count == 1 ? name : nil) {
        pending += text
        continue
      }
      if !pending.isEmpty {
        _ = try type(pending)
        pending = ""
      }
      let key = Self.namedKeys[name]?.rawValue ?? name
      if ISimXCT.canPressKeys {
        try ISimXCT.pressKey(key, modifiers: flags.rawValue)
      } else {
        try frontmost().0.typeKey(key, modifierFlags: flags)
      }
    }
    if !pending.isEmpty { _ = try type(pending) }
    return [:]
  }

  private func button(_ body: [String: Any]) throws -> [String: Any] {
    settleKeyboard()
    let name = body["name"] as? String ?? ""
    let device = XCUIDevice.shared
    switch name {
    case "home":
      device.press(.home)
      // The app stays in front while it animates away; the next read should see the home screen.
      _ = Self.wait(until: Date(timeIntervalSinceNow: 2)) { (try? frontmost().1.bundleID) == Self.springboard }
    #if !targetEnvironment(simulator)
    case "volume_up":
      device.press(.volumeUp)
    case "volume_down":
      device.press(.volumeDown)
    #endif
    case "lock", "side":
      let selector = NSSelectorFromString("pressLockButton")
      guard device.responds(to: selector) else { throw AgentError(message: "this XCTest cannot press the side button", status: 501) }
      device.perform(selector)
    default:
      throw AgentError(message: "the agent cannot press \(name)", status: 501)
    }
    return [:]
  }

  // MARK: Element types

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

  private static func typeName(_ type: XCUIElement.ElementType) -> String {
    let raw = Int(type.rawValue)
    return raw < typeNames.count ? typeNames[raw] : "Type\(raw)"
  }
}
