# iSim-mcp

MCP server in Swift that lets an AI agent (Claude Code, Cursor, …) drive **iOS simulators and physical iPhones/iPads**: list and boot devices, install and launch apps, open links, take screenshots. Input and UI inspection come in later phases — see [PLAN.md](PLAN.md).

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
| devices | `list_devices`, `boot_device`, `shutdown_device` |
| apps | `list_apps`, `install_app`, `uninstall_app`, `launch_app`, `terminate_app`, `open_url` |
| screen | `screenshot` |

Every device tool takes an optional `device` (UDID or name). Without it the server uses the active device (`set_active_device`), otherwise the only booted simulator or connected iPhone.

`screenshot` returns a JPEG downscaled to 1024 px by default and says how image pixels map to points; `format=png max_dimension=0` gives the full-resolution PNG, `return=path` only saves a file.

Options: `--toolsets core,devices,apps,screen,ui` (default) or `all`, `--log-level`, `--list-tools`. Logs go to stderr; stdout carries only JSON-RPC.

## Physical devices

- Developer Mode on, device paired with this Mac, unlocked while you work with it.
- Apps must be built for the device and signed with your team.
- Booting, shutting down and erasing are not available on physical devices.
- Screenshots and app lists from a personal phone go to the AI agent — keep that in mind.

## Development

```bash
make build
make test               # unit tests; devices are mocked via ProcessRunning
```

Layout: `Sources/ProcessKit` (async process runner with timeouts and cancellation), `DeviceCore` (models, device resolution, capability matrix), `SimctlBackend`, `DevicectlBackend`, `ISimMCP` (tools, registry, router), `isim-mcp` (CLI entry point). `Spikes/` holds the phase 0 prototypes.
