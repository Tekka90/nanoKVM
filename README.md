# NanoKVM for Apple platforms

A native SwiftUI app for macOS, iPhone and iPad that controls a [Sipeed NanoKVM](https://github.com/sipeed/NanoKVM) (developed against a NanoKVM Go+, image v1.0.9, application 0.2.2). It talks to the KVM's own HTTP/WebSocket API and exposes far more than the stock web UI.

## Features
- **Screen:** low-latency H.264 / H.265 video, keyboard and mouse (absolute/relative), ⌘ shortcut forwarding, paste, mouse jiggler, macOS full screen with a hover-reveal sidebar.
- **Sharp picture:** builds and uploads a custom EDID matching the Mac/iPad display (notch-aware, HiDPI variants) so pixels map 1:1; optional auto-switch; synced via iCloud. It uses the screen the app window is on (not just the main one), keeps one EDID file per screen (including the iPhone Duo cover and inner screens), and re-matches a few seconds after a monitor is plugged, unplugged, resized or the window moves (auto-switch on).
- **Media:** list, upload, mount and delete ISO/IMG images.
- **Wake:** Wake-on-LAN machines.
- **Network:** Wi-Fi scan/connect/disconnect, Tailscale, hostname, mDNS, SSH toggle.
- **Services:** MCP server (enable, endpoint, API key, ready-made client config), memory fabric, screen timelapse, scripts (upload, run, delete).
- **Device:** info, web title, low-power, swap, USB mode, time zone/time sync, firmware updates, reboot.
- **Advanced:** USB identity and network, virtual devices (network, disk, audio) and reported names, static IP, Wi-Fi preset, image download to the KVM, signature verification, login change, 2FA status, finger robot, installed apps.
- **Trackpad mode (iOS):** per device; touch moves the cursor relatively (drag to move with acceleration, tap = click, two-finger tap = right click, two-finger drag = scroll, tap then touch again and drag = move a window, or hold briefly then drag). Speed is adjustable. On by default on iOS; direct (absolute) touch is one toggle away.
- **Settings:** video quality, codec, frame rate, GOP, EDID, pointer mode.
- Devices are discovered via Bonjour; credentials live in the (iCloud) Keychain.

Not implemented (missing on this firmware or too risky): GPIO power buttons, OLED, DNS, multi-user management, 2FA setup, reboot-to-flashing, app installation.

## Requirements
- Xcode with the macOS / iOS 27 SDK. Deployment targets: iOS/iPadOS 17.0, macOS 15.0, visionOS 1.0. Swift 5 mode.
- A NanoKVM reachable on your network (HTTPS, self-signed certificate is accepted).

## Build
```
cd NanoKVM
xcodebuild -project NanoKVM.xcodeproj -scheme NanoKVM -destination 'platform=macOS' build
xcodebuild -project NanoKVM.xcodeproj -scheme NanoKVM -destination 'generic/platform=iOS Simulator' build
```
Or open `NanoKVM/NanoKVM.xcodeproj` in Xcode and run. New source files are picked up automatically (synchronized folders); if Xcode misses them, reopen the workspace and Clean Build Folder.

## Tests
```
xcodebuild test -project NanoKVM/NanoKVM.xcodeproj -scheme NanoKVM -destination 'platform=macOS' -enableCodeCoverage YES
```
Tests use a mocked URL protocol, so no KVM is needed. Current coverage is about 78% of the app (over 90% for the logic layers). iOS-only tests (`IOSInputViewTests`) need an iOS simulator to run.

## On-screen keyboard (iOS)
The **Type** button in the rail opens the system keyboard; typed characters are sent as US-layout key presses (`KeyMap.swift`; characters with no US key are skipped). A bar above the keyboard has a hide button, Esc, Tab, sticky Ctrl/Alt/Win (they apply to the next key), arrows, Home/End/PgUp/PgDn/Del/Ins and F1–F12. The **Keys** menu has shortcuts such as Ctrl+Alt+Del, and a hardware keyboard works as before.

## Stream statistics
The chart button (top right of the Screen) shows a live bitrate and FPS chart for the last minute, plus resolution, codec, average/peak bitrate and keyframe count.

## Encryption and export compliance

The app uses only Apple's TLS (`URLSession`), no bundled cryptography, so `Info.plist` sets `ITSAppUsesNonExemptEncryption` to `false` and App Store Connect needs no encryption documentation, including for France. SSH and the terminal were removed for that reason (they pulled in Citadel). Adding a library that ships its own crypto would require the French ANSSI declaration again.

## Wake on no signal
When the host display is asleep (no signal), the app taps F15 up to 4 times (1.5 s apart) to wake it. F15 has no effect on macOS/Windows/Linux and can't trigger Sticky Keys.

## Deploy
`scripts/deploy.sh` builds and installs on connected iPhones/iPads (`xcrun devicectl`) or on this Mac:
```
scripts/deploy.sh -L                       # list devices
scripts/deploy.sh -d iPad -l               # install on the iPad and launch
scripts/deploy.sh --test --mac -l -c Release
scripts/deploy.sh --help
```
Build products go to `.build/` (ignored by git).

## Layout
```
NanoKVM/NanoKVM/
  KVMClient*.swift        HTTP client and API wrappers
  DeviceStore.swift       devices, Keychain, sessions
  DeviceView.swift        main screen and sidebar rail
  *View.swift             one file per page (Network, Services, Device, Advanced, Settings, Media, Wake)
  VideoStream.swift       H.264/H.265 decoding
  InputSender.swift       keyboard/mouse over WebSocket
  EDID*.swift             EDID building and upload
  PageKit.swift           shared page helpers
.github/copilot-instructions.md   conventions and API facts for Copilot
.github/agents/nanokvm-sync.agent.md   agent that tracks upstream NanoKVM changes
docs/UPSTREAM.md                  parity table and last reviewed upstream version
```

## Keeping up with upstream
Run the `nanokvm-sync` agent (e.g. `/agent` in Copilot CLI, then pick `nanokvm-sync`) periodically or after a KVM firmware update. It reviews new upstream releases/commits, implements missing features here, rebuilds both platforms and updates `docs/UPSTREAM.md`.

## Notes
- On notched MacBooks, native full screen leaves the notch band black; the EDID size subtracts it.
- Changing Wi-Fi, static IP or credentials on the KVM can make it unreachable; the app warns before doing so.

## App Store screenshots

`scripts/screenshots/screenshots.sh [phone ipad duo-fold duo-open]` runs the app in the simulators against a fake KVM (`mock-kvm.py` streaming a drawn desktop) and frames the captures in Apple's bezels; `scripts/screenshots/screenshots-mac.sh` does the same for the Mac on a virtual display (needs Accessibility permission for the terminal). Output goes to `build/screenshots/{raw,framed}`. The app side is the `-screenshots-host host:port` launch argument (`ScreenshotMode`), which never saves the demo device. `scripts/screenshots/publish.sh` is the one entry point: with no option it copies the framed App Store sizes (iPhone 6.9", iPad 13", Mac) into `fastlane/screenshots/{ios,mac}/en-US`; `-c` captures first, `-u` uploads afterwards (`fastlane ios screenshots` and `fastlane mac screenshots`, screenshots only, replacing the ones on App Store Connect), `-n` is a dry run. Duo and landscape shots are never staged.

Needs axe, duoctl, ffmpeg and Python with Pillow. Scenes: Screen, KVM menu, Display/EDID (match the KVM to the local screen), Gesture tuning (iOS only) and Video quality; the Mac captures the first three. On the Mac, `SCROLL_DISPLAY` sets how far Settings scrolls to reach Display, and the window can look inactive (grey toggles), so check the Display shot.

The landscape iPhone shot (`raw/iphone-6.9-land/01-screen.png`, framed by the same script) isn't scripted: the simulator can't be rotated from the shell, so rotate it with Xcode's `DeviceInteractionSynthesize` (`orientation landscapeRight`), relaunch with `-screenshots-host` and capture with `simctl io screenshot`.
