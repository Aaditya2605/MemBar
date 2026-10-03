# AppMem

AppMem is a macOS menu bar app. It shows memory per app, not per process, and it flags leftovers: processes that still run when their app is not open. One click stops them.

Status: v1 built 2026-09-26 (`./build.sh`, then `open build/AppMem.app`). On 2026-10-03 the branch `claude/appmem-feature-expansion-544237` adds: CPU column, icons, sort, search, right-click actions, pressure, history, settings, ports, CLI flags, idle apps, remembered owners, process tree, notifications, auto rules, menu bar modes, keyboard, simulator devices, Details window, mark, orphans. CLI prototype: `~/projects/scripts/appmem.py`.
- Tested by asserts: `AppMem --test` checks the pure rules: grouping, leftovers, remembered owners, respawns, orphans, idle apps and age, auto-stop and Quit When Idle, alerts, mark, growth, CLI flags, keys, simulator lines, report and URLs.
- Tested by snapshots: `AppMem --snapshot OUT.png [QUERY]` and `--snapshot-details OUT.png GROUP` (debug builds) draw the real panel and the Details window off screen with live data. `CROWD=1` adds made-up groups with each badge, `HISTORY=1` a chart, `MARK=1` a mark, `DARK=1` or `DARK=0` the appearance.
- Not yet clicked by a person: Stop, Stop All, Quit, Pause and Resume on real apps; the notification prompt and a notification's Stop; Launch at Login; auto-stop and Quit When Idle over real hours; simulator Shut Down; the quick menu, the keys and the `appmem://` URLs in the running app.

## Why

Activity Monitor shows `node`, `com.apple.WebKit.WebContent` or `Claude Helper` with no link to the app that owns them. On the first run, the prototype found about 5.5 GB of waste on a 16 GB Mac:
- 19 Cursor processes (2.1 GB) that were still running after Cursor quit. They show as `node` in Activity Monitor.
- A headless iOS simulator (3.2 GB) that an agent had booted and never shut down.
- An OpenCode service with no OpenCode app open.

## Language

**Group**:
All the processes that work for one app, for example "Claude" = the Electron UI + its helpers + the `claude` agent processes that it started.

**Owner**:
The app that a process works for. To find it: (1) the macOS "responsible" process (`responsibility_get_pid_responsible_for_pid`, a private libsystem call; Activity Monitor uses it for XPC and WebKit helpers). (2) If that process is dead or unknown, the parent chain up to launchd (PID 1). (3) The executable path of that top process gives the name: `~/Library/Application Support/<X>/...` → X, else the outermost `<X>.app/` → X, else `/System`, `/usr` and similar → "macOS", else the file name. Apple's own apps (`/System/Applications/...`) keep their name but are never leftovers. (4) A remembered owner wins over (3).

**Remembered owner** (Recall):
A command-line process (not in an `.app`, not Apple's, not tmux, screen, zellij, dtach or abduco) that was seen in an app's group keeps that app as its owner after the app quits, while the same PID runs the same executable for the same user. Children that it starts later get the same owner. So VS Code's dev server becomes a VS Code leftover, not a group named "node". Never other users' processes. Kept in RAM only.

**Memory**:
The physical footprint. This is the "Memory" column in Activity Monitor, and it includes compressed memory. RSS is too low for processes that are compressed or in swap.

**CPU**:
% of one core since the previous scan, as in Activity Monitor. Below 0.1% it shows "–".

**Leftover**:
(1) A group that belongs to an app, while that app is not open. "Open" = some process runs from `<X>.app/Contents/MacOS/`, or an iPhone/iPad app from `Wrapper/<X>.app/`. The names match by whole words ("claude" ~ "Claude Helper"). An app of its own inside the group's folder (Instruments in Xcode.app) also counts as open. Processes whose owner is an app extension (`.appex`) do not count: macOS starts them while the app is quit (for example, WhatsApp's notification extension decrypts each push), and starts them again after Stop. (2) The "iOS Simulator" group while a device is booted (`launchd_sim` runs) and Simulator.app is not open. (3) The "Android Emulator" group while Android Studio is not open. (4) Never an ignored app.

**Ignored app** (Never Flagged):
An app that the user says runs without its window on purpose (right-click > Never Flag). Exact name. It is never a leftover: no badge, no Stop, no alert, not in the waste total. It is not idle either, because it is not open.

