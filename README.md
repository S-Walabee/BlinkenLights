# BlinkenLights

Old-school drive activity lights for macOS. A small floating panel shows every mounted
volume — local disks, external drives, disk images and network shares — with a
**green LED for reads** and a **red LED for writes**.

![LEDs](https://img.shields.io/badge/macOS-15%2B-blue)

## Features

- One entry per mounted volume, labelled with its Finder name
- Free space shown as a percentage beside each volume (hover for GB free of total);
  read-only volumes such as DVDs show none
- Network shares (SMB / NFS / AFP) appear when mounted and disappear when unmounted
- Borderless, draggable panel on every Space (including full-screen apps); no Dock icon or menu bar
- Right-click menu:
  - Vertical / Horizontal layout
  - Always Visible (float above other windows)
  - Show Free Space (on by default)
  - Background opacity slider
  - Update speed (100 ms – 2 s, default 500 ms)
  - Launch at Login
  - Quit

## How it works

- **Local volumes:** I/O counters come from the `IOBlockStorageDriver` beneath each
  volume. macOS only counts I/O per device, so APFS volumes that share a drive blink
  together.
- **Network shares:** file-sharing traffic belongs to the kernel, so BlinkenLights reads
  per-connection byte counters for `kernel_task` from `nettop`. It matches them to each
  share's server: bytes in light the read LED, bytes out light the write LED.
- **Free space:** measured every 5 s off the main thread. Local volumes use the same
  "available" figure as Finder (including purgeable space); network shares use `statfs`.

## Build

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project BlinkenLights.xcodeproj -scheme BlinkenLights -configuration Release \
  -derivedDataPath build/DD build
ditto build/DD/Build/Products/Release/BlinkenLights.app /Applications/BlinkenLights.app
open /Applications/BlinkenLights.app
```

The project signs with a *Developer ID Application* certificate (team set in
`project.yml`). To build with your own team, change `DEVELOPMENT_TEAM`, or set
`CODE_SIGN_IDENTITY=-` for an ad-hoc local build.

## License

MIT
