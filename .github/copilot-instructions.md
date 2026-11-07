# Copilot instructions — NanoKVM for Apple platforms

Native SwiftUI app (macOS + iOS/iPadOS) that replaces the stock web UI of a Sipeed **NanoKVM** (tested on a NanoKVM Go+, image v1.0.9, application 0.2.2).
Project: `NanoKVM/NanoKVM.xcodeproj`, sources in `NanoKVM/NanoKVM/`. Bundle id `org.jupille.NanoKVM`, deployment target 27.0, Swift 5 mode.

## Build and verify
Run from `NanoKVM/`:
```
xcodebuild -project NanoKVM.xcodeproj -scheme NanoKVM -destination 'platform=macOS' build
xcodebuild -project NanoKVM.xcodeproj -scheme NanoKVM -destination 'generic/platform=iOS Simulator' build
```
Always build **both** platforms after a change (filter with `grep -E "error:|BUILD"`). There are no unit tests. The project uses file-system-synchronized groups: new `.swift` files in `NanoKVM/NanoKVM/` are picked up without editing the pbxproj. If Xcode doesn't see them, close/reopen the workspace and Clean Build Folder.

## Architecture
- `KVMClient.swift` / `KVMClient+API.swift`: typed HTTP client (login, stream, EDID, storage, WoL, HID...). `KVMClient+More.swift`: loosely typed `raw(method, path, body)` returning the envelope's `data` as `JSON` (`[String: Any]`), `rawArray`, `uploadFile`, plus wrappers for Wi-Fi, Tailscale, device, updates, MCP, scripts.
- `DeviceStore.swift`: saved devices, Keychain (iCloud-synced), `DeviceSession` (one per connected KVM), `FullScreenState`, synced flags.
- `DeviceView.swift`: main screen. A custom left "rail" with sections (`Section_` enum: Screen, Media, Wake, Network, Services, Device, Advanced, Settings) and a fixed bottom group (Keys, Paste, Reconnect, Full Screen, Quit on macOS). Add new pages by extending `Section_`, its icon, and the `content` switch (wrap in `NavigationStack`).
- Pages: `NetworkView`, `ServicesView` (MCP, memory fabric, timelapse, scripts), `DevicePageView`, `AdvancedView`, `SettingsView` (video, codec, EDID, pointer, jiggler), `MediaView`, `WakeView`.
- Video: `VideoStream.swift` (H.264/H.265 Annex-B over WebSocket → VideoToolbox), `InteractiveVideoView.swift`, `InputSender.swift` (HID over WebSocket). EDID: `EDIDBuilder.swift`, `EDIDController.swift`.
- Page helper: `PageKit.swift` (`PageState`, `.pageAlerts`, `str/bool/int` dictionary helpers, `copyToClipboard`). Use `page.run { ... }` for every call so errors surface in an alert.

## Device API facts (do not rediscover)
- Base `https://<host>/api`, cookie `nano-kvm-token`, envelope `{code,msg,data}` (`code == 0` is success). Self-signed certificate (the client trusts it).
- **Every request needs `Origin` and `Referer`**, otherwise 403 "csrf validation failed".
- Toggle POST bodies are usually `{enable: Bool}` (swap, low-power, preview) but `{enabled: Bool}` elsewhere (usb-id, static-ip, tailscale exit-node). Check the web bundle or server source before guessing.
- The firmware differs from the public repo: some endpoints return 404 (`/vm/gpio`, `/vm/oled`, `/network/dns`, `/auth/users`...) and a few hang (`GET /vm/time`). Always probe on the real device and use short timeouts.
- `challenge` fields are for 2FA only (off by default).
- Multiple screens: `EDIDController.displayProvider` returns a `DisplayInfo` for the window's own screen (`window.screen` / `windowScene.screen`); never use `NSScreen.main` or `UIScreen.main` for sizing. The EDID file name includes the screen tag (empty for the built-in one). `startMonitoring()` observes screen notifications and, with auto-switch on, re-matches after a debounce. Tests inject a fake `displayProvider`. Dual-screen/foldable iPhones (iOS 27.1 "iPhone Duo") expose the cover screen (466×678 pt, `UIScreen.main`) and, when unfolded, a second `UIScreen` (951×669 pt) that the scene moves to, with connect/disconnect notifications. Non-main screens get a `Screen-WxH` tag. Test folding with `duoctl open|close|state` on the Duo simulator. `DeviceView` also re-reads the screen when it changes size.
- Video `fps = 0` yields no frames. EDID changes need the external-power confirmation and cut the signal briefly.