**Orphan**:
A dev server, watcher or MCP server that a terminal tab or an agent started and left. Rule: a command-line process of this user (as for Remembered owner) that launchd adopted (parent PID 1), that launchd does not run as a job (`launchctl list`), that has no live terminal, and that started before the last job list; plus every process under it. Not one with a process on a live terminal under it (mosh-server). Never AppMem or its children. An orphan moves out of the group of an app that is still open into a group named after its top orphan, but not out of a leftover's, an ignored app's, the simulator's or the emulator's group. That group gets the "orphan" badge and a Stop when it is not an app and all of this user's processes in it are orphans. It is not a leftover unless Settings > Count Orphans as Leftovers is on: a server kept on purpose looks the same.

**Respawn**:
A leftover that comes back within 60 s after Stop: the group is a leftover again and runs a stopped executable under a new PID. It gets a "respawns" badge, with the launchd job label when a new process is a launchd child of this user. Never marked for the simulator: it is shut down, not signalled.

**Paused**:
Stopped with SIGSTOP (right-click > Pause, a debugger, ctrl-Z). The badge shows when all of this user's processes in the group are paused.

**Idle app**:
An open app (not a leftover, not ignored, not "macOS") with 500 MB or more that was not frontmost for 2 h or more. Frontmost is the only sign of use. An app never seen frontmost is not idle. At launch, saved times count as now.

**Leftover age**:
"for 2 d" after a leftover or an orphan: how long its oldest process has run. For the simulator: its first booted device (`launchd_sim`), because CoreSimulator daemons run for weeks.

**Pressure**:
The kernel's memory pressure level: Normal, Warning or Critical, as in Activity Monitor. The % is the part of RAM that is not available (100 − `kern.memorystatus_level`). It is what macOS acts on: it compresses, then swaps, then asks you to quit apps.

**Growing**:
A group's memory rose by 25% and 300 MB or more across 15 min or more, and mostly rose (a straight line fits with R² ≥ 0.8, 10 samples or more). From the RAM history: the last hour, one sample each 15 s at most, groups of 50 MB or more, in RAM only.

**Mark**:
The memory of each group (10 MB or more) and the RAM at one moment, taken from a scan with the panel open. One mark at a time, kept across restarts. Rows then show the change: "new", or "+320 MB" / "−1.1 GB" for 50 MB or more. A group under 10 MB at the mark reads as new.

**Freed**:
The memory of the groups that Stop, Stop All, Auto-stop and Quit When Idle ended, as each held at its stop, added up since the first stop. A group whose processes all were in its last Stop counts once. An idle quit counts only when the app has quit within 10 s. Recent Actions lists the last 20.

