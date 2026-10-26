# iSim-mcp

MCP server in Swift that lets an AI agent (Claude Code, Cursor, …) drive **iOS simulators and physical iPhones/iPads**: create, boot, clone and erase simulators, install, launch and inspect apps, take screenshots and record video, set up the environment — dark mode, Dynamic Type, status bar, location, permissions, Face ID, pasteboard, language, push notifications (simulated or through APNs) — use the app: read the screen's accessibility tree, tap, swipe, drag, pinch, type and answer system alerts, on simulators and iPhones alike — and look inside it: its logs and console output, crash reports, container files and UserDefaults. See [PLAN.md](PLAN.md) for the design and what is next.

Requires macOS with **Xcode 27 or newer**. No Python, Node or third-party device tools: everything goes through `simctl`, `devicectl`, private CoreSimulator APIs loaded at runtime for simulator input and accessibility (`Sources/SimBridge`), and on iPhones an XCUITest agent the server builds and runs itself (`Agent/`).

## Install

```bash
make install            # swift build -c release → ~/.local/bin/isim-mcp, agent sources → ~/.local/share/isim-mcp/Agent
```

Connect to Claude Code:

```bash
claude mcp add isim -- ~/.local/bin/isim-mcp
```

Debug with MCP Inspector:

```bash
npx @modelcontextprotocol/inspector ~/.local/bin/isim-mcp
```

## Tools

| Toolset | Tools |
|---|---|
| core | `doctor`, `set_active_device`, `ui_agent` |
| devices | `list_devices`, `boot_device`, `shutdown_device`, `reboot_device`, `open_simulator_app`, `list_runtimes`, `create_device`, `erase_device`, `delete_device`, `clone_device`, `rename_device` |
| apps | `list_apps`, `get_app_info`, `install_app`, `uninstall_app`, `launch_app`, `terminate_app`, `open_url`, `list_processes`, `get_app_container`, `send_memory_warning` |
| screen | `screenshot`, `get_screen_info`, `start_recording`, `stop_recording`, `add_media` |
| ui | `describe_ui`, `find_elements`, `describe_point`, `tap`, `swipe`, `type_text`, `press_key`, `press_button`, `wait_for`, `handle_system_alert`, `set_orientation`, `touch_path`, `multi_touch`, `scroll_until_visible`, `shake` |
| system | `configure_ui`, `set_permission`, `set_location`, `simulate_route`, `override_status_bar`, `biometrics`, `set_pasteboard`, `get_pasteboard`, `send_push`, `set_locale`, `icloud_sync` |
| data | `list_container_files`, `read_container_file`, `write_container_file`, `read_user_defaults`, `write_user_defaults`, `keychain` |
| logs | `start_log_capture`, `read_log_capture`, `stop_log_capture`, `query_logs`, `list_crash_reports`, `get_crash_report` |
| advanced | `simctl_raw`, `devicectl_raw`, `post_darwin_notification`, `spawn_process` |

Every device tool takes an optional `device` (UDID or name). Without it the server uses the active device (`set_active_device`), otherwise the only booted simulator or connected iPhone. `erase_device` and `delete_device` always need an explicit `device`.

`screenshot` returns a JPEG downscaled to 1024 px by default and says how image pixels map to points; `format=png max_dimension=0` gives the full-resolution PNG, `return=path` only saves a file.

Options: `--toolsets core,devices,apps,screen,ui` (default) or `all`, `--team-id` (signs the UI agent for iPhones; also `ISIM_TEAM_ID`), `--apns-key-path` and `--apns-key-id` (real pushes, see below; also `ISIM_APNS_KEY_PATH`, `ISIM_APNS_KEY_ID`), `--log-level`, `--list-tools`. Logs go to stderr; stdout carries only JSON-RPC. The `system`, `data`, `logs` and `advanced` toolsets are off by default; enable what you need, e.g. for screenshot preparation and debugging:

```bash
claude mcp add isim -- ~/.local/bin/isim-mcp --toolsets core,devices,apps,screen,ui,system,data,logs
```

## Using an app

`describe_ui` lists what is on screen, one line per element, in points:

```
"iSim Test" (pid 75337), 402×874 pt, 4 element(s):
[heading] "Welcome" (133,356 137×41)
[text_field] value="Username" id=username (24,412 354×34)
[secure_text_field] value="Password" id=password (24,462 354×34)
[button] "Log In" id=loginButton (166,512 70×34)
```

