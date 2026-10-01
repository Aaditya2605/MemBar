# AppMem

AppMem is a macOS menu bar app. It shows memory per app, not per process, and it flags leftovers: processes that still run when their app is not open. One click stops them.

Status: v1 built 2026-09-26 (`./build.sh`, then `open build/AppMem.app`). Stop in the real popover not yet clicked by a person. CLI prototype: `~/projects/scripts/appmem.py`.

## Why

Activity Monitor shows `node`, `com.apple.WebKit.WebContent` or `Claude Helper` with no link to the app that owns them. On the first run, the prototype found about 5.5 GB of waste on a 16 GB Mac:
- 19 Cursor processes (2.1 GB) that were still running after Cursor quit. They show as `node` in Activity Monitor.
- A headless iOS simulator (3.2 GB) that an agent had booted and never shut down.
- An OpenCode service with no OpenCode app open.

## Language

**Group**:
All the processes that work for one app, for example "Claude" = the Electron UI + its helpers + the `claude` agent processes that it started.

**Owner**:
The app that a process works for. To find it: (1) the macOS "responsible" process (`responsibility_get_pid_responsible_for_pid`, a private libsystem call; Activity Monitor uses it for XPC and WebKit helpers). (2) If that process is dead or unknown, the parent chain up to launchd (PID 1). (3) The executable path of that top process gives the name: `~/Library/Application Support/<X>/...` → X, else the outermost `<X>.app/` → X, else `/System`, `/usr` and similar → "macOS", else the file name.

**Memory**:
The physical footprint. This is the "Memory" column in Activity Monitor, and it includes compressed memory. RSS is too low for processes that are compressed or in swap.

**Leftover**:
(1) A group that belongs to an app, while that app is not open. "Open" = some process runs from `<X>.app/Contents/MacOS/`. Processes whose owner is an app extension (`.appex`) do not count: macOS starts them while the app is quit (for example, WhatsApp's notification extension decrypts each push), and starts them again after Stop. (2) The "iOS Simulator" group while a device is booted (`launchd_sim` runs) and Simulator.app is not open.

## Requirements

- Menu bar only. No Dock icon (`LSUIElement`).
- The menu bar icon shows when leftovers exist, for example a badge or the leftover size.
- The panel lists groups sorted by memory. Leftovers come first and are marked. Each group can expand to show its largest processes (name, PID, memory).
- Each leftover has a **Stop** button:
  - App leftovers: SIGTERM to each process in the group. After 3 s, SIGKILL for the processes that still run.
  - iOS Simulator: `xcrun simctl shutdown` for each booted device.
- Never stop processes in the "macOS" group, or processes that other users own.
- The app itself must be light: less than 50 MB, and almost 0% CPU when idle. Refresh every 2–5 s only while the panel is open. With the panel closed, check about once each minute, only to update the icon.
- Native only: Swift + SwiftUI (`MenuBarExtra`) or AppKit. No web views. No third-party packages.
- Not sandboxed. The App Sandbox blocks process inspection and signals.

## Decisions

- **Read data with system calls, not shell commands:** `proc_listallpids`, `proc_pidpath`, `proc_pidinfo(PROC_PIDTBSDINFO)` for the parent PID, `proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint` for memory, and `dlsym` for the responsibility call. If `proc_pid_rusage` fails for system processes without root, use `top -l 1 -stats pid,mem` for those only (the prototype does this).
- **The "open" check is a loose name match** (see the prototype). This is a known limit.
- **Build:** use the same pattern as `~/projects/Search` (Swift Package + `build.sh` that makes the `.app`).

## Not in v1

- Memory for each browser tab or site.
- Alerts when leftovers are above a limit.
- CPU and energy.
- Launch at login.
