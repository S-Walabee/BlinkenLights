# BlinkenLights — project prompt

Use this prompt to start a project like BlinkenLights: a tiny always-on-screen
macOS utility showing live read/write activity for every mounted volume as
LED-style lights. All of the requirements below were settled in advance, so no
further questions are needed before starting.

## What to build

A macOS app (Swift, SwiftUI + AppKit, macOS 15+) that displays one entry per
**mounted volume** — not per physical disk — each with two LEDs and the
volume's human-friendly name.

- **LEDs:** green = reading, red = writing, dim/off = idle. Draw them as glossy
  round LEDs with a glow when lit.
- **Labels:** show only the friendly volume name as seen in Finder (e.g.
  "Macintosh SSD", "Qwiizlab", "AI Models", "Unit One"). No device-name
  (`disk3s1`) option.
- **Free space:** after the name, a dimmed percentage of free space (e.g.
  "37%"), right-aligned in a column in the vertical layout. The tooltip adds
  the amounts ("1.92 TB free of 4 TB (48%)"). Read-only volumes (optical
  discs, mounted disc images) show no percentage — they are always "full" —
  except the boot volume `/`, whose sealed system snapshot is read-only but
  whose APFS container is not.
- **Which volumes:** the boot volume plus every browsable volume under
  `/Volumes` (internal, external, disk images, optical). Skip hidden/system
  (`nobrowse`) volumes such as Recovery, Preboot and VM.
- **Network shares:** include SMB, NFS and AFP shares mounted by this Mac. Add
  them when mounted and remove them when unmounted.
- **Order:** boot volume first, then other local volumes, then network shares;
  alphabetical within each group.
- **Update speed:** 0.5 s by default, adjustable (100 ms, 250 ms, 500 ms, 1 s, 2 s).

## Window (not a widget)

WidgetKit widgets cannot refresh anywhere near every 0.5 s; the system budgets
their refreshes to every few minutes. Use a small borderless floating panel
instead:

- `NSPanel` with `[.borderless, .nonactivatingPanel]` styles, a clear
  background, movable by dragging anywhere, and no title bar.
- The app has no Dock icon and no menu bar (`LSUIElement`, `.accessory`
  activation policy).
- Present on **every Space**, including over full-screen apps
  (`.canJoinAllSpaces, .fullScreenAuxiliary, .stationary`).
- The window sizes itself to its content, keeps its top-left corner fixed, stays
  on screen, and remembers its position.

## Settings: right-click menu on the panel

- Vertical / Horizontal layout
- Always Visible: floats above all other windows when on; normal level when off
- Background Opacity: a slider from fully transparent to opaque; the LEDs and
  text stay fully visible
- Show Free Space toggle, on by default
- Update Speed submenu
- Launch at Login (`SMAppService.mainApp`), on by default at first run
- Quit

## How activity is measured (the hard part)

- **Local volumes:** macOS keeps I/O counters per block device, not per volume.
  1. Get the volume's BSD device from `getmntinfo` (`f_mntfromname`).
  2. Find its `IOMedia` with `IOBSDNameMatching`.
  3. Walk up the IOService plane until reaching an `IOBlockStorageDriver`.
  4. Each tick, diff that driver's `Statistics` →
     `Operations (Read)` / `Operations (Write)`.

  Consequence: APFS volumes in the same container or on the same physical drive
  blink together.
- **Network shares:** SMB, NFS and AFP run in the kernel, so their traffic shows
  up as `kernel_task` TCP connections.
  1. Each tick, run `/usr/bin/nettop -m tcp -n -L 1 -p kernel_task -x -J
     bytes_in,bytes_out` off the main thread (about 30 ms per run).
  2. Keep connections to ports 445, 139, 2049 and 548, and diff the bytes per
     remote IP.
  3. Map each share to an IP by parsing the server from `f_mntfromname`
     (`//user@server/share` or `server:/path`). Resolve Bonjour names such as
     `Some Mac._smb._tcp.local` with `NetService`, and plain host names with
     `getaddrinfo`.
  4. Rules:
     - Read = at least 2 KB in per tick.
     - Write = at least 2 KB out *and* more out than in. Directory listings send
       many small requests and would otherwise light the write LED.
- **Free space:** measure every 5 s (and right after a mount change) on a
  background task, one batch at a time, because `statfs` on a dead network
  server blocks. Local volumes: `URLResourceValues`
  `volumeAvailableCapacityForImportantUsage` / `volumeTotalCapacity` (fresh
  `URL` each time to avoid cached values), which matches Finder by counting
  purgeable space; fall back to `statfs` `f_bavail` / `f_blocks`. Network
  shares: `statfs`.
- **Mount discovery:** use `getmntinfo(MNT_NOWAIT)` so a dead server can never
  block the UI. Rescan on `NSWorkspace` mount, unmount and rename
  notifications, plus every ~5 s as a safety net.
- Add the polling `Timer` to `RunLoop.main` in `.common` mode so the LEDs keep
  blinking while the right-click menu is open.

## Build, sign, deliver

- Generate the Xcode project with XcodeGen (`project.yml`).
- Sign with **Developer ID Application** (manual signing, hardened runtime,
  no sandbox — the app needs IOKit and `nettop`). Notarization is not required
  for a local build.
- Create a **public** GitHub repo under the personal account (not the Blinken
  Labs org).
- Deploy by copying the Release build to `/Applications` and launching it. If
  the source folder is iCloud-synced (`~/Documents`), strip
  `com.apple.FinderInfo` / file-provider extended attributes from the installed
  bundle, or `codesign --verify --strict` reports "detritus".
- Register launch-at-login from the copy in `/Applications`, not from the build
  folder.

## Process

- Settle open questions before writing code (they are all answered above).
- When finished, update this document so it remains a stand-alone prompt for
  starting a similar project.