## Conventions
- SwiftUI with `@Observable`; keep files small and per page. Cross-platform code uses `#if os(macOS)` / `#if os(iOS)` sparingly.
- `@State` declarations must be one variable per line.
- Comment only what needs clarification. Don't add dependencies.
- Be conservative with anything that can lock the user out (Wi-Fi, static IP, credentials, 2FA, flashing mode): add a confirmation and a warning. Never reboot, change network or credentials on the user's real KVM without asking first.
- Never write real passwords, tokens or device keys into the repo, docs or scratch files that outlive the task. Remove temp files after probing.
- Don't guess UI behaviour: the owner dislikes wrong guesses. Verify (build both platforms, and screenshot with `screencapture -x` when the UI changed).
- macOS full screen: the notch band stays black (system limit); the app restores in full screen and shows the rail on hover.

## Stats and encryption
- `StreamStats.swift` (`StreamMeter`, pure) feeds `VideoStream.history`; `StatsOverlay` charts it.
- **No third-party crypto.** The app has no SSH/terminal (Citadel and SwiftTerm were removed): only Apple's TLS is used, so no French encryption declaration is needed. Don't add a dependency that bundles its own cryptography without reading the App Store export-compliance notes in the README.

## Deploying
`scripts/deploy.sh` (see `--help`) runs the tests (`-t`), builds, and installs on physical devices or on the Mac (`--mac`). It never runs unless the user asks; use `-n` for a dry run.

## Pointer input
- Direct mode (default): touch/mouse position maps to the absolute pointer report. Trackpad mode (iOS only, on by default until the user chooses, per device via `PointerPrefs` / `DeviceSession.trackpad`): `InputUIView` swaps to relative gestures; the maths lives in `TrackpadEngine` (pure, tested). Enabling it sets the KVM pointer mode to relative. Gesture sets are gated in `gestureRecognizerShouldBegin`.

## Testing (mandatory, no exceptions)
**Any change to this code base (feature, fix, refactor, UI tweak, crash fix) must be covered by tests in the same change, and the full suite must pass before you report the work as done.** A change without a test is incomplete. This applies to every agent and to every file under `NanoKVM/NanoKVM/`, including platform-specific code: put macOS-only tests under `#if os(macOS)` and iOS-only tests under `#if os(iOS)`.
- Crash or trap fixes need a regression test that feeds the offending input (e.g. out-of-range integers, empty collections).
- Before finishing: run the macOS test command below, confirm 0 failures, check the coverage of the files you touched, and also run `xcodebuild build-for-testing` for `generic/platform=iOS Simulator` (run the iOS tests too when a simulator is installed). Say explicitly what you could not run.
- Prefer extracting logic into small pure functions so it can be unit tested instead of leaving it inside views or event handlers.
- Unit tests live in `NanoKVM/NanoKVMTests` (target `NanoKVMTests`, Swift Testing, hosted in the app, shared scheme `NanoKVM`).
- **Every code change or new feature must add or update unit tests in the same change.** Bug fixes get a regression test. Never leave tests failing or deleted to make a build pass.
- Network code is tested with `MockServer` / `MockURLProtocol` (`Support.swift`): register routes as `"METHOD /path"` (no `/api` prefix), and build clients with `server.client(host:)`. Pages are rendered with `mount()` in `ViewSmokeTests.swift` so their loaders run against the mock. Mock error replies must omit `data`.
- Tests touch the real UserDefaults, Keychain and iCloud KVS (app-hosted): use unique names/UUIDs and clean up. Keep `EDIDController` sessions alive (`unowned`).
- Run: `xcodebuild test -project NanoKVM/NanoKVM.xcodeproj -scheme NanoKVM -destination 'platform=macOS' -enableCodeCoverage YES -resultBundlePath /tmp/r.xcresult`, then `xcrun xccov view --report /tmp/r.xcresult`. Also run on an iOS Simulator destination. Logic files should stay above 90% coverage; don't let overall coverage drop.

## Upstream tracking
Upstream source: <https://github.com/sipeed/NanoKVM> (Go server in `server/`, web UI in `web/`). The `nanokvm-sync` agent (`.github/agents/nanokvm-sync.agent.md`) compares upstream changes with this app. Its state is kept in `docs/UPSTREAM.md`.
