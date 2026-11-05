# iSim-mcp

**Let your AI agent use your iOS app the way a tester would, on simulators and on real iPhones.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![Xcode 27+](https://img.shields.io/badge/Xcode-27%2B-147EFB.svg)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138.svg)

iSim-mcp is an [MCP](https://modelcontextprotocol.io) server for Claude Code, Cursor, VS Code, Codex and any other MCP client. With it your agent can:

- **run your app**: create and boot simulators, install, launch and deep-link into apps, on a simulator or a connected iPhone;
- **see the screen**: screenshots, plus the accessibility tree as compact text, so it knows what each button and field is called;
- **use the app**: tap, type in any language, swipe, drag, pinch, and answer permission prompts;
- **set the scene**: dark mode, Dynamic Type, a clean status bar, GPS location and routes, permissions, Face ID, language, push notifications;
- **find out what went wrong**: the app's console output, the unified log, crash reports, files in the app's container and its UserDefaults.

It is a single Swift binary on top of Apple's own tools. No Node, Python, idb or WebDriverAgent to install.

> *"Install build/MyApp.app on an iPhone 17 simulator, sign in as test@example.com and check that the order list loads. If it crashes, show me why."*

## Why iSim-mcp

- **Real iPhones work like simulators.** The same tools read the screen, tap and type on a phone. For that the server builds a small XCUITest agent, signs it with your team (a free Apple ID will do), installs and starts it, all on the first UI call.
- **The agent reads the screen as text.** `describe_ui` returns one line per element, so the agent taps "Log In" by its label or identifier instead of guessing pixels. That costs far fewer tokens than screenshots and keeps working when the layout moves.
- **Fast on simulators.** Input goes straight to the simulator's HID service and the screen is read through CoreSimulator: a tap on an element takes about 0.2 s, reading a screen 30–40 ms. Nothing to build or install in the simulator.
- **Any language, including Flutter.** Cyrillic, emoji and other non-Latin text are typed through the pasteboard on simulators, with a fallback for Flutter fields, and natively on iPhones.
- **Built for debugging.** It captures the app's `print` output and the unified log (also from a USB-connected iPhone, without root), explains crash reports and reads or writes the app's files and UserDefaults.
- **Careful with your devices.** 44 of the 71 tools are on by default; settings, data, logs and raw `simctl` access are opt-in. Erasing and deleting need an explicit device, and a physical iPhone is never erased.

## Quick start

### 1. Requirements

- A Mac with **Xcode 27 or newer** selected (`xcode-select -p`) and at least one iOS simulator runtime.
- For a real iPhone, a few one-time steps: see [Real iPhones](#real-iphones).

### 2. Install

```bash
git clone https://github.com/DesmondFox/iSim-mcp.git
cd iSim-mcp
make install
```

This builds a release binary into `~/.local/bin/isim-mcp` and copies the UI agent's sources to `~/.local/share/isim-mcp/Agent`. `make uninstall` removes both.

### 3. Connect your MCP client

**Claude Code**

```bash
claude mcp add isim -- ~/.local/bin/isim-mcp
```

This adds it to the current project; `claude mcp add --scope user isim -- ~/.local/bin/isim-mcp` adds it to all of them.

<details>
<summary><b>Cursor, Claude Desktop, Windsurf and other clients with an <code>mcpServers</code> config</b></summary>

Cursor: `~/.cursor/mcp.json`. Claude Desktop: `~/Library/Application Support/Claude/claude_desktop_config.json`. Use the full path to the binary, `~` is not expanded:

```json
{
  "mcpServers": {
    "isim": {
      "command": "/Users/you/.local/bin/isim-mcp",
      "args": []
    }
  }
}
```

</details>

<details>
<summary><b>VS Code (GitHub Copilot)</b></summary>

`.vscode/mcp.json` in your project, or **MCP: Open User Configuration** for all projects:

```json
{
  "servers": {
    "isim": {
      "type": "stdio",
      "command": "/Users/you/.local/bin/isim-mcp",
      "args": []
    }
  }
}
```

</details>

<details>
<summary><b>Codex CLI</b></summary>

```bash
codex mcp add isim -- ~/.local/bin/isim-mcp
```

or in `~/.codex/config.toml`:

```toml
[mcp_servers.isim]
command = "/Users/you/.local/bin/isim-mcp"
args = []
```

</details>

### 4. Try it

Restart the client and ask:

> *"Run the isim doctor."*

`doctor` checks Xcode, simulator runtimes, the private frameworks UI tools need, connected iPhones (Developer Mode, lock state) and code signing identities, and says what to fix. Then:

> *"Boot an iPhone simulator, open Settings and take a screenshot."*

## What you can ask

| You say | What happens |
|---|---|
| "Sign in with the test account and check that the feed loads" | `launch_app`, `describe_ui`, `type_text` and `tap` by label, `wait_for` the next screen |
| "Take App Store screenshots of the main screens in dark mode" | `configure_ui(appearance: dark)`, `override_status_bar(preset: screenshot)`, `screenshot` |
| "Does onboarding survive German and the largest text size?" | `set_locale(language: de)`, `configure_ui(content_size: accessibility-extra-extra-extra-large)`, a walk through the screens |
| "The app crashes on my iPhone when I open the map. Find out why." | reproduce with UI tools, `list_crash_reports`, `get_crash_report`, `query_logs` |
| "Grant location, drive the Freeway route and record a video" | `set_permission`, `simulate_route`, `start_recording` / `stop_recording` |
| "Send this push and check that tapping it opens the order" | `send_push`, then UI tools on the notification and the app |
| "Turn on the `newCheckout` flag and relaunch" | `write_user_defaults`, `launch_app` |
| "What did the app print while I logged in?" | `launch_app(capture_output: true)`, `read_log_capture` |

Some of these need toolsets that are off by default (`system`, `data`, `logs`): see [Toolsets](#toolsets).

## How it compares

iSim-mcp is for driving and debugging an iOS app that is already built, on simulators and real iPhones alike. Other MCP servers cover Android or building projects. Here is how they line up on iOS:

| | iSim-mcp | [MobileBuildMCP][mbm]<br><sub>ex-XcodeBuildMCP</sub> | [ios-simulator-mcp][ism] | [mobile-mcp][mm] | [Appium MCP][am] | [Maestro MCP][mae] | [Xcode MCP][xc]<br><sub>Apple</sub> |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| What you install | one binary | Node or Homebrew | Node, idb (Python) | Node | Node, Java, WDA | Java, Maestro CLI | comes with Xcode |
| Create, boot, erase simulators | ✅ | ⚠️ no create | ❌ | ❌ | ⚠️ boot | ❌ | ⚠️ boot |
| Read the screen, tap and type **on a real iPhone** | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ Xcode 27 |
| Android | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ |
| Tap an element by label or id | ✅ | ✅ | ❌ coordinates | ✅ | ✅ | ✅ | ❌ coordinates |
| Non-Latin text on a simulator | ✅ | ❌ ASCII only | ⚠️ opt-in | ❔ | ❔ | ❔ | ❔ |
| Pinch and other multi-touch | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ | ✅ |
| Answer permission prompts | ✅ | ❌ | ❌ | ❌ | ✅ | ⚠️ | ⚠️ |
| Simulator setup: status bar, location, permissions, Face ID, language | ✅ | ⚠️ some | ❌ | ⚠️ location, locale | ⚠️ location, permissions | ⚠️ location, permissions | ❌ |
| Push notifications | ✅ simulated and APNs | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| App logs from a real iPhone | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ |
| Crash reports | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ | ⚠️ Organizer |
| App files and UserDefaults | ✅ | ❌ | ❌ | ⚠️ clear only | ⚠️ files | ⚠️ clear only | ❌ |
| Screen recording | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Build and test Xcode projects | ❌ planned | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |
| License | MIT | MIT | MIT | Apache 2.0 | Apache 2.0 | Apache 2.0 | proprietary |

✅ yes · ⚠️ partly · ❌ no · ❔ not documented. Checked against each project's README and docs on 5 November 2026; if something has changed, please open an issue.

**When to pick something else**

- **You also test on Android:** mobile-mcp, Appium MCP or Maestro. Also worth a look: [agent-device][ad] (iOS, Android and more, simulators and real devices) and [Argent][arg] (simulators and Android, leaning towards React Native).
- **You want the agent to build, run and test your Xcode project:** MobileBuildMCP or Xcode's own MCP server. They work fine next to iSim-mcp: build with one, drive and debug the app with iSim-mcp.
- **You are on Xcode 26 or older:** iSim-mcp needs Xcode 27.
- **Your team already has Appium or Maestro tests:** their MCP servers reuse them.

[mbm]: https://github.com/getsentry/MobileBuildMCP
[ism]: https://github.com/joshuayoes/ios-simulator-mcp
[mm]: https://github.com/mobile-next/mobile-mcp
[am]: https://github.com/appium/appium-mcp
[mae]: https://docs.maestro.dev/get-started/maestro-mcp
[xc]: https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode
[ad]: https://github.com/callstack/agent-device
[arg]: https://github.com/software-mansion/argent

## Toolsets

Tools come in groups. The first five are on by default; turn on the others with `--toolsets`.

| Toolset | Default | For | Tools |
|---|:---:|---|---|
| core | ✅ | setup and diagnostics | `doctor`, `set_active_device`, `ui_agent` |
| devices | ✅ | simulators and iPhones | `list_devices`, `boot_device`, `shutdown_device`, `reboot_device`, `open_simulator_app`, `list_runtimes`, `create_device`, `erase_device`, `delete_device`, `clone_device`, `rename_device` |
| apps | ✅ | installing and running apps | `list_apps`, `get_app_info`, `install_app`, `uninstall_app`, `launch_app`, `terminate_app`, `open_url`, `list_processes`, `get_app_container`, `send_memory_warning` |
| screen | ✅ | screenshots and video | `screenshot`, `get_screen_info`, `start_recording`, `stop_recording`, `add_media` |
| ui | ✅ | reading the screen and input | `describe_ui`, `find_elements`, `describe_point`, `tap`, `swipe`, `type_text`, `press_key`, `press_button`, `wait_for`, `handle_system_alert`, `set_orientation`, `touch_path`, `multi_touch`, `scroll_until_visible`, `shake` |
| system | | environment for tests and screenshots | `configure_ui`, `set_permission`, `set_location`, `simulate_route`, `override_status_bar`, `biometrics`, `set_pasteboard`, `get_pasteboard`, `send_push`, `set_locale`, `icloud_sync` |
| data | | the app's files and settings | `list_container_files`, `read_container_file`, `write_container_file`, `read_user_defaults`, `write_user_defaults`, `keychain` |
| logs | | debugging | `start_log_capture`, `read_log_capture`, `stop_log_capture`, `query_logs`, `list_crash_reports`, `get_crash_report` |
| advanced | | raw access, use with care | `simctl_raw`, `devicectl_raw`, `post_darwin_notification`, `spawn_process` |

Everything except raw access, for app development and debugging:

```bash
claude mcp add isim -- ~/.local/bin/isim-mcp --toolsets core,devices,apps,screen,ui,system,data,logs
```

In a JSON config the same goes into `"args": ["--toolsets", "core,devices,apps,screen,ui,system,data,logs"]`. `--toolsets all` turns on all 71 tools; `isim-mcp --list-tools --toolsets …` prints what a set contains.

**Which device.** Every device tool takes an optional `device` (UDID or name). Without it the server uses the active device (`set_active_device`), otherwise the only booted simulator or connected iPhone. `erase_device` and `delete_device` always need an explicit `device`.

<details>
<summary><b>All command-line options</b></summary>

| Option | Environment | |
|---|---|---|
| `--toolsets core,devices,…` or `all` | | toolsets to enable; `core` is always on |
| `--team-id` | `ISIM_TEAM_ID` | development team that signs the UI agent for iPhones |
| `--apns-key-path`, `--apns-key-id` | `ISIM_APNS_KEY_PATH`, `ISIM_APNS_KEY_ID` | APNs auth key for real pushes, see [Push notifications](#push-notifications) |
| `--log-level` | | stderr log level, `info` by default |
| `--list-tools` | | print the enabled tools and exit |

Logs go to stderr; stdout carries only JSON-RPC.

</details>

## Simulators and real iPhones

Most tools work on both. Where they differ:

| | Simulator | iPhone / iPad |
|---|:---:|:---:|
| Create, boot, shut down, erase, delete, clone | ✅ | — (reboot and rename only) |
| Install, launch, terminate apps; open URLs; app info and processes | ✅ | ✅ device builds signed by your team |
| Screenshots | ✅ | ✅ |
| Screen recording | ✅ | — |
| Read the screen, tap, type, swipe, drag, pinch | ✅ built in | ✅ through the [UI agent](#real-iphones) |
| Two-finger rotation | — (simulators don't pass it to apps) | ✅ |
| Answer permission prompts | ✅ | ✅, plus alerts inside apps such as "Save Password?" |
| Appearance, Dynamic Type, Increase Contrast, Reduce Motion | ✅ | ✅ |
| Location and routes, orientation, pasteboard | ✅ | ✅ |
| Permissions without a prompt, status bar, Face ID / Touch ID, photos and contacts, language and region, keychain, shake, iCloud sync, hardware keyboard | ✅ | — |
| Push notifications | ✅ simulated or APNs | ✅ APNs |
| App stdout and stderr | ✅ | ✅ |
| Unified log (`os_log`, `Logger`) | ✅ | ✅ over USB |
| Crash reports, container files, reading UserDefaults | ✅ | ✅ development builds |
| Writing UserDefaults | ✅ | — (use launch arguments) |
| Memory warning | ✅ | ⚠️ `devicectl` fails on iOS 27.0.1 |
| Darwin notifications | ✅ | ✅ |
| Run a program inside the device | ✅ | — |

## Real iPhones

UI tools on an iPhone go through an XCUITest runner on the phone (`Agent/`). On the first UI call the server builds it with `xcodebuild`, signs it, installs it and starts it. To get there:

1. **Pair the phone.** Connect it by USB, tap *Trust* on the phone and let Xcode prepare it for development once.
2. **Developer Mode:** Settings → Privacy & Security → Developer Mode.
3. **UI Automation:** Settings → Developer → **Enable UI Automation**.
4. **A development team.** Sign in to Xcode with your Apple ID; a free account's Personal Team works. The server takes the team from `ui_agent(team_id:)`, `--team-id`, the team used last, or the only team in Xcode; with several teams the first UI tool asks you to pick one.
5. **Trust the certificate** the first time: Settings → General → VPN & Device Management.
6. **Keep the phone unlocked** while the agent works with it.

`doctor` checks pairing, Developer Mode, the lock state and signing identities, and says what is missing.

- **Startup.** The first build takes up to a minute. After that the agent starts in about 10 s, or 4 s with the build cached in `~/Library/Application Support/iSim-mcp/agent`, and runs until the server exits. `ui_agent` shows it, starts it ahead of time, rebuilds or stops it.
- **Speed** on an iPhone 14 Plus: `describe_ui` 0.3–0.6 s, a tap on an element 0.8 s, `type_text` into a field 3 s.
- **USB or Wi-Fi.** The server reaches the agent through usbmuxd, or through Xcode's CoreDevice tunnel when the phone is on Wi-Fi, which usbmuxd does not see. The unified log needs USB.
- **Free Apple ID.** Personal Team profiles last 7 days; the server rebuilds the agent when one has expired.
- **Your apps** must be built for the device and signed with your team.
- **Privacy.** Screenshots, UI trees (Settings shows your account name and Wi-Fi network), app and process lists, crash report lists and the pasteboard of a personal phone go to the AI agent and its provider.

<details>
<summary><b>More about the UI agent</b></summary>

- Typing reaches the app as a hardware keyboard, so iOS hides the software keyboard and brings it back a second later; the agent waits for that before the next screen read or tap.
- Home screen icons come without frames, so open apps with `launch_app` rather than by tapping icons.
- Debug builds of Flutter apps do not start on an iPhone without Flutter tooling attached; use a profile or release build. Profile builds ask for local network access on first launch, and an app that reads the pasteboard itself (Flutter's Cmd+V) gets an "Allow Paste" prompt: `type_text(method: paste)` says so, and `handle_system_alert(accept)` lets the paste through.
- On a simulator `ui_agent start` moves its UI tools from the built-in simulator bridge to the agent, a fallback if the bridge breaks with a new Xcode; `ui_agent stop` moves them back.

</details>

## Guide

### Reading the screen and tapping

`describe_ui` lists what is on screen, one line per element, in points:

```
"iSim Test" (pid 75337), 402×874 pt, 4 element(s):
[heading] "Welcome" (133,356 137×41)
[text_field] value="Username" id=username (24,412 354×34)
[secure_text_field] value="Password" id=password (24,462 354×34)
[button] "Log In" id=loginButton (166,512 70×34)
```

`tap`, `type_text`, `swipe`, `find_elements` and `wait_for` take an `element` selector (`identifier`, `label` as the whole label, case-insensitive, `label_contains`, `value`, `role`, `index`) or coordinates in points. A login then reads:

```
type_text(text: "alex", element: {identifier: "username"})
type_text(text: "secret", element: {identifier: "password"})
tap(element: {label: "Log In"})
wait_for(condition: exists, element: {label: "Items"})
```

- Apps expose their UI tree only if accessibility was on in the simulator when they started. The server switches it on in `boot_device`, `launch_app` and the first UI tool; an app started before that shows no elements until it is relaunched with `launch_app` (the error says so).
- `handle_system_alert` reads and answers permission prompts. accept/deny know the English button labels and otherwise go by position. On iPhones it also answers alerts and sheets inside apps that XCUITest marks as such, like iOS's "Save Password?" after a login.
- `swipe(direction: up)` moves the finger up, which scrolls a list towards its end.
- `screenshot` returns a JPEG downscaled to 1024 px by default and says how image pixels map to points; `format=png max_dimension=0` gives the full-resolution PNG, `return=path` only saves a file.

<details>
<summary><b>Typing text</b></summary>

- On a simulator `type_text` types Latin letters, digits and punctuation with the simulator's hardware keyboard; other text (Cyrillic, emoji) is pasted with Cmd+V and stays on the simulator's pasteboard. Flutter apps read the pasteboard themselves on Cmd+V, which iOS refuses, so when the field does not change `type_text` long-presses it and taps Paste in the edit menu. The pasted text goes where the long press puts the cursor.
- On an iPhone the agent types any script directly.
- `configure_ui(hardware_keyboard: false)` disconnects a simulator's hardware keyboard, the Simulator app's Connect Hardware Keyboard: the software keyboard then shows while a field has focus, for screenshots or layouts that move with it. `type_text` and `press_key` type either way. CoreSimulator cannot read the setting back.

</details>

<details>
<summary><b>Gestures</b></summary>

`touch_path` moves one finger through points, `dt_ms` apart: drag and drop, drawing, sliders; repeat a point with a `dt_ms` to hold before dragging (reordering a list). `multi_touch` pinches (`pinch_out` zooms in, `pinch_in` out) and rotates around a point or an element, or follows two fingers' points. `scroll_until_visible` swipes until an element is on screen and stops when the list ends. `shake` sends the Shake Gesture (simulators). Simulators pass pinches to apps but not rotation (the angle arrives undefined), so `multi_touch` refuses `rotate` there.

</details>

<details>
<summary><b>Flutter apps</b></summary>

- A widget's `Key` does not reach the accessibility tree; for `identifier` selectors wrap the widget in `Semantics(identifier: ...)`.
- A text field's label is its hint and is gone once the field has text, so select a filled field by `role` (`secure_text_field` for a password) and `index`.
- Non-Latin text on a simulator goes through the edit menu's Paste (see *Typing text*). On an iPhone, use a profile or release build (see *More about the UI agent*).
- `start_log_capture` runs next to `flutter run` without relaunching the app.

</details>

### Screenshots for the App Store

A typical setup on a simulator: `configure_ui(appearance: dark)`, `override_status_bar(preset: screenshot)` (9:41, full battery and signal), `set_location(...)`, `set_permission(action: grant, ...)`, then `launch_app` and `screenshot(format: png, max_dimension: 0)`.

### Logs, video and app data

- **App output.** `launch_app(capture_output: true)` keeps the app's stdout and stderr (`print`, `NSLog`) in a job; `read_log_capture` reads what is new since the last read (or from a `cursor`, with `grep`), `stop_log_capture` ends it and terminates the app. Simulators and iPhones.
- **Unified log.** `start_log_capture` streams `os_log`/`Logger`/`NSLog` entries of an app, process, subsystem or predicate into a job without relaunching the app; `query_logs` returns the last minutes at once. On an iPhone connected by USB the entries come from its log relay (`com.apple.os_trace_relay`, what Console.app shows), without root: the same compact lines as on a simulator, filtered on the Mac. `query_logs` on an iPhone downloads the device's log archive first (about 230 MB, 10 s). Over Wi-Fi this does not work: usbmuxd does not see iPhones that Xcode reaches over the network.
- **Crash reports.** `list_crash_reports` lists an app's crashes (simulator apps' reports live on the Mac, an iPhone's are copied from it), `get_crash_report` shows the exception, termination reason, the message the code left and the crashed thread's stack.
- **Video (simulators).** `start_recording` → `stop_recording` writes a QuickTime movie to `~/Library/Caches/iSim-mcp/recordings` (or `path`) and returns its duration and size.
- **Container files.** `list_container_files`, `read_container_file` (property lists as JSON, text as text, PNG/JPEG as an image, `save_path` for databases) and `write_container_file` work on the data container or an app group. On iPhones only development builds of your apps are reachable.
- **UserDefaults.** `read_user_defaults` reads an app's domain or a suite. `write_user_defaults` (simulators) sets or removes a key through the simulator's `defaults`, so the running app sees it at once. On iPhones, override a default for one run with `launch_app(args: ["-key", "value"])`.
- **Simulator extras.** `set_locale` (language and region; the simulator reboots in a few seconds), `keychain` (trust a CA for a debugging proxy, reset), `icloud_sync`, `clone_device` (a snapshot of a shut-down simulator), `send_memory_warning`.
- Jobs write to `~/Library/Caches/iSim-mcp/jobs`; all jobs stop when the server exits, and a recording still gets its file finished.

### Push notifications

`send_push` delivers a simulated push to a simulator app with no setup (`mode: local`, the default on simulators). For real pushes through Apple's servers (`mode: apns`, the default on iPhones; also background, VoIP and Live Activity pushes) start the server with an APNs auth key from your Apple Developer account and pass the app's device token:

```bash
claude mcp add isim -- ~/.local/bin/isim-mcp --toolsets core,devices,apps,screen,ui,system \
  --team-id AB12CD34EF --apns-key-path ~/keys/AuthKey_XYZ123.p8 --apns-key-id XYZ123
```

The key stays with the server: it never appears in tool parameters or results. `environment: production` targets TestFlight and App Store builds.

## Troubleshooting

- **Anything fails:** ask the agent to run `doctor`. Errors from the tools also say what to do next.
- **`describe_ui` shows no elements:** the app started before accessibility was on. Relaunch it with `launch_app`.
- **Non-Latin text doesn't arrive on a simulator:** it goes through the pasteboard. In Flutter apps the long-press Paste fallback puts it where the cursor lands.
- **The UI agent won't start on an iPhone:** check that the phone is unlocked, UI Automation is on and the developer certificate is trusted on the phone. `ui_agent(action: start, rebuild: true)` builds it anew.
- **No unified log from an iPhone:** connect it by USB.

## Try it on the test app

`make test-app` builds a small SwiftUI app (`dev.isimmcp.testapp`) with a login, a list, a detail screen and permission prompts, plus a lab screen (launch it with `args: ["-lab"]`) for gestures, shake, memory warnings, UserDefaults, locale, logs and a crash button. `make test-app-device TEAM=<team id> DEVICE=<udid>` builds the same app for an iPhone (`dev.isimmcp.testapp.<team id>`).

## How it works

- **Simulators:** `simctl` and `devicectl` for devices, apps and settings; private CoreSimulator APIs, loaded at runtime, for input (XPC to the simulator's `dtuhidd` HID service) and the accessibility tree (`Sources/SimBridge`).
- **iPhones:** `devicectl` for apps, files and settings; the XCUITest agent for the screen and input, reached through usbmuxd or the CoreDevice tunnel; the device's `os_trace_relay` for the unified log; APNs over HTTP/2 for pushes.

The design, decisions and what comes next are in [PLAN.md](PLAN.md) (in Russian).

## Development

```bash
make build
make test               # unit tests; devices are mocked via ProcessRunning
make test-app           # the SwiftUI test app for UI tools → .build/TestApp/ISimTestApp.app
make test-app-device TEAM=AB12CD34EF DEVICE=<udid>   # the same app for an iPhone
```

Debug with MCP Inspector:

```bash
npx @modelcontextprotocol/inspector ~/.local/bin/isim-mcp
```

<details>
<summary><b>Source layout</b></summary>

- `Sources/ProcessKit`: async process runner with timeouts and cancellation.
- `DeviceCore`: models, device resolution, capability matrix, UI elements and selectors, background jobs, crash report parsing.
- `SimctlBackend`, `DevicectlBackend`.
- `SimBridge` (Objective-C): CoreSimulator, XPC to the simulator's `dtuhidd` HID daemon, accessibility through AccessibilityPlatformTranslation. `SimBridgeBackend`: input and UI tree on top of it.
- `AgentBackend`: builds and runs the UI agent, talks to it over HTTP through usbmuxd or the CoreDevice tunnel.
- `APNsBackend`: token-signed HTTP/2 requests to APNs.
- `LockdownBackend`: an iPhone's unified log: usbmuxd, the pair record, a TLS session with lockdownd, `os_trace_relay`; runs as the `isim-mcp device-log` child process.
- `LogPredicate` (Objective-C): NSPredicate without its exceptions.
- `ISimMCP`: tools, registry, router. `isim-mcp`: CLI entry point.
- `Agent/`: the agent's Xcode project, an empty host app and a UI-test runner serving XCUITest over HTTP.
- `Spikes/`: the phase 0 prototypes and the Flutter report.

</details>

## License

[MIT](LICENSE)
