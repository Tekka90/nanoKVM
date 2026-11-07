---
name: nanokvm-sync
description: Reviews recent changes in the upstream sipeed/NanoKVM repository and makes sure every new or changed feature exists in this Apple app. Use periodically or after a KVM firmware update.
---

You keep the NanoKVM Apple app (SwiftUI, macOS + iOS) at feature parity with the upstream NanoKVM project. Read `.github/copilot-instructions.md` first; it describes the architecture, API quirks and conventions.

## Procedure
1. **Find the baseline.** Read `docs/UPSTREAM.md` for the last reviewed upstream commit/release and the parity table. If it is missing, create it (format below) and start from the latest release.
2. **List upstream changes since the baseline** with `gh` (no cloning needed):
   - `gh api repos/sipeed/NanoKVM/releases --jq '.[0:5][] | {tag_name, published_at, body}'`
   - `gh api "repos/sipeed/NanoKVM/commits?per_page=50"` and `gh api repos/sipeed/NanoKVM/compare/<baseline>...HEAD`
   - Focus on `server/router`, `server/service`, `server/proto`, and `web/src` (pages, `api/`). Also check the NanoKVM-Go-Apps repo if apps are mentioned.
3. **Extract feature deltas:** new/changed/removed endpoints (method, path, request body, response shape), new settings, new UI pages, new streaming/HID behaviours.
4. **Compare with the app:** grep `NanoKVM/NanoKVM/*.swift` for each endpoint path. Classify every delta as: already supported / missing / changed / not applicable (e.g. hardware the user lacks) / unsafe to expose.
5. **Check the real device** only if the user permits (GET only, short timeout, `Origin` and `Referer` headers set). Upstream code can differ from the shipped firmware; confirm an endpoint exists before building UI for it. Ask for the credentials; never store them in files.
6. **Implement the missing features** following the repo conventions: loosely typed calls via `KVMClient.raw`, a section in an existing page or a new page wired into `Section_` in `DeviceView.swift`, errors through `PageState`. Add confirmations for risky actions.
7. **Verify:** build macOS and iOS Simulator (commands in the instructions) and fix all errors.
8. **Update `docs/UPSTREAM.md`** (new baseline, parity table, skipped items with reasons) and the feature list in `README.md` if user-visible features changed.
9. **Report** briefly: what changed upstream, what you added, what you skipped and why, and anything needing the owner's decision.

## Rules
- Do not reboot, or change Wi-Fi/network, credentials, 2FA or firmware on the real KVM without explicit approval.
- Don't invent request shapes: copy them from the upstream server/web code and confirm on the device.
- Make surgical changes; no unrelated refactors; no new dependencies.
- Don't leave secrets or temp files behind.

## `docs/UPSTREAM.md` format
- No change is complete without tests (features and fixes alike). Every feature you add must come with unit tests (see Testing in `.github/copilot-instructions.md`); run the suite on macOS and iOS before reporting done.

```
# Upstream tracking
Last reviewed: <date> — upstream <tag or commit sha>
Device tested: image <x>, application <y>

| Feature | Upstream endpoint(s) | App location | Status |
|---|---|---|---|
| MCP | /ai/config, /ai/mcp/key | ServicesView | done |

## Skipped
- <feature>: <reason>
```
