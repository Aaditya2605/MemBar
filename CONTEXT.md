# MemBar

MemBar is a macOS menu bar app. It shows memory per app, not per process, and it flags leftovers: processes that still run when their app is not open. One click stops them.

Status: v1 built 2026-09-26 (`./build.sh`, then `open build/MemBar.app`). On 2026-10-03 the branch `claude/appmem-feature-expansion-544237` adds: CPU column, icons, sort, search, right-click actions, pressure, history, settings, ports, CLI flags, idle apps, remembered owners, process tree, notifications, auto rules, menu bar modes, keyboard, simulator devices, Details window, mark, orphans; then filter tokens, power and disk, 24 h history, RAM bar, menu bar RAM graph, Restart When Above, Pause When in Background, badge legend, first-run card, Save Report, Docker and VM groups, site names and process roles, launch agents, the insight line, the Details chart, Inspect and the GUI driver. The copy that runs on this Mac is `~/Applications/MemBar.app`: `./build.sh` makes `build/MemBar.app` and does not update it. CLI prototype: `~/projects/scripts/appmem.py`.
- Tested by asserts: `MemBar --test` checks the pure rules: grouping, leftovers, deleted programs, remembered owners, respawns, launch agents, orphans, VM owners and docker lines, idle apps and age, auto-stop, Quit When Idle, Restart When Above, Pause When in Background, alerts, insights, mark, growth, the 24 h history and its file, peaks, RAM bar, menu bar glyph, Details chart, power and disk, filter tokens, site names and roles, environment and secrets, CLI flags, keys, simulator lines, reports (Markdown, CSV) and URLs.
- Tested by snapshots: `MemBar --snapshot OUT.png [QUERY]` and `--snapshot-details OUT.png GROUP` (debug builds) draw the real panel and the Details window off screen with live data. `CROWD=1` adds made-up groups with each badge and a "Linux VM" with containers, `HISTORY=1` made-up history (sparklines, growing badge, Details chart), `MARK=1` a mark, `FIRSTRUN=1` the first-run card, `DARK=1` or `DARK=0` the appearance. `LEGEND=1` or `INSPECT=sample|files|env` draw the badge legend or an Inspect window instead of the panel.
- Tested by the GUI driver: `.build/debug/MemBar --drive OUTDIR` (debug, the bare binary) runs the real app for about 40 s and takes the focus. It clicks the status item, turns the mark on and off, sends keys (arrows, ⌘C, ⌘R, ⌘F, typing, Esc), opens Details and closes it with ⌘W, opens two Inspect windows on MemBar itself, builds the quick menu, sends the three `appmem://` URLs and builds each kind of notification. It checks the focus, the scans (none extra from panel to window, none with both closed) and that closed windows are freed. Output: a PNG per step and `drive.log` in OUTDIR; exit 1 on a failure. A check after keys is skipped, not failed, when another app took the focus.
- Debug hook `MemBar --agent-test HOME LABEL`: Disable and enable again for a loaded test agent `com.appmem.test.*` in HOME, checked against launchctl.
- Not yet clicked by a person: Stop, Stop All, Quit, Pause and Resume on real apps; the notification prompt and a notification's Stop; Launch at Login; auto-stop, Quit When Idle, Restart When Above and Pause When in Background over real hours; simulator Shut Down; Disable Launch Agent on a real agent; containers under a live VM; Save Report's panel.

## Why

Activity Monitor shows `node`, `com.apple.WebKit.WebContent` or `Claude Helper` with no link to the app that owns them. On the first run, the prototype found about 5.5 GB of waste on a 16 GB Mac:
- 19 Cursor processes (2.1 GB) that were still running after Cursor quit. They show as `node` in Activity Monitor.
- A headless iOS simulator (3.2 GB) that an agent had booted and never shut down.
- An OpenCode service with no OpenCode app open.

## Language

**Group**:
All the processes that work for one app, for example "Claude" = the Electron UI + its helpers + the `claude` agent processes that it started.

**Owner**:
The app that a process works for. To find it: (1) the macOS "responsible" process (`responsibility_get_pid_responsible_for_pid`, a private libsystem call; Activity Monitor uses it for XPC and WebKit helpers). (2) If that process is dead or unknown, the parent chain up to launchd (PID 1). (3) The executable path of that top process gives the name: `~/Library/Application Support/<X>/...` → X, else the outermost `<X>.app/` → X, else `/System`, `/usr` and similar → "macOS", else the file name. Apple's own apps (`/System/Applications/...`) keep their name but are never leftovers. (4) A remembered owner wins over (3), and a VM owner over both.