**Auto-stop**:
Off by default. A leftover that stays one for 10 min or 1 h (by AppMem's clock from first sight, not process age) gets Stop. Never an orphan, a respawn, a group that a remembered owner keeps a command-line job in (nohup, pm2), a group with a paused process (its clock starts again), or a group with no process of this user. The simulator and the emulator only with "Include Simulator and Emulator".

**Quit When Idle**:
A right-click rule on an open app: 1, 2 or 4 hours. When the app was not frontmost that long, counted from when the rule was set at the latest, AppMem asks it to quit (never force). Never the frontmost app, a paused one, or one never seen frontmost. One ask for each idle stretch: a cancelled quit is not asked again each minute.

**Alert**:
A notification. All off by default. New Leftover: 500 MB or more, after 30 s, once until it is gone; it has a Stop button (rescan, then stop if still a leftover). Memory Pressure: becomes critical, at most once in 30 min. Growing App: at most once an hour for each app. App Over Limit: above the app's limit (1, 2, 4 or 8 GB), again only after it was 10% under. Ignored apps never alert.

**Device**:
A booted iOS simulator device. The expanded "iOS Simulator" group shows a line per device (by the UDID in a process path, or its `launchd_sim` parent chain), each with Shut Down, and "Shared" for the rest. The Android emulator (default SDK folder) is a group of its own. An open app that started it (VS Code, Terminal) keeps it in that app's group.

## Requirements

- Menu bar only. No Dock icon (`LSUIElement`).
- The menu bar icon shows a dot: yellow for leftovers, orange for Warning pressure, red for Critical. Settings > Menu Bar Shows adds text: Icon Only (default), Leftover Size, RAM Used, Memory Pressure. Right-click opens a quick menu: Open, RAM and pressure, Stop All Leftovers, Copy Report, Refresh, Quit.
- The panel lists groups with icon, CPU, memory and process count. Leftovers come first and are marked; then sort by name, processes, CPU, memory, or change since the mark. Search by group name, process name, PID or port. Each group expands to a process tree (top 10, or all), with the command line on hover and listening ports.
- The header shows the pressure bar (click: Activity Monitor's breakdown), a RAM chart for the last hour, the waste total with Stop All, the mark, Refresh and the gear menu.
- Each leftover and orphan has a **Stop** button:
  - App leftovers and orphans: SIGTERM to each process of this user in the group (SIGCONT too, so a paused one acts on it). After 3 s, SIGKILL for the ones that still run with the same PID and path.
  - iOS Simulator: `xcrun simctl shutdown` for each booted device, in its own device set.
- Right-click on a group: Show Details, Quit, Force Quit (asks first), Restart, Quit When Idle, Pause or Resume, Reveal in Finder, Copy Summary, Alert Above, Never Flag. On a process: Quit, Force Quit, Pause or Resume, Reveal, Copy Path, Copy PID.
- Never stop or signal processes in the "macOS" group, processes that other users own, launchd, or AppMem and its children. Apple's own programs only inside a third-party app's group. The simulator only by Stop. The app and `--stop` do not run as root.
- The app itself must be light: less than 50 MB, and almost 0% CPU when idle. Refresh every 2, 3 or 5 s (default 3) only while the panel or the Details window shows. With both closed, scan once a minute (and on a pressure change) for the icon, alerts, history and the auto rules: only this user's memory, no `top`, no ports, no device list.
- Launch at Login: a Settings toggle, off by default.
- Keyboard in the panel: arrows, Return to expand, ⌘⌫ Stop, ⌘F search, ⌘C copy, ⌘R refresh, Esc.
- Command line for scripts and agent hooks: `--list`, `--json [--cpu]`, `--leftovers` (exit 1 if any), `--stop [NAME ...] [--dry-run]`, `--test`, `--help`. URLs `appmem://open`, `appmem://refresh`, `appmem://report`. No URL stops anything: any web page can open one.
- Native only: Swift + SwiftUI + AppKit, and Apple frameworks (Charts, UserNotifications, ServiceManagement). No web views. No third-party packages.
- Not sandboxed. The App Sandbox blocks process inspection and signals.

## Decisions

- **Read data with system calls, not shell commands:** `proc_listallpids`, `proc_pidpath`, `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)` for the parent PID, user and paused state, `proc_pid_rusage(RUSAGE_INFO_V4)` for memory (`ri_phys_footprint`), peak and CPU time, `proc_pidfdinfo` for listening ports, `sysctl` for start times and command lines, and `dlsym` for the responsibility call. Tools run only when needed: `top -l 1 -stats pid,mem` for other users' memory (panel open, at most every 30 s); `launchctl list` for orphans (panel open, at most every 30 s) and to name a new respawn's job; `xcrun simctl` for devices (panel open, a device booted, at most every 30 s) and to shut them down.
- **The "open" check is a loose name match by whole words.** The prototype's substring match let "xcode" hide "Code". This is a known limit.
- **Memory across scans stays in RAM:** remembered owners, respawn marks and the RAM history start empty at each launch. Settings, the ignore list, rules, limits, the mark, the freed total and Recent Actions are in UserDefaults.
- **Rules that act with no click are careful:** auto-stop and alerts are off by default; auto-stop skips orphans, respawns and kept terminal jobs; Quit When Idle never force-quits. Stop by hand still can.
- **Notifications ask for permission only when a toggle is turned on.** Denied: the toggle goes off and a dialog says where to allow them.
- **Build:** use the same pattern as `~/projects/Search` (Swift Package + `build.sh` that makes the `.app`).

## Not done yet

- Memory for each browser tab or site: no system call links a WebContent process to a tab; it needs each browser's own API.
- Energy: Activity Monitor's energy impact formula is not public.
- Owners across restarts: an app that quit before AppMem started, or between two scans, is not known as an owner.
- Start times for reused PIDs: Recall and respawns treat the same executable at a reused PID as the same process.
- A better sign of use than frontmost: music that plays in the background reads as idle.
- Android SDK in another folder: only the default `~/Library/Android/sdk/emulator/` is matched.
- A signed and notarized build: `build.sh` signs ad hoc, so it runs only on this Mac.
