#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# NanoKVM: Build, Test & Deploy Script
# ==============================================================================
# Tests, builds and installs the app on physical iPhones/iPads (via
# 'xcrun devicectl'), or builds and installs it on this Mac (--mac).
# ==============================================================================

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT="${REPO_ROOT}/NanoKVM/NanoKVM.xcodeproj"
SCHEME="NanoKVM"
APP_NAME="NanoKVM"
BUNDLE_ID="org.jupille.NanoKVM"
DERIVED_DATA="${REPO_ROOT}/.build/derivedData"

if [[ -t 1 ]]; then
    BOLD="$(tput bold 2>/dev/null || printf "\033[1m")"
    GREEN="$(tput setaf 2 2>/dev/null || printf "\033[0;32m")"
    BLUE="$(tput setaf 4 2>/dev/null || printf "\033[0;34m")"
    YELLOW="$(tput setaf 3 2>/dev/null || printf "\033[1;33m")"
    RED="$(tput setaf 1 2>/dev/null || printf "\033[0;31m")"
    CYAN="$(tput setaf 6 2>/dev/null || printf "\033[0;36m")"
    NC="$(tput sgr0 2>/dev/null || printf "\033[0m")"
else
    BOLD="" GREEN="" BLUE="" YELLOW="" RED="" CYAN="" NC=""
fi

info()    { printf "%b[INFO]%b %s\n" "${BLUE}${BOLD}" "${NC}" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "${GREEN}${BOLD}" "${NC}" "$*"; }
warn()    { printf "%b[WARNING]%b %s\n" "${YELLOW}${BOLD}" "${NC}" "$*"; }
error()   { printf "%b[ERROR]%b %s\n" "${RED}${BOLD}" "${NC}" "$*" >&2; }
step()    { printf "\n%b=== %s ===%b\n" "${CYAN}${BOLD}" "$*" "${NC}"; }

usage() {
    local me; me="$(basename "$0")"
    printf "%bUsage:%b %s [options]\n\n" "${BOLD}" "${NC}" "$me"
    printf "%bOptions:%b\n" "${BOLD}" "${NC}"
    printf "  -t, --test              Run the unit tests (macOS) before building\n"
    printf "  -l, --launch            Launch the app after installing\n"
    printf "  -m, --mac               Build and install on this Mac (/Applications) instead of iOS devices\n"
    printf "  -c, --config <config>   Build configuration (default: \"Debug\"; use Release for daily use)\n"
    printf "  -d, --device <id|name>  Target device by name or UDID (substring match, comma-separated, or repeat -d)\n"
    printf "  -a, --all               Deploy to all connected devices without prompting\n"
    printf "  -i, --interactive       Pick target device(s) from a menu\n"
    printf "  -L, --list-devices      List detected physical devices and exit\n"
    printf "  -n, --dry-run           Show what would happen without building or installing\n"
    printf "  -T, --terminal          Run inside an interactive Terminal.app window (for keychain/signing prompts)\n"
    printf "  --clean                 Remove previous build products first\n"
    printf "  -h, --help              Show this help\n\n"
    printf "%bExamples:%b\n" "${BOLD}" "${NC}"
    printf "  ./%s -d iPad --launch        # install on the iPad and open it\n" "$me"
    printf "  ./%s --test --mac -l -c Release\n" "$me"
    printf "  ./%s --all                   # every connected device\n\n" "$me"
    exit 0
}

RUN_TESTS=false
LAUNCH_APP=false
CLEAN_BUILD=false
MAC_MODE=false
CONFIG="Debug"
DEVICE_QUERIES=()
DEPLOY_ALL=false
INTERACTIVE_PICK=false
LIST_DEVICES=false
DRY_RUN=false
USE_TERMINAL=false
ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case "$1" in
        -T|--terminal) USE_TERMINAL=true; shift ;;
        -t|--test) RUN_TESTS=true; shift ;;
        --skip-test) RUN_TESTS=false; shift ;;
        -l|--launch) LAUNCH_APP=true; shift ;;
        -m|--mac) MAC_MODE=true; shift ;;
        -c|--config) CONFIG="$2"; shift 2 ;;
        -d|--device)
            IFS=',' read -ra ADDR <<< "$2"
            for q in "${ADDR[@]}"; do
                q="$(echo "$q" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                [[ -n "$q" ]] && DEVICE_QUERIES+=("$q")
            done
            shift 2 ;;
        -a|--all) DEPLOY_ALL=true; shift ;;
        -i|--interactive|--pick) INTERACTIVE_PICK=true; shift ;;
        -L|--list|--list-devices) LIST_DEVICES=true; shift ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        --clean) CLEAN_BUILD=true; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1"; echo "Run with --help for usage."; exit 1 ;;
    esac
