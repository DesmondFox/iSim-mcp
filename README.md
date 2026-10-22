# iSim-mcp

MCP server in Swift that lets an AI agent (Claude Code, Cursor, …) drive **iOS simulators and physical iPhones/iPads**: create, boot and erase simulators, install, launch and inspect apps, take screenshots, and set up the environment — dark mode, Dynamic Type, status bar, location, permissions, Face ID, pasteboard, push notifications. Input and UI inspection come in later phases — see [PLAN.md](PLAN.md).

Requires macOS with **Xcode 27 or newer**. No Python, Node or third-party device tools: everything goes through `simctl` and `devicectl`.

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
| ui | `set_orientation` |
| system | `configure_ui`, `set_permission`, `set_location`, `simulate_route`, `override_status_bar`, `biometrics`, `set_pasteboard`, `get_pasteboard`, `send_push` |

Every device tool takes an optional `device` (UDID or name). Without it the server uses the active device (`set_active_device`), otherwise the only booted simulator or connected iPhone. `erase_device` and `delete_device` always need an explicit `device`.

`screenshot` returns a JPEG downscaled to 1024 px by default and says how image pixels map to points; `format=png max_dimension=0` gives the full-resolution PNG, `return=path` only saves a file.

Options: `--toolsets core,devices,apps,screen,ui` (default) or `all`, `--log-level`, `--list-tools`. Logs go to stderr; stdout carries only JSON-RPC. The `system` toolset is off by default; enable it for screenshot preparation:

```bash
claude mcp add isim -- ~/.local/bin/isim-mcp --toolsets core,devices,apps,screen,ui,system
```

A typical screenshot setup on a simulator: `configure_ui(appearance: dark)`, `override_status_bar(preset: screenshot)`, `set_location(...)`, `set_permission(action: grant, ...)`, then `launch_app` and `screenshot`.

## Physical devices

- Developer Mode on, device paired with this Mac, unlocked while you work with it.
- Apps must be built for the device and signed with your team.
- Booting, shutting down, erasing and deleting are not available on physical devices; `reboot_device` works (the phone then waits for its passcode).
- Simulator only: permissions without the prompt, status bar overrides, Face ID / Touch ID, adding photos, simulated push, app container paths on the Mac.
- On both: appearance and Dynamic Type, location and routes, orientation, pasteboard, app info and processes.
- Screenshots, app and process lists and the pasteboard of a personal phone go to the AI agent — keep that in mind.

## Development

```bash
make build
make test               # unit tests; devices are mocked via ProcessRunning
```

Layout: `Sources/ProcessKit` (async process runner with timeouts and cancellation), `DeviceCore` (models, device resolution, capability matrix), `SimctlBackend`, `DevicectlBackend`, `ISimMCP` (tools, registry, router), `isim-mcp` (CLI entry point). `Spikes/` holds the phase 0 prototypes.
