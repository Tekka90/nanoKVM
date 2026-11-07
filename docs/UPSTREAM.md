# Upstream tracking

Last reviewed: 2026-10-22 — upstream `sipeed/NanoKVM` (default branch, as of this date; no commit pinned yet)
Device tested: image v1.0.9, application 0.2.2 (NanoKVM Go+)

| Feature | Upstream endpoint(s) | App location | Status |
|---|---|---|---|
| Video stream H.264/H.265 | /stream/h264/direct, /stream/h265/direct, /stream/mode | VideoStream, SettingsView | done |
| Stream quality / fps / gop / rate control | /stream/quality, fps, gop, rate-control, encoder | SettingsView | done |
| EDID | /vm/edid, /vm/edid/custom, /vm/edid/upload, /vm/edid/delete | EDIDController, SettingsView | done |
| Images | /storage/image*, /storage/image/mount | MediaView | done |
| Image download | /storage/download/image* | AdvancedView | done |
| Wake-on-LAN | /network/wol* | WakeView | done |
| Wi-Fi | /network/wifi, scan, connect, disconnect, preset | NetworkView, AdvancedView | done |
| Static IP | /network/static-ip | AdvancedView | done |
| Tailscale | /extensions/tailscale/* | NetworkView | done (install/uninstall not exposed) |
| Hostname, mDNS, SSH | /vm/hostname, /vm/mdns, /vm/ssh | NetworkView | done |
| MCP / AI | /ai/config, /ai/mcp/key* | ServicesView | done |
| Memory fabric, timelapse | /ai/memory-fabric, /ai/screen-timelapse/state | ServicesView | toggles only (config, retention, frames not exposed) |
| Scripts | /vm/script* | ServicesView | done |
| Device settings | /vm/web-title, low-power, swap, timezone, time/sync, /hid/mode | DevicePageView | done |
| Updates | /application/version, update, preview | DevicePageView | done |
| USB identity / network | /vm/usb-id, /vm/usb-network | AdvancedView | done |
| Virtual devices | /vm/device/virtual*, disk-inquiry*, uac2-function-name | AdvancedView | done |
| Security | /application/signature-verification, /auth/password, /auth/2fa/status | AdvancedView | partial (2FA setup not exposed) |
| Finger robot | /vm/finger-robot* | AdvancedView | status/press/release only |
| Apps | /apps | AdvancedView | list only |
| HID, paste, jiggler, pointer mode | /hid/*, /vm/mouse-jiggler | InputSender, SettingsView | done |
| Menu bar items, portal, input profiles, shortcuts, leader key | /vm/menubar, /vm/portal, /vm/input-profiles, /hid/shortcut* | — | not implemented |

## Skipped
- GPIO power/reset, OLED, DNS, multi-user: endpoints return 404 on this firmware.
- 2FA setup, reboot-to-flashing, app install: risky or need extra flows.
- Screen timelapse browsing / memory fabric model config: not yet requested.
