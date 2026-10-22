// Test app for UI tools: login → list → detail, a text field for typing, buttons that trigger system alerts.
// Built without Xcode by `make test-app` (swiftc for the iOS Simulator, ad-hoc signed).

import CoreLocation
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
        if let user {
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
