# Apple / Windows parity

This matrix is the acceptance inventory for the Windows client. A “complete” result must be backed by a Rust test, a frontend test and, for realtime or native integration, validation on Windows hardware.

| Area | Apple behavior to preserve | Windows status |
|---|---|---|
| Device library | Add/edit/remove, Bonjour discovery, saved metadata, Keychain password, multi-device state, reconnect | Complete: persistent metadata, Windows Credential Manager, mDNS `_http/_https` discovery, add/edit/remove, multiple authenticated sessions and supervised reconnect |
| Authentication | Username/password login, cookie, 2FA login, sensitive-action challenge/replay | Complete in-app flow: cookie remains in Rust; login 2FA and per-sensitive-action verification are UI-driven and command-guarded |
| Video | `wss://host/api/stream/{h264\|h265}/direct`, 9-byte binary header, Annex-B, H.264/H.265 hardware decode, status/no-signal, 5 s ping, 15 s stall detection | Transport/parser/5 s ping/15 s stall/reconnect complete. Windows build compiles MFT hardware enumeration, D3D11/DXGI video device, decoder activation and Annex-B submission. The transport still receives packets for signal detection while the absent Direct3D child-surface presentation is reported explicitly; no web/canvas fallback is used |
| HID | `/api/ws`, binary keyboard/mouse reports, six-key rollover, direct/relative pointer, buttons/wheel, heartbeat, reconnect | Complete protocol and WebSocket supervision; keyboard, physical key mapping, pointer/touch/wheel and release-on-stop/focus-loss are connected |
| Keys and paste | Shortcut menu, keyboard forwarding, F1–F12, modifiers, sticky modifiers, Ctrl/Alt/Del, text paste through `/hid/paste` | Complete for the covered keyboard map, special-key panel, sticky Ctrl/Shift/Alt/Win and paste endpoint |
| Full screen | Native full screen; rail visible/hidden behavior | Browser Fullscreen API is wired. A native Windows swap/presenter window is still blocked on the video child-surface integration |
| Stats | Bitrate/FPS history, dimensions, codec, peak/average bitrate, keyframe count | Complete realtime dimensions plus bounded FPS/bitrate history, peak/average values and keyframe count |
| EDID | List/custom upload/delete, display/window-specific EDID matching, auto switch, signal wait, external-power acknowledgement | Preset and custom EDIDs are shown in a picker; the window monitor EDID is generated automatically at 60 Hz. Changes, upload, deletion and per-device auto-match require a USB-C power acknowledgement. Signal wait/rollback is implemented for generated EDIDs |
| Media | Chunked ISO upload, list, mount/unmount, delete, progress | Complete with 8 MiB chunks, progress events, list/mount/unmount/delete commands and sensitive-action guards |
| Wake | Saved named MAC addresses, list/add/remove/wake | Complete commands and UI |
| Network | Hostname, mDNS, SSH, Wi-Fi scan/join/disconnect, risky-action warning | Complete commands, state and UI; risky actions require confirmation |
| Tailscale | Status/login/up/down/start/logout, exit node, subnet route | Complete commands and UI; sensitive actions require 2FA/confirmation |
| Services | MCP config/key/regeneration, memory fabric, timelapse, scripts list/run/upload/delete/log | MCP state/key/regeneration, memory fabric, timelapse and script upload/run/delete/list are wired; foreground/background logs are returned to the UI as JSON |
| Device | Hardware/info/title/low-power/swap/USB mode/time/timezone/update/preview/reboot | Complete state, typed commands and UI for supported firmware routes |
| Advanced | USB ID/network, virtual devices/names, static IP, Wi-Fi preset, image download, signature verification, password change, 2FA status, finger robot, apps | Complete typed commands/state/UI, including virtual network/disk/audio modes and CD-ROM/disk/audio reported-name editors |
| Settings | Stream quality/rate/GOP/FPS/codec, HDMI capture, pointer mode, reset, jiggler, gesture tuning, diagnostics | Complete settings/state wiring plus persisted local sensitivity for Windows relative pointer input and realtime diagnostics |
| Safety | Explicit warnings/confirmation for Wi-Fi, credentials, 2FA, reboot, update, EDID, key regeneration | Complete command-level confirmation plus UI confirmation and 2FA verification for mapped sensitive endpoints |

## HTTP protocol invariants

- Base: `https://<host>/api`
- Cookie: `nano-kvm-token`
- Every request: `Origin: https://<host>` and `Referer: https://<host>/`
- Success envelope: `{ code: 0, msg, data }`
- Self-signed TLS is accepted only for an explicitly configured device.
- Toggle casing is endpoint-specific (`enable` vs `enabled` vs `mcpEnabled`) and must not be normalized.
- Known unsupported firmware routes must be represented as errors, not silently skipped.

## Binary video contract

`wss://<host>/api/stream/{h264|h265}/direct`

Each frame has a keyframe flag byte, an 8-byte little-endian microsecond timestamp, then Annex-B NAL units. H.264 needs SPS/PPS; H.265 needs VPS/SPS/PPS. Parameter sets are sent into the decoder before picture samples. The stream is unhealthy after 15 seconds without data, with pings every 5 seconds.

## Binary input contract

`wss://<host>/api/ws`

Reports start with `[3, 1, source, kind, flags, sequence:u32 LE, timestamp-ms:u32 LE, payload...]`. A one-byte zero report is the heartbeat. Key reports release on loss of focus/session disconnect. Pointer behavior supports both normalized absolute and signed relative/wheel movement.

## Native video strategy

The intended Windows path is:

1. Rust owns TLS, cookies and the authenticated WebSocket.
2. Rust validates the frame header and Annex-B parameter sets.
3. A Windows-only module submits Annex-B access units to a hardware-capable Media Foundation H.264/H.265 decoder.
4. Decoded textures must be presented through a Direct3D-backed native child surface, not copied through JSON or a `<canvas>`. MFT/DXVA decode is implemented; this presenter attachment is the remaining Windows-only integration blocker.
5. Input coordinates are converted from the native surface and sent by Rust in the original HID report format.

No web-video fallback is accepted. If `IMFTransform` cannot enable hardware decode, the UI must show an explicit error and the unsupported feature state.

## Validation scope

- `cargo test --workspace` validates the cross-platform Rust protocol, persistence, command guards, discovery filter and realtime supervision.
- The frontend Vitest suite validates navigation, parity inventory and physical-key-to-HID mapping; Vite/TypeScript validates the UI.
- `cargo check --workspace --target x86_64-pc-windows-msvc` validates that the Windows MFT/D3D11/DXGI and Credential Manager code compiles.
- Actual MFT activation, hardware H.264/H.265 output and the missing Direct3D presenter cannot be runtime-validated on a Mac. They are intentionally reported as unsupported rather than simulated.

## Secure state

- Device metadata: app-data JSON owned by Rust, validated on load and atomic on save.
- Password/token: Windows Credential Manager / DPAPI-backed native storage; never frontend state, localStorage, logs or diagnostics.
- In-memory session cookies: Rust only.
- TLS is provided by the operating system (SChannel on Windows); no application-level cryptography dependency is introduced.