`tap`, `type_text`, `swipe`, `find_elements` and `wait_for` take an `element` selector — `identifier`, `label` (whole label, case-insensitive), `label_contains`, `value`, `role`, `index` — or coordinates in points. A login then reads: `type_text(text: "alex", element: {identifier: "username"})`, `type_text(text: "secret", element: {identifier: "password"})`, `tap(element: {label: "Log In"})`, `wait_for(condition: exists, element: {label: "Items"})`.

- Apps expose their UI tree only if accessibility was on in the simulator when they started. The server switches it on in `boot_device`, `launch_app` and the first UI tool; an app started before that shows no elements until it is relaunched with `launch_app` (the error says so).
- On a simulator `type_text` types Latin letters, digits and punctuation with the simulator's hardware keyboard; other text (Cyrillic, emoji) is pasted with Cmd+V and stays on the simulator's pasteboard. Flutter apps read the pasteboard themselves on Cmd+V, which iOS refuses, so when the field does not change `type_text` long-presses it and taps Paste in the edit menu. The pasted text goes where the long press puts the cursor. On an iPhone the agent types any script directly.
- Flutter: a widget's `Key` does not reach the accessibility tree; for `identifier` selectors wrap the widget in `Semantics(identifier: ...)`. A text field's label is its hint and is gone once the field has text, so select a filled field by `role` (`secure_text_field` for a password) and `index`.
- `handle_system_alert` reads and answers permission prompts. accept/deny know the English button labels and otherwise go by position. On iPhones it also answers alerts and sheets inside apps that XCUITest marks as such, like iOS's "Save Password?" after a login.
- `swipe(direction: up)` moves the finger up, which scrolls a list towards its end.
- `make test-app` builds a small SwiftUI app (`dev.isimmcp.testapp`) with a login, a list, a detail screen and permission prompts to try the tools on, plus a lab screen (launch it with `args: ["-lab"]`) for gestures, shake, memory warnings, UserDefaults, locale, logs and a crash button; `make test-app-device TEAM=<team id> DEVICE=<udid>` builds the same app for an iPhone (`dev.isimmcp.testapp.<team id>`).

### On an iPhone: the UI agent

UI tools on an iPhone go through an XCUITest runner on the phone (`Agent/`). The first UI tool builds it with `xcodebuild` and starts it: about 10 s, or 4 s once the build is cached in `~/Library/Application Support/iSim-mcp/agent`. It keeps running until the server exits. `ui_agent` shows it, starts it ahead of time, rebuilds or stops it. Typical times on an iPhone 14 Plus: `describe_ui` 0.3–0.6 s, a tap on an element 0.8 s, `type_text` into a field 3 s.

