#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# NanoKVM: App Store screenshots
# ==============================================================================
# Runs the real app in the simulators against a fake KVM (scripts/screenshots/mock-kvm.py streaming a drawn
# desktop), drives it with AXe and duoctl, and frames the captures in Apple's bezels.
#
#   scripts/screenshots/screenshots.sh                 all devices
#   scripts/screenshots/screenshots.sh phone duo-fold  only these
#   NO_FRAME=1 scripts/screenshots/screenshots.sh      raw captures only
#
# Targets: phone, ipad, duo-fold, duo-open.   Output: build/screenshots/{raw,framed}
# Needs: Xcode, axe (brew), duoctl, ffmpeg, python3 with Pillow.
# ==============================================================================

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$ROOT/build/screenshots"
DD="$ROOT/build/screenshots-dd"
VENV="$ROOT/build/venv"
BID="org.jupille.NanoKVM"
PORT=8443

TARGETS=("$@")
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(phone ipad duo-fold duo-open)

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

start_mock() {
    log "Starting the fake KVM"
    if [[ ! -x "$VENV/bin/python" ]]; then
        python3 -m venv "$VENV"
        "$VENV/bin/pip" -q install aiohttp > /dev/null 2>&1
    fi
    python3 "$SCRIPT_DIR/make-desktop.py" "$ROOT/build/desktop.png"
    "$VENV/bin/python" "$SCRIPT_DIR/mock-kvm.py" "$PORT" "$ROOT/build/desktop.png" "$ROOT/build/mock" > "$ROOT/build/mock.log" 2>&1 &
    MOCK_PID=$!
    trap 'kill "$MOCK_PID" 2> /dev/null || true' EXIT
    for _ in $(seq 1 30); do grep -q ready "$ROOT/build/mock.log" 2> /dev/null && return; sleep 0.5; done
    echo "mock KVM did not start" >&2; cat "$ROOT/build/mock.log" >&2; exit 1
}

build_app() {
    log "Building for the simulator"
    xcodebuild -project "$ROOT/NanoKVM/NanoKVM.xcodeproj" -scheme NanoKVM -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO | grep -E "error:|BUILD" || true
    APP="$DD/Build/Products/Debug-iphonesimulator/NanoKVM.app"
    [[ -d "$APP" ]] || { echo "build failed" >&2; exit 1; }
}

udid_for() { xcrun simctl list devices available | grep -F "    $1 (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'; }

# Taps with a real touch; the default tap style is ignored by some controls.
tap() {
    if [[ -n "$DUO" ]]; then
        duoctl -d "$U" tap "$@" > /dev/null || return 1
    else
        axe tap "$@" --tap-style physical --wait-timeout 10 --udid "$U" > /dev/null || return 1
    fi
    sleep 1.5
}
tap_label() { tap --label "$1"; }
shot() {
    mkdir -p "$OUT/raw/$NAME"
    sleep 1.5
    if [[ -n "$DUO" ]]; then
        duoctl -d "$U" screenshot "$OUT/raw/$NAME/$1.png" > /dev/null
    else
        xcrun simctl io "$U" screenshot "$OUT/raw/$NAME/$1.png" > /dev/null 2>&1
    fi
    log "  $NAME/$1"
}
relaunch() {
    xcrun simctl terminate "$U" "$BID" > /dev/null 2>&1 || true
    xcrun simctl launch "$U" "$BID" -screenshots-host "127.0.0.1:$PORT" > /dev/null
    sleep 7
}
# Pages under the KVM rail entry open from its pop-up menu.
kvm_page() { tap_label KVM; sleep 0.5; tap_label "$1"; }

# Drags the page up by a fraction of the screen height (slow, so it barely flings). SW/SH are the screen size in points.
scroll() {
    local x=$((SW * 7 / 10)) y1=$((SH * 85 / 100)) y2=$((SH * 85 / 100 - SH * $1 / 100))
    if [[ -n "$DUO" ]]; then
        duoctl -d "$U" swipe --duration 1 "$x" "$y1" "$x" "$y2" > /dev/null
    else
        axe swipe --start-x "$x" --start-y "$y1" --end-x "$x" --end-y "$y2" --duration 1 --udid "$U" > /dev/null
    fi
    sleep 1.5
}

scenes() {
    relaunch
    shot 01-screen

    # The KVM pop-up over a page shows everything the web UI offers.
    kvm_page Media
    tap_label KVM
    shot 02-kvm-menu
    tap_label Media

    tap_label Settings
    scroll "${SCROLL_DISPLAY:-$SCD}"
    shot 03-display

    # The row's position depends on the screen height, so scroll until it is on screen.
    for _ in 1 2 3 4 5 6; do
        scroll 40
        tap_label "Adjust and test gestures" 2> /dev/null && break
    done
    shot 04-gestures

    relaunch
    tap_label Settings
    shot 05-video
}

prepare_device() {
    U="$(udid_for "$1")"
    [[ -z "$U" ]] && { echo "Simulator '$1' not found" >&2; exit 1; }
    xcrun simctl boot "$U" 2> /dev/null || true
    xcrun simctl bootstatus "$U" -b > /dev/null 2>&1
    xcrun simctl install "$U" "$APP"
    xcrun simctl status_bar "$U" override --time 9:41 --batteryState charged --batteryLevel 100 \
        --cellularBars 4 --wifiBars 3 --operatorName "" 2> /dev/null || true
    xcrun simctl ui "$U" appearance light
}

run_target() {
    case "$1" in
        phone)
            NAME=iphone-6.9; DUO=; SW=440; SH=956; SCD=45; prepare_device "iPhone 18 Pro Max"; scenes ;;
        ipad)
            NAME=ipad-13; DUO=; SW=1032; SH=1376; SCD=25; prepare_device "iPad Pro 13-inch (M5)"; scenes ;;
        duo-fold)
            NAME=duo-folded; DUO=1; SW=466; SH=678; SCD=62; prepare_device "iPhone Duo"; duoctl -d "$U" close > /dev/null; sleep 3; scenes ;;
        duo-open)
            NAME=duo-unfolded; DUO=1; SW=951; SH=669; SCD=52; prepare_device "iPhone Duo"; duoctl -d "$U" open > /dev/null; sleep 3; scenes ;;
        *) echo "Unknown target $1" >&2; exit 1 ;;
    esac
}

start_mock
build_app
for target in "${TARGETS[@]}"; do
    log "Capturing $target"
    run_target "$target"
done

if [[ -z "$NO_FRAME" ]]; then
    log "Framing"
    "$SCRIPT_DIR/fetch-bezels.sh"
    swift "$SCRIPT_DIR/frame-screenshots.swift" "$OUT/raw" "$OUT/framed"
fi
log "Done: $OUT"
