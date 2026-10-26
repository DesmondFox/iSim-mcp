// Test app for UI tools: login → list → detail, a text field for typing, buttons that trigger system alerts,
// and a lab screen (launch with -lab, or Open Lab after logging in) for gestures, shake, memory warnings,
// UserDefaults, locale, logs and a crash.
// Built without Xcode by `make test-app` (swiftc for the iOS Simulator, ad-hoc signed).

import CoreLocation
import os
import SwiftUI
import UserNotifications

@main
struct ISimTestApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @State private var user: String?

    var body: some View {
        if CommandLine.arguments.contains("-lab") {
            NavigationStack { LabView() }
        } else if let user {
            ItemsView(user: user) { self.user = nil }
        } else {
            LoginView { user = $0 }
        }
    }
}

struct LoginView: View {
    let onLogin: (String) -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome").font(.largeTitle).accessibilityAddTraits(.isHeader)
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("username")
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("password")
            if let error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("loginError")
            }
            Button("Log In") {
                if username.isEmpty || password != "secret" {
                    error = "Wrong username or password"
                } else {
                    onLogin(username)
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("loginButton")
        }
        .padding(24)
    }
}

struct Item: Identifiable, Hashable {
    let id: Int
    var title: String { "Item \(id)" }
}

struct ItemsView: View {
    let user: String
    let onLogout: () -> Void
    private let items = (1...40).map(Item.init)
    @State private var location = LocationPrompt()
    @State private var notificationStatus = "not asked"

    var body: some View {
        NavigationStack {
            List {
                Section("Signed in as \(user)") {
                    Button("Ask for Notifications") {
                        Task {
                            let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                            notificationStatus = granted == true ? "granted" : "denied"
                        }
                    }
                    .accessibilityIdentifier("askNotifications")
                    Text("Notifications: \(notificationStatus)").accessibilityIdentifier("notificationStatus")
                    Button("Ask for Location") { location.request() }
                        .accessibilityIdentifier("askLocation")
                    NavigationLink("Open Lab") { LabView() }.accessibilityIdentifier("openLab")
                }
                Section("Items") {
                    ForEach(items) { item in
                        NavigationLink(item.title, value: item).accessibilityIdentifier("item-\(item.id)")
                    }
                }
            }
            .navigationTitle("Items")
            .navigationDestination(for: Item.self) { DetailView(item: $0) }
            .toolbar {
                Button("Log Out", action: onLogout).accessibilityIdentifier("logoutButton")
            }
        }
    }
}

struct DetailView: View {
    let item: Item
    @State private var favorite = false
    @State private var note = ""
    @State private var count = 0

    var body: some View {
        Form {
            Text("Details of \(item.title)").accessibilityIdentifier("detailTitle")
            Toggle("Favorite", isOn: $favorite).accessibilityIdentifier("favorite")
            TextField("Note", text: $note).accessibilityIdentifier("note")
            Text("Note: \(note)").accessibilityIdentifier("noteEcho")
            Stepper("Count: \(count)", value: $count).accessibilityIdentifier("count")
        }
        .navigationTitle(item.title)
    }
}

@Observable
final class LocationPrompt: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    func request() {
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }
}

/// Everything the app reports also goes to stdout (launch_app capture_output) and the unified log (start_log_capture).
let log = Logger(subsystem: "dev.isimmcp.testapp", category: "lab")

func report(_ message: String) {
    print("ISimTestApp: \(message)")
    log.info("\(message, privacy: .public)")
}

extension Notification.Name {
    static let deviceDidShake = Notification.Name("ISimTestAppDeviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .deviceDidShake, object: nil) }
        super.motionEnded(motion, with: event)
    }
}

struct LabView: View {
    @AppStorage("launchCount") private var launches = 0
    @State private var greeting = UserDefaults.standard.string(forKey: "greeting") ?? "none"
    @State private var shakes = 0
    @State private var memoryWarnings = 0
    @State private var drag = "none"
    @State private var moves = 0
    @State private var zoom: CGFloat = 1
    @State private var rotation: Angle = .zero
    @State private var counted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Launches: \(launches)").accessibilityIdentifier("launches")
            HStack {
                Text("Greeting: \(greeting)").accessibilityIdentifier("greeting")
                Spacer()
                Button("Reload") { greeting = UserDefaults.standard.string(forKey: "greeting") ?? "none" }
                    .accessibilityIdentifier("reloadGreeting")
            }
            Text("Locale: \(Locale.current.identifier), language: \(Locale.preferredLanguages.first ?? "?")")
                .accessibilityIdentifier("locale")
            Text("Shakes: \(shakes)").accessibilityIdentifier("shakes")
            Text("Memory warnings: \(memoryWarnings)").accessibilityIdentifier("memoryWarnings")
            Text("Drag: \(drag)").accessibilityIdentifier("drag")
            Rectangle().fill(.blue.opacity(0.2)).frame(height: 160)
                .overlay(Text("Drag here"))
                .accessibilityIdentifier("dragArea")
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in moves += 1 }
                    .onEnded { value in
                        drag = "\(moves) moves from \(point(value.startLocation)) to \(point(value.location))"
                        report("drag \(drag)")
                        moves = 0
                    })
            Text(String(format: "Zoom: %.2f, rotation: %.0f°", zoom, rotation.degrees)).accessibilityIdentifier("zoom")
            Rectangle().fill(.green.opacity(0.2)).frame(height: 200)
                .overlay(Text("Pinch or rotate here"))
                .accessibilityIdentifier("pinchArea")
                .gesture(MagnifyGesture().onChanged { zoom = $0.magnification }
                    .simultaneously(with: RotateGesture().onChanged { rotation = $0.rotation }))
            Button("Crash") {
                report("crashing on purpose")
                fatalError("iSim test crash")
            }
            .accessibilityIdentifier("crashButton")
        }
        .padding()
        .navigationTitle("Lab")
        .onAppear {
            guard !counted else { return }
            counted = true
            launches += 1
            report("lab opened, launch \(launches)")
            let file = URL.documentsDirectory.appending(path: "hello.txt")
            if !FileManager.default.fileExists(atPath: file.path) {
                try? "Hello from iSim Test".write(to: file, atomically: true, encoding: .utf8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            shakes += 1
            report("shake \(shakes)")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            memoryWarnings += 1
            report("memory warning \(memoryWarnings)")
        }
    }

    private func point(_ point: CGPoint) -> String {
        "(\(Int(point.x)),\(Int(point.y)))"
    }
}
