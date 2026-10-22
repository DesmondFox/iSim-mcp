# iSim-mcp

MCP server in Swift that lets an AI agent (Claude Code, Cursor, …) drive **iOS simulators and physical iPhones/iPads**: create, boot and erase simulators, install, launch and inspect apps, take screenshots, set up the environment — dark mode, Dynamic Type, status bar, location, permissions, Face ID, pasteboard, push notifications — and, on simulators, use the app: read the screen's accessibility tree, tap, swipe, type and answer system alerts. Input on iPhones comes in a later phase — see [PLAN.md](PLAN.md).

Requires macOS with **Xcode 27 or newer**. No Python, Node or third-party device tools: everything goes through `simctl`, `devicectl` and, for simulator input and accessibility, private CoreSimulator APIs loaded at runtime (`Sources/SimBridge`).

## Install

```bash
make install            # swift build -c release → ~/.local/bin/isim-mcp
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
| core | `doctor`, `set_active_device` |
| devices | `list_devices`, `boot_device`, `shutdown_device`, `reboot_device`, `open_simulator_app`, `list_runtimes`, `create_device`, `erase_device`, `delete_device` |
| apps | `list_apps`, `get_app_info`, `install_app`, `uninstall_app`, `launch_app`, `terminate_app`, `open_url`, `list_processes`, `get_app_container` |
| screen | `screenshot`, `get_screen_info`, `add_media` |
| ui | `describe_ui`, `find_elements`, `describe_point`, `tap`, `swipe`, `type_text`, `press_key`, `press_button`, `wait_for`, `handle_system_alert`, `set_orientation` |
| system | `configure_ui`, `set_permission`, `set_location`, `simulate_route`, `override_status_bar`, `biometrics`, `set_pasteboard`, `get_pasteboard`, `send_push` |

Every device tool takes an optional `device` (UDID or name). Without it the server uses the active device (`set_active_device`), otherwise the only booted simulator or connected iPhone. `erase_device` and `delete_device` always need an explicit `device`.

`screenshot` returns a JPEG downscaled to 1024 px by default and says how image pixels map to points; `format=png max_dimension=0` gives the full-resolution PNG, `return=path` only saves a file.

Options: `--toolsets core,devices,apps,screen,ui` (default) or `all`, `--log-level`, `--list-tools`. Logs go to stderr; stdout carries only JSON-RPC. The `system` toolset is off by default; enable it for screenshot preparation:

```bash
claude mcp add isim -- ~/.local/bin/isim-mcp --toolsets core,devices,apps,screen,ui,system
```

## Using an app (simulators)

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
- `type_text` types Latin letters, digits and punctuation with the simulator's hardware keyboard; other text (Cyrillic, emoji) is pasted with Cmd+V and stays on the simulator's pasteboard.
- `handle_system_alert` reads and answers permission prompts. accept/deny know the English button labels and otherwise go by position.
- `swipe(direction: up)` moves the finger up, which scrolls a list towards its end.
- `make test-app` builds a small SwiftUI app (`dev.isimmcp.testapp`) with a login, a list, a detail screen and permission prompts to try the tools on.

A typical screenshot setup on a simulator: `configure_ui(appearance: dark)`, `override_status_bar(preset: screenshot)`, `set_location(...)`, `set_permission(action: grant, ...)`, then `launch_app` and `screenshot`.

## Physical devices

- Developer Mode on, device paired with this Mac, unlocked while you work with it.
- Apps must be built for the device and signed with your team.
- Booting, shutting down, erasing and deleting are not available on physical devices; `reboot_device` works (the phone then waits for its passcode).
- Simulator only for now: UI tools (accessibility tree, taps, typing, alerts) — iPhones need an on-device agent that comes in phase 4.
- Simulator only: permissions without the prompt, status bar overrides, Face ID / Touch ID, adding photos, simulated push, app container paths on the Mac.
- On both: appearance and Dynamic Type, location and routes, orientation, pasteboard, app info and processes.
- Screenshots, app and process lists and the pasteboard of a personal phone go to the AI agent — keep that in mind.

## Development

```bash
make build
make test               # unit tests; devices are mocked via ProcessRunning
make test-app           # the SwiftUI test app for UI tools → .build/TestApp/ISimTestApp.app
```

Layout: `Sources/ProcessKit` (async process runner with timeouts and cancellation), `DeviceCore` (models, device resolution, capability matrix, UI elements and selectors), `SimctlBackend`, `DevicectlBackend`, `SimBridge` (Objective-C: CoreSimulator, XPC to the simulator's `dtuhidd` HID daemon, accessibility through AccessibilityPlatformTranslation), `SimBridgeBackend` (input and UI tree on top of it), `ISimMCP` (tools, registry, router), `isim-mcp` (CLI entry point). `Spikes/` holds the phase 0 prototypes.