done

# Re-run inside Terminal.app, where keychain and signing prompts can be answered
if [[ "$USE_TERMINAL" == true ]]; then
    FORWARD_ARGS=()
    for arg in "${ORIGINAL_ARGS[@]}"; do
        [[ "$arg" != "--terminal" && "$arg" != "-T" ]] && FORWARD_ARGS+=("$arg")
    done
    info "Launching interactive Terminal.app window..."
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nanokvm-deploy.XXXXXX")
    TEMP_CMD="$TEMP_DIR/deploy.command"
    FORWARDED_CMD=""
    if [[ ${#FORWARD_ARGS[@]} -gt 0 ]]; then
        FORWARDED_CMD=$(printf "%q " "${FORWARD_ARGS[@]}")
    fi
    cat <<EOF > "$TEMP_CMD"
#!/usr/bin/env bash
trap 'rm -rf "$TEMP_DIR"' EXIT
cd '$REPO_ROOT'
"$SCRIPT_DIR/deploy.sh" $FORWARDED_CMD
STATUS=\$?
if [[ \$STATUS -eq 0 ]]; then
    echo ""; echo "Done! Closing in 2 seconds..."; sleep 2
    # Terminal keeps the window open by default; close this one once the shell has exited.
    MY_TTY=\$(tty)
    (sleep 1; osascript -e "tell application \\"Terminal\\" to close (every window whose tty of selected tab is \\"\$MY_TTY\\")" >/dev/null 2>&1) &
    disown
else
    echo ""; echo "Deployment failed with exit code \$STATUS."
    read -n 1 -s -r -p "Press any key to close..."; echo ""
fi
exit \$STATUS
EOF
    chmod +x "$TEMP_CMD"
    open "$TEMP_CMD"
    success "Dispatched to Terminal.app. Check the newly opened window."
    exit 0
fi

command -v xcodebuild &>/dev/null || { error "xcodebuild not found. Install Xcode."; exit 1; }
[[ -d "$PROJECT" ]] || { error "Xcode project not found at: $PROJECT"; exit 1; }

# ------------------------------------------------------------------------------
# Tests (shared by both modes)
# ------------------------------------------------------------------------------
run_tests() {
    step "Running unit tests (macOS)"
    local log; log="$(mktemp "${TMPDIR:-/tmp}/nanokvm-tests.XXXXXX")"
    if xcodebuild test -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" >"$log" 2>&1; then
        grep -E "Test run with" "$log" | tail -1 || true
        success "All tests passed."
        rm -f "$log"
    else
        grep -E "error:|✘" "$log" | head -30 || true
        error "Tests failed. Full log: $log"
        exit 1
    fi
}

if [[ "$CLEAN_BUILD" == true && "$DRY_RUN" != true ]]; then
    info "Cleaning previous build artifacts..."
    rm -rf "$DERIVED_DATA"
fi

# ------------------------------------------------------------------------------
# macOS mode
# ------------------------------------------------------------------------------
if [[ "$MAC_MODE" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would build '${SCHEME}' (${CONFIG}) for macOS and copy ${APP_NAME}.app to /Applications."
        exit 0
    fi
    [[ "$RUN_TESTS" == true ]] && run_tests
    step "Building ${APP_NAME} for macOS"
    info "Configuration: ${BOLD}${CONFIG}${NC}"
    xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED_DATA" -quiet \
        || { error "xcodebuild failed."; exit 1; }
    APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIG}/${APP_NAME}.app"
    [[ -d "$APP_PATH" ]] || { error "Built app not found at $APP_PATH"; exit 1; }
    step "Installing on this Mac"
    if pgrep -x "$APP_NAME" >/dev/null; then
        info "Quitting the running ${APP_NAME}..."
        osascript -e "tell application \"${APP_NAME}\" to quit" || true
        sleep 1
    fi
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP_PATH" "/Applications/${APP_NAME}.app"
    success "Installed /Applications/${APP_NAME}.app"
    if [[ "$LAUNCH_APP" == true ]]; then
        open "/Applications/${APP_NAME}.app"
        success "${APP_NAME} launched."
    fi
    exit 0
fi

# ------------------------------------------------------------------------------
# iOS: device discovery
# ------------------------------------------------------------------------------
xcrun --find devicectl &>/dev/null || { error "xcrun devicectl not found. Xcode 15+ is required."; exit 1; }

step "Step 1: Locating Target Devices"

AVAILABLE_UDIDS=()
AVAILABLE_NAMES=()
AVAILABLE_MODELS=()
AVAILABLE_STATES=()

DEV_JSON="$(mktemp "${TMPDIR:-/tmp}/nanokvm-devices.XXXXXX")"
trap 'rm -f "$DEV_JSON"' EXIT
xcrun devicectl list devices -j "$DEV_JSON" >/dev/null 2>&1 || true

while IFS='|' read -r dev_udid dev_name dev_model dev_state; do
    if [[ -n "$dev_udid" ]]; then
        AVAILABLE_UDIDS+=("$dev_udid")
        AVAILABLE_NAMES+=("$dev_name")
        AVAILABLE_MODELS+=("$dev_model")
        AVAILABLE_STATES+=("$dev_state")
    fi
done < <(python3 - "$DEV_JSON" <<'PY' 2>/dev/null || true
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw, props, conn = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") != "physical" or conn.get("tunnelState") == "unavailable":
        continue
    print("|".join([hw.get("udid", d["identifier"]), props.get("name", ""), hw.get("marketingName", ""), conn.get("tunnelState", "")]))
PY
)

if [[ "$LIST_DEVICES" == true ]]; then
    printf "\n%bConnected Physical Devices:%b\n" "${CYAN}${BOLD}" "${NC}"
    if [[ ${#AVAILABLE_UDIDS[@]} -eq 0 ]]; then
        warn "No physical devices detected."
    else
        for i in "${!AVAILABLE_UDIDS[@]}"; do
            printf "  [%d] %b%-26s%b %-34s %s (%s)\n" "$((i + 1))" "${BOLD}" "${AVAILABLE_NAMES[$i]}" "${NC}" \
                "${AVAILABLE_MODELS[$i]}" "${AVAILABLE_STATES[$i]}" "${AVAILABLE_UDIDS[$i]}"
        done
    fi
    echo ""
    exit 0
fi

if [[ ${#AVAILABLE_UDIDS[@]} -eq 0 ]]; then
    warn "No physical device detected."
    xcrun devicectl list devices || true
    error "Connect and unlock your device, or use --mac to install on this Mac."
    exit 1
fi

TARGET_DEVICES=()
TARGET_DEVICE_NAMES=()

add_target_device() {
    local udid="$1" name="$2"
    for existing in "${TARGET_DEVICES[@]}"; do [[ "$existing" == "$udid" ]] && return; done
    TARGET_DEVICES+=("$udid")
    TARGET_DEVICE_NAMES+=("$name")
}

lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

if [[ ${#DEVICE_QUERIES[@]} -gt 0 ]]; then
    for query in "${DEVICE_QUERIES[@]}"; do
        q="$(lower "$query")"
        FOUND=false
        # exact UDID, exact name, then substring of name, then substring of model
        for i in "${!AVAILABLE_UDIDS[@]}"; do
            if [[ "$(lower "${AVAILABLE_UDIDS[$i]}")" == "$q" ]]; then
                add_target_device "${AVAILABLE_UDIDS[$i]}" "${AVAILABLE_NAMES[$i]}"; FOUND=true; break
            fi
        done
        [[ "$FOUND" == true ]] && continue
        for i in "${!AVAILABLE_NAMES[@]}"; do
            if [[ "$(lower "${AVAILABLE_NAMES[$i]}")" == "$q" ]]; then
                add_target_device "${AVAILABLE_UDIDS[$i]}" "${AVAILABLE_NAMES[$i]}"; FOUND=true; break
            fi
        done
        [[ "$FOUND" == true ]] && continue
        for i in "${!AVAILABLE_NAMES[@]}"; do
            if [[ "$(lower "${AVAILABLE_NAMES[$i]}")" == *"$q"* ]]; then
                add_target_device "${AVAILABLE_UDIDS[$i]}" "${AVAILABLE_NAMES[$i]}"; FOUND=true
            fi
        done
        [[ "$FOUND" == true ]] && continue
        for i in "${!AVAILABLE_MODELS[@]}"; do
            if [[ "$(lower "${AVAILABLE_MODELS[$i]}")" == *"$q"* ]]; then
                add_target_device "${AVAILABLE_UDIDS[$i]}" "${AVAILABLE_NAMES[$i]}"; FOUND=true
            fi
        done
        [[ "$FOUND" == true ]] && continue
        error "No connected physical device matched: '${query}'"
        info "Available devices:"
        for i in "${!AVAILABLE_UDIDS[@]}"; do
            echo "  • ${BOLD}${AVAILABLE_NAMES[$i]}${NC} (${AVAILABLE_MODELS[$i]}) [${AVAILABLE_UDIDS[$i]}]"
        done
        exit 1
    done
elif [[ "$DEPLOY_ALL" == true ]]; then
    for i in "${!AVAILABLE_UDIDS[@]}"; do add_target_device "${AVAILABLE_UDIDS[$i]}" "${AVAILABLE_NAMES[$i]}"; done
elif [[ ${#AVAILABLE_UDIDS[@]} -eq 1 ]]; then
    add_target_device "${AVAILABLE_UDIDS[0]}" "${AVAILABLE_NAMES[0]}"
else
    if [[ "$INTERACTIVE_PICK" == true || -t 0 ]]; then
        printf "\n%bMultiple physical devices detected:%b\n" "${CYAN}${BOLD}" "${NC}"
        for i in "${!AVAILABLE_UDIDS[@]}"; do
            printf "  [%d] %b%-26s%b (%s)\n" "$((i + 1))" "${BOLD}" "${AVAILABLE_NAMES[$i]}" "${NC}" "${AVAILABLE_MODELS[$i]}"
        done
        printf "  [a] %bAll devices%b\n\n" "${BOLD}" "${NC}"
        while true; do
            read -r -p "Select device(s) [1-${#AVAILABLE_UDIDS[@]}, comma-separated, a] (default: a): " CHOICE
            CHOICE="$(lower "$CHOICE" | tr -d ' ')"
            if [[ -z "$CHOICE" || "$CHOICE" == "a" || "$CHOICE" == "all" ]]; then
                for i in "${!AVAILABLE_UDIDS[@]}"; do add_target_device "${AVAILABLE_UDIDS[$i]}" "${AVAILABLE_NAMES[$i]}"; done
                break
            fi
            VALID=true; SELECTED=()
            IFS=',' read -ra NUMS <<< "$CHOICE"
            for num in "${NUMS[@]}"; do
                if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#AVAILABLE_UDIDS[@]} )); then
                    SELECTED+=("$((num - 1))")
                else
                    VALID=false; break
                fi
            done
            if [[ "$VALID" == true && ${#SELECTED[@]} -gt 0 ]]; then
                for idx in "${SELECTED[@]}"; do add_target_device "${AVAILABLE_UDIDS[$idx]}" "${AVAILABLE_NAMES[$idx]}"; done
                break
            fi
            warn "Invalid selection '${CHOICE}'."
        done
    else
        info "Non-interactive session: using all ${#AVAILABLE_UDIDS[@]} connected devices (pass -d to choose)."
        for i in "${!AVAILABLE_UDIDS[@]}"; do add_target_device "${AVAILABLE_UDIDS[$i]}" "${AVAILABLE_NAMES[$i]}"; done
    fi
fi

info "Targeting ${#TARGET_DEVICES[@]} device(s):"
for i in "${!TARGET_DEVICES[@]}"; do
    echo "  • ${BOLD}${TARGET_DEVICE_NAMES[$i]}${NC} (${TARGET_DEVICES[$i]})"
done

if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would build '${SCHEME}' (${CONFIG}) for id=${TARGET_DEVICES[0]} and install on the device(s) above."
    [[ "$LAUNCH_APP" == true ]] && info "Would launch ${BUNDLE_ID} after install."
    exit 0
fi

[[ "$RUN_TESTS" == true ]] && run_tests

# ------------------------------------------------------------------------------
# iOS: build
# ------------------------------------------------------------------------------
step "Step 2: Building ${APP_NAME} for iOS"
info "Scheme:        ${BOLD}${SCHEME}${NC}"
info "Configuration: ${BOLD}${CONFIG}${NC}"
info "Destination:   id=${TARGET_DEVICES[0]} (${TARGET_DEVICE_NAMES[0]})"

if xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination "id=${TARGET_DEVICES[0]}" -derivedDataPath "$DERIVED_DATA" -allowProvisioningUpdates -quiet; then
    success "Build completed successfully!"
else
    error "xcodebuild failed. If signing failed, unlock the device and try --terminal."
    exit 1
fi

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIG}-iphoneos/${APP_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
    APP_PATH=$(find "${DERIVED_DATA}/Build/Products" -maxdepth 2 -name "${APP_NAME}.app" -type d | grep "iphoneos" | head -n1 || true)
fi
[[ -n "$APP_PATH" && -d "$APP_PATH" ]] || { error "Could not find built ${APP_NAME}.app"; exit 1; }
info "Built app bundle: ${APP_PATH}"

# ------------------------------------------------------------------------------
# iOS: install
# ------------------------------------------------------------------------------
step "Step 3: Installing App on Device(s)"

OK=0
FAIL=0
for i in "${!TARGET_DEVICES[@]}"; do
    UDID="${TARGET_DEVICES[$i]}"
    NAME="${TARGET_DEVICE_NAMES[$i]}"
    printf "\n--> Installing onto %b%s%b (%s)...\n" "${BOLD}" "${NAME}" "${NC}" "${UDID}"
    if xcrun devicectl device install app --device "${UDID}" "${APP_PATH}"; then
        success "Installed ${APP_NAME} on ${NAME}."
        OK=$((OK + 1))
        if [[ "$LAUNCH_APP" == true ]]; then
            if xcrun devicectl device process launch --device "${UDID}" "${BUNDLE_ID}" --activate; then
                success "${APP_NAME} is running on ${NAME}."
            else
                warn "Could not launch on ${NAME} (device may be locked). Tap ${APP_NAME} on the home screen."
            fi
        fi
    else
        error "Failed to install on ${NAME} (${UDID}). Make sure the device is unlocked."
        FAIL=$((FAIL + 1))
    fi
done

step "Deployment Summary"
info "Installed on ${BOLD}${OK}/${#TARGET_DEVICES[@]}${NC} device(s)"
[[ $FAIL -gt 0 ]] && warn "Failed on ${FAIL} device(s). Check unlock state and trust settings."
[[ "$LAUNCH_APP" != true ]] && info "Pass ${BOLD}--launch${NC} (-l) to open the app after install."

if [[ $OK -gt 0 ]]; then
    success "Done!"
else
    error "Deployment failed on all devices."
    exit 1
fi