**Remembered owner** (Recall):
A command-line process (not in an `.app`, not Apple's, not tmux, screen, zellij, dtach or abduco) that was seen in an app's group keeps that app as its owner after the app quits, while the same PID runs the same executable for the same user. Children that it starts later get the same owner. So VS Code's dev server becomes a VS Code leftover, not a group named "node". Never other users' processes. Kept in RAM only.

**Memory**:
The physical footprint. This is the "Memory" column in Activity Monitor, and it includes compressed memory. RSS is too low for processes that are compressed or in swap.

**CPU**:
% of one core since the previous scan, as in Activity Monitor. Below 0.1% it shows "–".

**Power**:
The energy that macOS estimates a process's CPU work used, per second since the previous scan (`ri_energy_nj`). CPU energy only: not the GPU or the screen, and not Activity Monitor's Energy Impact, whose formula is not public. "–" under 1 mW and for other users' processes; an Intel Mac may read 0. A Details column; the row's CPU tooltip shows it from 0.1 W.

**Disk**:
Bytes read plus written per second since the previous scan, from the same rusage call. A new process, or a reused PID (another start time), reads 0. A Details column; the row's CPU tooltip shows it from 1 MB/s.

**Leftover**:
(1) A group that belongs to an app, while that app is not open. "Open" = some process runs from `<X>.app/Contents/MacOS/`, or an iPhone/iPad app from `Wrapper/<X>.app/`. The names match by whole words ("claude" ~ "Claude Helper"). An app of its own inside the group's folder (Instruments in Xcode.app) also counts as open. Processes whose owner is an app extension (`.appex`) do not count: macOS starts them while the app is quit (for example, WhatsApp's notification extension decrypts each push), and starts them again after Stop. (2) The "iOS Simulator" group while a device is booted (`launchd_sim` runs) and Simulator.app is not open. (3) The "Android Emulator" group while Android Studio is not open. (4) A group whose owners all run an executable file that is deleted (an uninstalled brew service, a Python from an upgraded Cellar): nothing can start it again. Only ENOENT counts, so a path this user may not read is not "deleted". Only this user's owners, never a file in Apple's folders, and not when some owner's file is there (an old `claude` under an open Claude app). It wins over "open" and over the app extension rule, but not over the simulator's or the emulator's own rule. proc_pidpath fails for a deleted or replaced file, so the path is then argv's, the one the program was started by: a file that an update replaced is there, and a brew service started by its `opt/` link counts after `brew uninstall`, not `brew upgrade`. Such a group is a leftover, not an orphan; its badge says "Its program file is deleted". (5) Never an ignored app or a VM group.

**Ignored app** (Never Flagged):
An app that the user says runs without its window on purpose (right-click > Never Flag). Exact name. It is never a leftover: no badge, no Stop, no alert, not in the waste total. It is not idle either, because it is not open.

