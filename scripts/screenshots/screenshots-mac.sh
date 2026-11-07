#!/usr/bin/env bash
# Retina macOS screenshots of the real app against the fake KVM, on a virtual 3024x1964 display
# (the 14" MacBook Pro screen), framed in Apple's MacBook Pro bezel.
#
#   scripts/screenshots/screenshots-mac.sh        (NO_FRAME=1 for raw captures only)
#
# Needs Accessibility permission for the terminal (System Settings > Privacy & Security > Accessibility),
# plus what screenshots.sh needs (ffmpeg, python3 with Pillow). Output: build/screenshots/{raw,framed}/mac-14
set -eo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$ROOT/build/screenshots"
RAW="$OUT/raw/mac-14"
DD="$ROOT/build/screenshots-mac-dd"
APP="$DD/Build/Products/Debug/NanoKVM.app"
VENV="$ROOT/build/venv"
PORT=8443
UI="osascript $SCRIPT_DIR/mac-ui.applescript"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

kill_app() {
    for pid in $(pgrep -f "$APP/Contents/MacOS/NanoKVM" || true); do kill "$pid" 2> /dev/null || true; done
}
cleanup() {
    kill_app
    kill "$VD_PID" "$MOCK_PID" 2> /dev/null || true
}
trap cleanup EXIT

log "Starting the fake KVM"
if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" -q install aiohttp > /dev/null 2>&1
fi
python3 "$SCRIPT_DIR/make-desktop.py" "$ROOT/build/desktop.png"
"$VENV/bin/python" "$SCRIPT_DIR/mock-kvm.py" "$PORT" "$ROOT/build/desktop.png" "$ROOT/build/mock" > "$ROOT/build/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 30); do grep -q ready "$ROOT/build/mock.log" 2> /dev/null && break; sleep 0.5; done

log "Building the macOS app"
xcodebuild -project "$ROOT/NanoKVM/NanoKVM.xcodeproj" -scheme NanoKVM -destination 'platform=macOS' \
    -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO | grep -E "error:|BUILD" || true
[[ -d "$APP" ]] || { echo "build failed" >&2; exit 1; }

log "Starting the virtual display"
clang -fobjc-arc -framework Cocoa -o "$ROOT/build/virtual-display" "$SCRIPT_DIR/virtual-display.m"
"$ROOT/build/virtual-display" 1512 982 > "$ROOT/build/virtual-display.out" &
VD_PID=$!
for _ in $(seq 1 20); do [[ -s "$ROOT/build/virtual-display.out" ]] && break; sleep 0.5; done
read -r _ VX VY _ < "$ROOT/build/virtual-display.out"
[[ -n "${VX:-}" ]] || { echo "virtual display failed" >&2; exit 1; }

# screencapture numbers displays 1...n; find the virtual one by its pixel size.
DISPLAY_NO=
for n in 1 2 3 4; do
    screencapture -x -D "$n" "$ROOT/build/probe.png" 2> /dev/null || continue
    if [[ "$(sips -g pixelWidth "$ROOT/build/probe.png" | awk '/pixelWidth/ {print $2}')" == 3024 ]]; then DISPLAY_NO=$n; break; fi
done
rm -f "$ROOT/build/probe.png"
[[ -n "$DISPLAY_NO" ]] || { echo "could not find the virtual display" >&2; exit 1; }

log "Launching the app"
kill_app
sleep 1
open -n "$APP" --args -ApplePersistenceIgnoreState YES -screenshots-host "127.0.0.1:$PORT"
# 1360x860 window centred on the 1512x982 virtual display; retry until the window exists.
for _ in $(seq 1 30); do
    sleep 1
    $UI frame $((VX + 76)) $((VY + 61)) 1360 860 > /dev/null 2>&1 && break
done
sleep 6

mkdir -p "$RAW"
# System Events leaves the window looking inactive (grey toggles); `open` on the running app activates it again.
activate() { open "$APP"; sleep 1.5; open "$APP"; sleep 1.5; }
shot() { sleep 1.5; screencapture -x -D "$DISPLAY_NO" "$RAW/$1.png"; log "  mac-14/$1"; }

$UI screen > /dev/null; sleep 2
activate
shot 01-screen
$UI kvm 1 > /dev/null; sleep 2
activate
$UI kvm 0 > /dev/null; sleep 1
shot 02-kvm-menu
key_escape() { osascript -e 'tell application "System Events" to key code 53'; }
key_escape; sleep 1
$UI settings > /dev/null; sleep 2
swiftc -O -o "$ROOT/build/mac-scroll" "$SCRIPT_DIR/mac-scroll.swift" 2> /dev/null
"$ROOT/build/mac-scroll" $((VX + 740)) $((VY + 500)) "${SCROLL_DISPLAY:-380}"; sleep 1
activate
shot 03-display

if [[ -z "$NO_FRAME" ]]; then
    log "Framing"
    "$SCRIPT_DIR/fetch-bezels.sh"
    swift "$SCRIPT_DIR/frame-screenshots.swift" "$OUT/raw" "$OUT/framed"
fi
log "Done: $OUT"