- The phone needs Developer Mode, **Settings → Developer → Enable UI Automation**, and must stay unlocked.
- The agent is signed by a development team: `team_id` of `ui_agent`, `--team-id`, the team used last, or the only team signed in to Xcode. With several teams the first UI tool asks to pick one. A free Apple ID's Personal Team works; its profiles last 7 days and the server rebuilds the agent when one has expired. The first time, trust the certificate on the phone: Settings → General → VPN & Device Management.
- Typing reaches the app as a hardware keyboard, so iOS hides the software keyboard and brings it back a second later; the agent waits for that before the next screen read or tap.
- Debug builds of Flutter apps do not start on an iPhone without Flutter tooling attached; use a profile or release build. Profile builds ask for local network access on first launch, and an app that reads the pasteboard itself (Flutter's Cmd+V) gets an "Allow Paste" prompt: `type_text(method: paste)` says so, and `handle_system_alert(accept)` lets the paste through.
- Home screen icons come without frames, so open apps with `launch_app` rather than by tapping icons.
- On a simulator `ui_agent start` moves its UI tools from the built-in simulator bridge to the agent, a fallback if the bridge breaks with a new Xcode; `ui_agent stop` moves them back.

A typical screenshot setup on a simulator: `configure_ui(appearance: dark)`, `override_status_bar(preset: screenshot)`, `set_location(...)`, `set_permission(action: grant, ...)`, then `launch_app` and `screenshot`.

### Gestures

`touch_path` moves one finger through points, `dt_ms` apart: drag and drop, drawing, sliders; repeat a point with a `dt_ms` to hold before dragging (reordering a list). `multi_touch` pinches (`pinch_out` zooms in, `pinch_in` out) and rotates around a point or an element, or follows two fingers' points. `scroll_until_visible` swipes until an element is on screen and stops when the list ends. `shake` sends the Shake Gesture (simulators). Simulators pass pinches to apps but not rotation (the angle arrives undefined), so `multi_touch` refuses `rotate` there.

## Logs, video and app data

- **App output:** `launch_app(capture_output: true)` keeps the app's stdout and stderr (`print`, `NSLog`) in a job; `read_log_capture` reads what is new since the last read (or from a `cursor`, with `grep`), `stop_log_capture` ends it and terminates the app. Works on simulators and iPhones.
- **Unified log (simulators):** `start_log_capture` streams `os_log`/`Logger`/`NSLog` entries of an app, process, subsystem or predicate into a job; `query_logs` returns the last minutes at once. Reading an iPhone's unified log needs root, so on iPhones use the app's output instead.
- **Video (simulators):** `start_recording` → `stop_recording` writes a QuickTime movie to `~/Library/Caches/iSim-mcp/recordings` (or `path`) and returns its duration and size. iPhones have no screen recording for developer tools.
- **Crash reports:** `list_crash_reports` lists an app's crashes (simulator apps' reports live on the Mac, an iPhone's are copied from it), `get_crash_report` shows the exception, termination reason, the message the code left and the crashed thread's stack.
- **Container files:** `list_container_files`, `read_container_file` (property lists as JSON, text as text, PNG/JPEG as an image, `save_path` for databases) and `write_container_file` work on the data container or an app group. On iPhones only development builds of your apps are reachable.
- **UserDefaults:** `read_user_defaults` reads an app's domain or a suite. `write_user_defaults` (simulators) sets or removes a key through the simulator's `defaults`, so the running app sees it at once. On iPhones, override a default for one run with `launch_app(args: ["-key", "value"])`.
- **Simulator extras:** `set_locale` (language and region; the simulator reboots in a few seconds), `keychain` (trust a CA for a debugging proxy, reset), `icloud_sync`, `clone_device` (a snapshot of a shut-down simulator), `send_memory_warning`.
- Jobs write to `~/Library/Caches/iSim-mcp/jobs`; all jobs stop when the server exits, and a recording still gets its file finished.

## Push notifications

`send_push` delivers a simulated push to a simulator app with no setup (`mode: local`, the default on simulators). For real pushes through Apple's servers (`mode: apns`, the default on iPhones; also background, VoIP and Live Activity pushes) start the server with an APNs auth key from your Apple Developer account and pass the app's device token:

```bash
claude mcp add isim -- ~/.local/bin/isim-mcp --toolsets core,devices,apps,screen,ui,system \
  --team-id AB12CD34EF --apns-key-path ~/keys/AuthKey_XYZ123.p8 --apns-key-id XYZ123
```

The key stays with the server: it never appears in tool parameters or results. `environment: production` targets TestFlight and App Store builds.

## Physical devices

- Developer Mode on, device paired with this Mac, unlocked while you work with it.
- Apps must be built for the device and signed with your team.
- Booting, shutting down, erasing and deleting are not available on physical devices; `reboot_device` works (the phone then waits for its passcode).
- Simulator only: permissions without the prompt, status bar overrides, Face ID / Touch ID, adding photos, simulated push, app container paths on the Mac, screen recording, the unified log, writing UserDefaults, language, keychain, shake, cloning, processes inside the device.
- On both: UI tools (through the UI agent on iPhones, see above), appearance and Dynamic Type, location and routes, orientation, pasteboard, app info and processes, the app's stdout and stderr, crash reports, container files, reading UserDefaults, Darwin notifications, APNs pushes.
- `send_memory_warning` on an iPhone goes through `devicectl`, which fails with "No such file or directory" on iOS 27.0.1; simulators get memory warnings reliably.
- Screenshots, UI trees (Settings shows the account name and the Wi-Fi network), app and process lists, crash report lists and the pasteboard of a personal phone go to the AI agent — keep that in mind.

## Development

```bash
make build
make test               # unit tests; devices are mocked via ProcessRunning
make test-app           # the SwiftUI test app for UI tools → .build/TestApp/ISimTestApp.app
make test-app-device TEAM=AB12CD34EF DEVICE=<udid>   # the same app for an iPhone
```

Layout: `Sources/ProcessKit` (async process runner with timeouts and cancellation), `DeviceCore` (models, device resolution, capability matrix, UI elements and selectors, background jobs, crash report parsing), `SimctlBackend`, `DevicectlBackend`, `SimBridge` (Objective-C: CoreSimulator, XPC to the simulator's `dtuhidd` HID daemon, accessibility through AccessibilityPlatformTranslation), `SimBridgeBackend` (input and UI tree on top of it), `AgentBackend` (builds and runs the UI agent, talks to it over HTTP through usbmuxd), `APNsBackend` (token-signed HTTP/2 requests to APNs), `ISimMCP` (tools, registry, router), `isim-mcp` (CLI entry point). `Agent/` is the agent's Xcode project: an empty host app and a UI-test runner serving XCUITest over HTTP. `Spikes/` holds the phase 0 prototypes and the Flutter report.
