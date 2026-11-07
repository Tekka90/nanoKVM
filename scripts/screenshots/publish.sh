#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# NanoKVM: capture App Store screenshots and/or stage them for fastlane
# ==============================================================================
#   scripts/screenshots/publish.sh                    stage the existing framed shots (default)
#   scripts/screenshots/publish.sh --capture          capture (iPhone, iPad, Mac), frame, then stage
#   scripts/screenshots/publish.sh --upload           stage, then upload to App Store Connect
#   scripts/screenshots/publish.sh -c -u              all of it
#   scripts/screenshots/publish.sh -n                 dry run: show what would be copied
#
# Staging copies the framed App Store sizes into fastlane/screenshots/{ios,mac}/en-US:
#   iPhone 6.9" (1320x2868), iPad 13" (2064x2752), Mac (2880x1800).
# The Duo and landscape shots are not App Store sizes and are never staged.
# Upload needs the ASC_* variables of fastlane/.env.default.example. It replaces the
# screenshots already on App Store Connect for the editable version; no binary or text is sent.
# ==============================================================================

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FRAMED="$ROOT/build/screenshots/framed"
DEST="$ROOT/fastlane/screenshots"
LOCALE="${LOCALE:-en-US}"

CAPTURE=0
UPLOAD=0
DRY=0
for arg in "$@"; do
    case "$arg" in
        -c | --capture) CAPTURE=1 ;;
        -u | --upload) UPLOAD=1 ;;
        -n | --dry-run) DRY=1 ;;
        -h | --help) sed -n '5,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# source folder:platform:file prefix
SETS=("iphone-6.9:ios:iphone" "ipad-13:ios:ipad" "mac-14:mac:mac")

if [[ $CAPTURE -eq 1 ]]; then
    log "Capturing (iPhone, iPad)"
    [[ $DRY -eq 1 ]] || "$SCRIPT_DIR/screenshots.sh" phone ipad
    log "Capturing (Mac)"
    [[ $DRY -eq 1 ]] || "$SCRIPT_DIR/screenshots-mac.sh"
fi

log "Staging into fastlane/screenshots/<platform>/$LOCALE"
[[ $DRY -eq 1 ]] || rm -rf "$DEST/ios" "$DEST/mac"
COUNT=0
for set in "${SETS[@]}"; do
    IFS=: read -r folder platform prefix <<< "$set"
    shopt -s nullglob
    files=("$FRAMED/$folder"/*.png)
    shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "Missing $FRAMED/$folder (run with --capture)" >&2
        exit 1
    fi
    [[ $DRY -eq 1 ]] || mkdir -p "$DEST/$platform/$LOCALE"
    for f in "${files[@]}"; do
        name="$prefix-$(basename "$f")"
        echo "  $platform/$LOCALE/$name"
        [[ $DRY -eq 1 ]] || cp "$f" "$DEST/$platform/$LOCALE/$name"
        COUNT=$((COUNT + 1))
    done
done
log "$COUNT screenshots staged"

if [[ $UPLOAD -eq 1 && $DRY -eq 0 ]]; then
    cd "$ROOT"
    log "Uploading the iOS screenshots"
    fastlane ios screenshots
    log "Uploading the macOS screenshots"
    fastlane mac screenshots
fi