**Orphan**:
A dev server, watcher or MCP server that a terminal tab or an agent started and left. Rule: a command-line process of this user (as for Remembered owner) that launchd adopted (parent PID 1), that launchd does not run as a job (`launchctl list`), that has no live terminal, and that started before the last job list; plus every process under it. Not one with a process on a live terminal under it (mosh-server). Never MemBar or its children. An orphan moves out of the group of an app that is still open into a group named after its top orphan, but not out of a leftover's, an ignored app's, the simulator's or the emulator's group, and a VM process or one under a VM orphan (lima's `ssh`) stays in its VM group. That group gets the "orphan" badge and a Stop when it is not an app and all of this user's processes in it are orphans. It is not a leftover unless Settings > Count Orphans as Leftovers is on: a server kept on purpose looks the same.

**Respawn**:
A leftover that comes back within 60 s after Stop: the group is a leftover again and runs a stopped executable under a new PID. It gets a "respawns" badge, with the launchd job label when a new process is a launchd child of this user. Never marked for the simulator: it is shut down, not signalled.

**Launch agent**:
The launchd job behind a respawn: its label from `launchctl list`, its plist by that `Label` in `~/Library/LaunchAgents`, then `/Library/LaunchAgents`. Right-click on the row, and the Details header: Reveal Launch Agent.

**Disable** (a launch agent):
Disable Launch Agent… asks first, then runs `launchctl bootout` and `launchctl disable` for `gui/<uid>/<label>`: launchd stops it now and does not start it again, also after a restart. The plist does not change, and the respawn mark goes. Only a plist right in `~/Library/LaunchAgents` (symlinks resolved), never a `com.apple.` label, never as root. Settings > Disabled Launch Agents lists them; choosing one runs `enable` and `bootstrap`.

**Paused**:
Stopped with SIGSTOP (right-click > Pause, Pause When in Background, a debugger, ctrl-Z). The badge shows when all of this user's processes in the group are paused.

**Idle app**:
An open app (not a leftover, not ignored, not "macOS") with 500 MB or more that was not frontmost for 2 h or more. Frontmost is the only sign of use; a Chromium PWA in front counts for its browser too. An app never seen frontmost is not idle. At launch, saved times count as now.

**Leftover age**:
"for 2 d" after a leftover or an orphan: how long its oldest process has run. For the simulator: its first booted device (`launchd_sim`), because CoreSimulator daemons run for weeks.

**Pressure**:
The kernel's memory pressure level: Normal, Warning or Critical, as in Activity Monitor (but orange for Warning). The % is the part of RAM that is not available (100 − `kern.memorystatus_level`). It is what macOS acts on: it compresses, then swaps, then asks you to quit apps.

**RAM bar**:
The header's bar: physical RAM in parts. The 4 largest groups each get a color, and a dot of that color by their row's memory; a group keeps its color while it stays among the 4. Then Other apps, Wired, Compressed, and Cached and free. Footprints count compressed memory, so when the groups add up to more than App memory their parts are scaled down to it (the tooltip says so). No green, yellow, orange or red: those mean pressure, leftovers and growth. The pressure dot and % share its line.

**24 h history**:
The RAM history. The last hour: one sample each 15 s at most, groups of 50 MB or more. Older samples fold into one point per 5 min of the clock, each number at its highest so that a peak stays, with the 15 largest groups of 100 MB or more. Kept for 24 h and on disk, so the charts and the growth check have data at once after a restart. The Details chart shows 1 h or 24 h.

**Peaks Today**:
Settings > Peaks Today: the 5 groups with the most memory since midnight, each at its peak, with the time. Not macOS.

**Growing**:
A group's memory rose by 25% and 300 MB or more across 15 min or more, and mostly rose (a straight line fits with R² ≥ 0.8, 10 samples or more). From the last hour of the history.

**Mark**:
The memory of each group (10 MB or more) and the RAM at one moment, taken from a scan with the panel open. One mark at a time, kept across restarts. The header flag turns it on and off (filled = on); the line's ✕ also clears it; Settings > Mark Memory Now replaces it with a new one. Rows then show the change: "new", or "+320 MB" / "−1.1 GB" for 50 MB or more. A group under 10 MB at the mark reads as new.

**Freed**:
The memory of the groups that Stop, Stop All, Auto-stop, Quit When Idle and Restart When Above ended, as each held at its stop, added up since the first stop. A group whose processes all were in its last Stop counts once. An idle quit counts only when the app has quit within 10 s, a restart within 6 h. Recent Actions lists the last 20.

**Auto-stop**:
Off by default. A leftover that stays one for 10 min or 1 h (by MemBar's clock from first sight, not process age) gets Stop. Never an orphan, a respawn, a group that a remembered owner keeps a command-line job in (nohup, pm2), a group that is a leftover only by a deleted program file (a job kept across `brew upgrade` looks the same), a group with a paused process (its clock starts again), or a group with no process of this user. The simulator and the emulator only with "Include Simulator and Emulator".

**Quit When Idle**:
A right-click rule on an open app: 1, 2 or 4 hours. When the app was not frontmost that long, counted from when the rule was set at the latest, MemBar asks it to quit (never force). Never the frontmost app, one never seen frontmost, a VM group, or one with a process paused by hand (what Pause When in Background paused is resumed first). One ask for each idle stretch: a cancelled quit is not asked again each minute.

**Own processes** (of an app):
The app and helper executables in its `.app`, and the XPC services they are responsible for (its web pages). Not the jobs it started (a terminal's shells, an editor's dev server, an agent) or the tools its `.app` bundles (Xcode's compilers). The two rules below act on these only.

**Restart When Above**:
A right-click rule on an open app that is not Apple's: 2, 4 or 8 GB. When its own processes are above the limit and it was not frontmost for 30 min (counted from when the rule was set at the latest), MemBar asks it to quit (never force) and, once it has quit, opens it again in the background. It waits up to 6 h for a save dialog, but only 60 s once the user brings the app to the front. Never the frontmost app, a leftover, an ignored app, a VM group, one with a process paused by hand, or one that Quit When Idle just asked to quit. At most once in 6 h for each app.

**Pause When in Background**:
A right-click rule on an open app with a Dock icon. After 5 min in the background (since it was last frontmost, or since the rule or the last resume, the later), SIGSTOP to its own processes of this user that run. SIGCONT when the user switches to it (or to its Chromium PWA), opens its row's menu or turns the rule off, before Quit When Idle or Restart When Above quits it, and when MemBar quits (also on `kill`). Only what MemBar paused is resumed. Never the frontmost app, a leftover, an ignored app or a VM group. Recent Actions keeps one "Background pause" line per app; nothing is freed.

**Alert**:
A notification. All off by default. New Leftover: 500 MB or more, after 30 s, once until it is gone; it has a Stop button (rescan, then stop if still a leftover). Memory Pressure: becomes critical, at most once in 30 min. Growing App: at most once an hour for each app. App Over Limit: above the app's limit (1, 2, 4 or 8 GB), again only after it was 10% under. Ignored apps never alert.

**Insight**:
One line at the top of the list: the first of these that holds and was not hidden in the last 24 h by its ✕. Not idle apps: each row has its "idle" label. (1) Swap of 25% of the RAM or more at Warning or Critical: the largest group with a process of this user, not macOS. (2) A growing group with a process of this user, not ignored, not macOS: the one that rose the most; its ✕ hides only that group. (3) Booted simulators and emulators that are not leftovers, 1 GB or more together: the largest. Never leftovers: the header has their total. Its Show button only selects and opens the group; nothing acts.

**Device**:
A booted iOS simulator device. The expanded "iOS Simulator" group shows a line per device (by the UDID in a process path, or its `launchd_sim` parent chain), each with Shut Down, and "Shared" for the rest. The Android emulator (default SDK folder) is a group of its own. An open app that started it (VS Code, Terminal) keeps it in that app's group.

**VM process**:
A process that runs a virtual machine: Apple's Virtualization process (`com.apple.Virtualization.VirtualMachine`, which Docker, OrbStack, Lima, Podman and UTM use), `qemu-system-*` (not the Android SDK's), or a VM tool: `limactl`, `colima`, `vfkit`, `krunkit`, `gvproxy`, `com.docker.virtualization`, `com.docker.krun`.

**VM owner**:
The owner of a VM process, or of a process under one, when its top process is not an app: the app whose folder it is in (UTM), else "Podman Desktop" for `/opt/podman/`, else "Linux VM". When the top is an app (Docker, OrbStack, or VS Code whose terminal started it), that app keeps it. It wins over Recall's memory: a VM never becomes a leftover of the app that started it.

**VM group**:
A group that holds a VM process. Never a leftover: its app's window is often closed on purpose, and Stop would cut the VM off mid-write. Never Quit When Idle, Restart When Above or Pause When in Background: it is used from the command line with no window. The group's Quit, with no app to ask, signals the tools but not Apple's VM process (the tools power the guest off; its own process line can still quit it). Expanded, it shows a "Virtual machine" line with its VM processes' memory, and the containers under it.

**Container**:
A line from `docker stats` under the largest VM group: its memory and CPU as docker reports them, part of the VM's memory, not more. Only with the panel open and that row open, at most every 15 s. Read-only: MemBar never starts or stops a container or a VM.

**Site name** and **process role**:
What a process line, the Details table and the search call a helper. A WebKit web content process shows its site from its LaunchServices name ("Safari (apple.com) Web Content" → apple.com, without the app name, "https://" or "www."). A Chromium or Electron helper shows its role from `--type`: Renderer, Extension, GPU, Network, Storage, Audio, Node or Utility. Else the executable's name. Read only for the lines on show, kept 10 s by PID and path.

**Filter token**:
A word in the panel's search that filters, any case: `leftover`, `orphan`, `paused`, `growing`, `idle`, `new` (since the mark), `ignored`; `>1gb` and `<100mb` (gb or mb), `cpu>5`; `:3000` or `port:3000`, `user:root` (name or uid), `pid:123`. Every token must hold; the other words are text as before (group name, process name, site or role, PID, port). Port, user and PID pick processes: the group shows only those, expanded. A word that only looks like a token (`>1tb`) is text; a bare `port:`, `pid:` or `:` waits for its number. A token wins over a name. The menu next to the field adds them; with no result, the filters show in words.

## Requirements

- Menu bar only. No Dock icon (`LSUIElement`).
- The app icon (Finder, alerts, notifications): Claude Design option 5b, "Paper": the glyph with 4 of 6 blocks lit on a light tile. Source `Resources/AppIcon.svg`; `build.sh` copies `Resources/AppIcon.icns` and says how to make it again.
- The menu bar icon is 6 blocks: the lit ones show RAM used, to the nearest sixth (any use lights one). Its tooltip tells leftovers and memory pressure. Settings > Menu Bar Shows adds text: Icon Only (default), Leftover Size, RAM Used, Memory Pressure. Right-click opens a quick menu: Open, RAM and pressure, Stop All Leftovers, Copy Report, Refresh, Quit.
- The panel lists groups with icon, CPU, memory and process count. Leftovers come first and are marked; then sort by name, processes, CPU, memory, or change since the mark. Search by group name, process name, site or role, PID or port, with filter tokens. Each group expands to a process tree (top 10, or all), with the command line on hover and listening ports; a simulator group to its devices, a VM group to its containers.
- The header shows the RAM bar with the pressure (click: Activity Monitor's breakdown), the waste total with Stop All, the mark flag, Refresh and the gear menu. Above the list: the first-run card (once), then the insight line. The footer: hidden small groups and the freed total, on one line.
- Each leftover and orphan has a **Stop** button:
  - App leftovers and orphans: SIGTERM to each process of this user in the group (SIGCONT too, so a paused one acts on it). After 3 s, SIGKILL for the ones that still run with the same PID and path.
  - iOS Simulator: `xcrun simctl shutdown` for each booted device, in its own device set.
- Right-click on a group: Show Details, Quit, Force Quit (asks first), Restart, Quit When Idle, Restart When Above, Pause When in Background, Pause or Resume, Reveal and Disable Launch Agent (respawns), Reveal in Finder, Copy Summary, Alert Above, Never Flag. On a process: Quit, Force Quit, Pause or Resume, Reveal, Copy Path, Copy PID, and for this user's processes Inspect: Sample Process (3 s of `sample`), Open Files and Ports (`lsof`), Environment (values whose names look secret show as ••• until Show Values). Each in a window with Copy and Save.
- The Details window: a memory chart (1 h or 24 h) with now, lowest, highest and when, and CPU; then the process table, with Power and Disk columns.
- The gear menu also has Peaks Today, Save Report… (Markdown; CSV, a row per process; or JSON, as `--json`), Disabled Launch Agents and What the Badges Mean.
- Never stop or signal processes in the "macOS" group, processes that other users own, launchd, or MemBar and its children. Apple's own programs only inside a third-party app's group; a group's Quit leaves Apple's VM process to its tool. The simulator only by Stop. The per-app rules signal only an app's own processes. Launch agents: only this user's own, never by changing a file. The app and `--stop` do not run as root.
- The app itself must be light: less than 50 MB, and almost 0% CPU when idle. Refresh every 2, 3 or 5 s (default 3) only while the panel or the Details window shows. With both closed, scan once a minute (and on a pressure change) for the icon, alerts, history and the rules: only this user's memory, no `top`, no ports, no device list, no job list, no docker. Site names only for the lines on show; the insight line from the data in hand.
- Launch at Login: a Settings toggle, off by default.
- Keyboard in the panel: arrows, Return to expand, ⌘⌫ Stop, ⌘F search, ⌘C copy, ⌘R refresh, Esc.
- Command line for scripts and agent hooks: `--list`, `--json [--cpu]`, `--leftovers` (exit 1 if any), `--stop [NAME ...] [--dry-run]`, `--test`, `--help`; debug builds also `--snapshot`, `--snapshot-details` and `--drive`. The bare binary also reads the installed app's Never Flagged list. URLs `appmem://open`, `appmem://refresh`, `appmem://report`. No URL stops anything: any web page can open one.
- Native only: Swift + SwiftUI + AppKit, and Apple frameworks (Charts, UserNotifications, ServiceManagement). No web views. No third-party packages.
- Not sandboxed. The App Sandbox blocks process inspection and signals.

## Decisions

- **Read data with system calls, not shell commands:** `proc_listallpids`, `proc_pidpath`, `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)` for the parent PID, user and paused state, `proc_pid_rusage(RUSAGE_INFO_V6)` for memory (`ri_phys_footprint`), peak, CPU time, energy (`ri_energy_nj`: the process's own; V4's `ri_billed_energy` read 0 for `yes` at 98% CPU) and disk bytes, `proc_pidfdinfo` for listening ports, `sysctl` for start times, command lines and environments, and `dlsym` for the responsibility call. Tools run only when needed: `top -l 1 -stats pid,mem` for other users' memory (panel open, at most every 30 s); `launchctl list` for orphans (panel open, at most every 30 s) and to name a new respawn's job; `xcrun simctl` for devices (panel open, a device booted, at most every 30 s) and to shut them down; `docker stats` for an open VM row (at most every 15 s); `sample` and `lsof` only from Inspect; `launchctl bootout`/`disable` only from Disable Launch Agent. The scan's tools are ended after 10 s (a cut-off output counts as none), docker after 3 s, Inspect's `lsof` after 5 s and `sample` after 30 s: a wedged daemon must not hold a queue.
- **The "open" check is a loose name match by whole words.** The prototype's substring match let "xcode" hide "Code". This is a known limit.
- **What is kept:** remembered owners, respawn marks, what Pause When in Background paused and Restart When Above's 6 h are in RAM and start empty at each launch. The 24 h history is in `~/Library/Application Support/AppMem/history.json` (group ids once, times in seconds, memory in MB: about 100 KB a day), written atomically at most every 5 min and at quit; a damaged file is replaced. Settings, the ignore list, rules, limits, disabled agents, hidden insights, the mark, the freed total and Recent Actions are in UserDefaults.
- **Rules that act with no click are careful:** auto-stop and alerts are off by default, the per-app rules off until set; auto-stop skips orphans, respawns, kept terminal jobs and deleted programs; Quit When Idle and Restart When Above never force-quit; no rule acts on a VM group; a paused app resumes when the user switches to it and when MemBar quits. Stop by hand still can.
- **A scan when "open" changes, not on each window:** a new timer and a scan only when the panel or the Details window opens with the other closed, or closes with the other closed. From the panel to Details: no extra scan.
- **`kill` runs the quit work:** SIGTERM skips willTerminate, so MemBar posts it itself, then exits: paused apps resume and the history is saved.
- **No modal loop inside a main-queue block:** alerts go through `RunLoop.main.perform`, save panels use `begin`, so scans, SIGTERM and the reopen after a restart are not held back.
- **The GUI driver only looks:** `--drive` runs only as the bare debug binary (an `.app` shares the installed app's settings) and refuses to start while Auto-Stop, Quit When Idle, Restart When Above or Pause When in Background is on. It never clicks Stop, Quit or Pause, tracks no menu, posts no notification, reads the history file without writing it, and puts its defaults and the clipboard back at the end.
- **Notifications ask for permission only when a toggle is turned on.** Denied: the toggle goes off and a dialog says where to allow them.
- **Build:** use the same pattern as `~/projects/Search` (Swift Package + `build.sh` that makes the `.app`).
- **Renamed from AppMem on 2026-10-07:** the app, its process, its text and the Swift target. The `appmem://` URLs, the `com.appmem.test.*` agent labels and `~/Library/Application Support/AppMem/` keep the old name, so scripts and the history carry over.
- **Bundle ID `com.huetic.membar`,** as the other huetic apps. Before 2026-10-07 it was `com.officecommun.appmem`, copied from Search: not a domain the user owns. The settings were copied to the new ID once, by hand (`defaults export`/`import`); the app has no migration code, as no other Mac ran it.

## Not done yet

- Memory for each Chromium tab: WebKit pages show their site, but a Chromium renderer says only "Renderer"; its site is in neither its arguments nor its LaunchServices name, and each browser's task manager is not reachable from outside.
- Energy Impact: Activity Monitor's formula is not public. Power is CPU energy only (no GPU, no screen).
- Owners across restarts: an app that quit before MemBar started, or between two scans, is not known as an owner.
- Start times for reused PIDs: Recall and respawns treat the same executable at a reused PID as the same process.
- A better sign of use than frontmost: music that plays in the background reads as idle, and Pause When in Background would pause it.
- Docker's current context is not read: with two VMs, the containers can show under the wrong one.
- A crash or SIGKILL of MemBar leaves the apps it paused paused (the row's Resume or `kill -CONT` undoes it).
- Android SDK in another folder: only the default `~/Library/Android/sdk/emulator/` is matched.
- A signed and notarized build: `build.sh` signs ad hoc, so it runs only on this Mac.
