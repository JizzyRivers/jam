#!/usr/bin/env bash
# Jam -- give your Biscuit (Echo Dot 2) some.
#
# A menu-driven front end tying together the whole de-Amazonized Echo Dot
# toolkit: on-device WAN blocking, wake word switching (with automatic
# temporary WAN reconnection for Amazon's entitlement check), WiFi credential
# management, plus guided submenus for the Amonet unlock and the Wyoming
# Satellite install -- neither of which is Jam's own work, so those live in
# user-supplied subdirectories (amonet/, wyomingpackage/) rather than being
# bundled here. See amonet/README.md and wyomingpackage/README.md.
#
# Run this from the same directory as the other Jam scripts.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
AMONET_DIR="$SCRIPT_DIR/amonet"
WYOMING_DIR="$SCRIPT_DIR/wyomingpackage"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }

banner() {
    [[ -t 1 ]] && clear
    cyan   "   _ "
    cyan   "  | |___ _ __ ___  "
    cyan   "  | / _ \\ '  \\/ -_) "
    cyan   "  |_\\___/_|_|_\\___| "
    echo
    bold   "  Jam -- for your Biscuit (Echo Dot 2)"
    echo
}

pause() {
    echo
    read -r -p "Press enter to continue..." _ || true
}

read_menu() {
    # $1 = prompt. Sets REPLY_CHOICE. Exits the whole script cleanly on EOF
    # instead of spinning forever on a closed stdin.
    if ! read -r -p "$1" REPLY_CHOICE; then
        echo
        yellow "input closed, exiting."
        exit 0
    fi
}

# $1 (optional): which adb state(s) count as "connected", space-separated.
# Defaults to "device" (normal booted OS). `adb get-state` reports different
# strings depending on what mode the Echo is actually in -- "device" when
# booted normally, "recovery" when it's sitting in TWRP, "sideload" mid-
# sideload. A step that specifically needs TWRP (like the Amonet firmware
# flash) must accept "recovery", not just "device", or it'll wrongly report
# "no device" even though adb can see it fine.
check_adb() {
    local wanted="${1:-device}"
    command -v adb >/dev/null || { red "adb not in PATH."; return 1; }
    local state
    state=$(adb get-state 2>/dev/null </dev/null || true)
    for w in $wanted; do
        [[ "$state" == "$w" ]] && return 0
    done
    red "No adb device in an expected state (got: '${state:-<none>}', wanted: $wanted)."
    if [[ "$wanted" == *recovery* ]]; then
        yellow "Make sure the Echo is booted into TWRP (constantly blinking cyan LED)."
    else
        yellow "Plug in the Echo and unlock/authorize it first."
    fi
    return 1
}

# Checks that a user-supplied file exists before trying to use it, pointing
# at the relevant README instead of failing with a raw "no such file".
require_file() {
    local path="$1" readme="$2"
    if [[ ! -e "$path" ]]; then
        red "Missing: $path"
        yellow "This isn't part of Jam -- see $readme for what to place there."
        return 1
    fi
    return 0
}

run_step() {
    local script="$1"
    shift
    if [[ ! -x "$script" ]]; then
        red "$script not found or not executable."
        return 1
    fi
    "$script" "$@"
}

# ---------------------------------------------------------------------------
# Wyoming Package submenu
# ---------------------------------------------------------------------------
wyoming_menu() {
    while true; do
        banner
        bold "-- Wyoming Package (not Jam's own work -- see wyomingpackage/README.md) --"
        echo
        echo "  5) Flash the HA/Wyoming boot image"
        echo "  6) Initial Alexa setup instructions (Wi-Fi + wake word, one-time, manual)"
        echo "  7) Run the installer"
        echo "  8) Reboot + show Home Assistant setup instructions"
        echo "  0) Back"
        echo
        read_menu "#? "
        case "$REPLY_CHOICE" in
            5)
                echo
                bold "Get into rainbow fastboot:"
                ADB_CUR_STATE=$(adb get-state 2>/dev/null </dev/null || true)
                case "$ADB_CUR_STATE" in
                    device)
                        echo "  Rebooting the device now..."
                        adb reboot </dev/null
                        echo "  Wait for the blue ring, count to 3, then hold the circle (action)"
                        echo "  button to enter rainbow fastboot."
                        echo
                        read -r -p "In rainbow fastboot now? Press enter to flash..." _
                        ;;
                    recovery)
                        yellow "  Device is in TWRP -- plain 'adb reboot' doesn't work from here."
                        echo "  Using 'adb shell reboot-amonet' instead, which jumps straight to"
                        echo "  rainbow fastboot (no button-holding needed)."
                        adb shell "reboot-amonet" </dev/null
                        echo
                        read -r -p "Press enter once you see the spinning rainbow LED ring..." _
                        ;;
                    *)
                        yellow "  No adb device in a known state (got: '${ADB_CUR_STATE:-<none>}')."
                        echo "  Enter fastboot manually: unplug, reconnect, wait for the blue ring,"
                        echo "  count to 3, then hold the circle (action) button."
                        echo
                        read -r -p "In rainbow fastboot now? Press enter to flash..." _
                        ;;
                esac
                echo
                if require_file "$WYOMING_DIR/flash-ha-wyoming-boot.sh" "wyomingpackage/README.md"; then
                    (cd "$WYOMING_DIR" && ./flash-ha-wyoming-boot.sh)
                    echo
                    bold "Verifying the flash actually took..."
                    yellow "(Known failure mode: the boot image sometimes doesn't stick, and the"
                    yellow "device boots into what looks like normal setup mode but with adb"
                    yellow "disabled. Checking now so we catch that BEFORE you spend time on the"
                    yellow "Alexa app setup, instead of after.)"
                    echo "Waiting for adb to come up (up to 90s)..."
                    FLASH_VERIFIED=0
                    FLASH_WAITED=0
                    while [[ "$FLASH_WAITED" -lt 90 ]]; do
                        sleep 5
                        FLASH_WAITED=$((FLASH_WAITED + 5))
                        if [[ "$(adb get-state 2>/dev/null </dev/null || true)" == "device" ]]; then
                            FLASH_VERIFIED=1
                            break
                        fi
                    done
                    echo
                    if [[ "$FLASH_VERIFIED" -eq 1 ]]; then
                        green "adb is up after ${FLASH_WAITED}s -- the flash took. Safe to proceed"
                        green "to option 6 (Alexa app setup)."
                    else
                        red "=========================================================="
                        red " WARNING: adb never came up after ${FLASH_WAITED}s."
                        red " This is the KNOWN failure mode -- the boot image did NOT"
                        red " properly take, even if the device looks fully booted into"
                        red " setup mode."
                        red "=========================================================="
                        yellow "Do NOT proceed to option 6 yet -- it will very likely end the"
                        yellow "same way: fully booted, no adb, stuck in setup with nothing to"
                        yellow "do about it from there."
                        echo
                        bold "Recovery (the bootloader unlock is fine -- no need to redo Amonet):"
                        echo "  1. Unplug the device, reconnect it, wait ~3s after the blue LED,"
                        echo "     then hold the action (circle) button ~5s to re-enter rainbow"
                        echo "     fastboot."
                        echo "  2. Re-run this option (5) to reflash, and let this check run again."
                    fi
                fi
                pause
                ;;
            6)
                echo
                red "Before doing this: confirm option 5 reported adb came up successfully"
                red "after the flash. If you skipped that check or aren't sure, go back and"
                red "re-run option 5 first -- doing the Alexa app setup on a device where the"
                red "boot image didn't take will just end in a stuck, adb-less setup screen."
                echo
                bold "Using the Alexa app once:"
                echo "  1. Connect the Echo to Wi-Fi."
                echo "  2. Set the wake word of your choice (you can change this later"
                echo "     without the app via Jam's Wake Word Switcher)."
                echo "  3. You do NOT need to block internet access in your router --"
                echo "     Jam's WAN Block (main menu) does this on-device instead."
                pause
                ;;
            7)
                echo
                if require_file "$WYOMING_DIR/install.sh" "wyomingpackage/README.md"; then
                    # install.sh is third-party (not Jam's own work -- we
                    # don't edit it) and uses `set -euo pipefail`, so it dies
                    # immediately on the first transient adb/USB hiccup
                    # instead of retrying. Retry the whole run here instead,
                    # since its steps (stop service, remount, push, etc) are
                    # safe to redo from scratch.
                    if ! check_adb; then pause; continue; fi
                    INSTALL_OK=0
                    for attempt in 1 2 3; do
                        if (cd "$WYOMING_DIR" && ./install.sh); then
                            INSTALL_OK=1
                            break
                        fi
                        yellow "install.sh failed on attempt $attempt/3 (often just a transient adb/USB drop)."
                        if [[ "$attempt" -lt 3 ]]; then
                            yellow "Waiting for the connection to settle before retrying..."
                            sleep 4
                            if ! check_adb; then
                                red "Device unreachable -- can't safely retry. Check the cable/connection and re-run option 7."
                                break
                            fi
                        fi
                    done
                    if [[ "$INSTALL_OK" -ne 1 ]]; then
                        red "install.sh did not complete after 3 attempts."
                        yellow "Re-run option 7 once the connection looks stable (see the status line"
                        yellow "on the main menu)."
                    fi
                fi
                pause
                ;;
            8)
                echo
                if check_adb; then
                    echo "Rebooting..."
                    adb reboot </dev/null
                fi
                echo
                bold "After the reboot, add the Echo as a Wyoming Satellite in Home Assistant:"
                local ip
                ip=$(adb shell "ip addr show wlan0 2>/dev/null" </dev/null 2>/dev/null | tr -d '\r' \
                    | busybox grep "inet " | busybox awk '{print $2}' | busybox cut -d/ -f1)
                echo "  Host: ${ip:-<echo-wlan-ip>}"
                echo "  Port: 10700"
                pause
                ;;
            0|"") return ;;
            *) yellow "unrecognized option"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Amonet submenu
# ---------------------------------------------------------------------------
amonet_menu() {
    while true; do
        banner
        bold "-- Amonet Unlock (not Jam's own work -- see amonet/README.md) --"
        echo
        echo "  1) Enter fastboot mode (manual -- unplug, hold action button while reconnecting)"
        echo "  2) Run brick.sh"
        echo "  3) Run bootrom-step.sh"
        echo "  4) Run fastboot-step.sh"
        echo "  5) Wait for TWRP instructions"
        echo "  6) Wipe data/cache + flash firmware via TWRP"
        echo "  7) Reboot to recovery"
        echo "  8) Reboot to hacked fastboot"
        echo "  0) Back"
        echo
        read_menu "#? "
        case "$REPLY_CHOICE" in
            1)
                echo
                bold "Enter fastboot mode:"
                echo "  Unplug the power cable, then reconnect it while holding the action"
                echo "  button (the one with a circle, \"•\")."
                echo "  Wait until you see a GREEN LED -- that's fastboot mode."
                echo
                yellow "Can't get into fastboot because the device is bricked?"
                echo "  You'll need to disassemble it and short one of the documented pins,"
                echo "  then run brick.sh (option 2) while holding the short."
                pause
                ;;
            2)
                echo
                yellow "Run this as: sudo ./brick.sh -- follow its on-screen prompts."
                yellow "Success = the LED ring shows a rainbow pattern. Unplug once you see it."
                echo
                if require_file "$AMONET_DIR/brick.sh" "amonet/README.md"; then
                    (cd "$AMONET_DIR" && sudo ./brick.sh)
                fi
                pause
                ;;
            3)
                echo
                yellow "Connect the device to your PC now, then this will run bootrom-step.sh."
                yellow "If brick.sh didn't succeed, short the pin now and hold it until the"
                yellow "script tells you to release it."
                echo
                if require_file "$AMONET_DIR/bootrom-step.sh" "amonet/README.md"; then
                    (cd "$AMONET_DIR" && sudo ./bootrom-step.sh)
                fi
                echo
                yellow "Success = device reboots to hacked fastboot mode (spinning rainbow LED ring)."
                pause
                ;;
            4)
                echo
                if require_file "$AMONET_DIR/fastboot-step.sh" "amonet/README.md"; then
                    (cd "$AMONET_DIR" && sudo ./fastboot-step.sh)
                fi
                echo
                yellow "Success = device boots into TWRP recovery (constantly blinking cyan LED)."
                pause
                ;;
            5)
                echo
                bold "Waiting for TWRP:"
                echo "  Download your chosen stock firmware (.zip or .bin -- update.bin is"
                echo "  picked up automatically if present) plus f1r30s.zip, and place both"
                echo "  in the amonet/ directory (see amonet/README.md), then continue to"
                echo "  option 6."
                pause
                ;;
            6)
                echo
                if ! check_adb recovery; then pause; continue; fi
                # Stock firmware can be supplied as either a .zip or a .bin
                # (some vendors ship OTA packages named update.bin). Look
                # for update.bin first as the common default; if it's not
                # there, ask for whatever the user actually named their
                # firmware file rather than assuming an extension.
                if [[ -f "$AMONET_DIR/update.bin" ]]; then
                    FW_FILE="update.bin"
                    green "Found $AMONET_DIR/update.bin -- using it."
                else
                    yellow "No update.bin found in amonet/."
                    read -r -p "Full filename of the stock firmware to flash (in amonet/, .zip or .bin): " FW_FILE
                fi
                if [[ -z "${FW_FILE:-}" ]]; then yellow "cancelled."; pause; continue; fi
                if ! require_file "$AMONET_DIR/$FW_FILE" "amonet/README.md"; then pause; continue; fi
                if ! require_file "$AMONET_DIR/f1r30s.zip" "amonet/README.md"; then pause; continue; fi
                echo
                red "This WIPES data and cache, then installs $FW_FILE + f1r30s.zip. This cannot be undone."
                read -r -p "Type 'yes' to continue: " CONFIRM_WIPE
                if [[ "$CONFIRM_WIPE" != "yes" ]]; then yellow "cancelled -- nothing was touched."; pause; continue; fi
                echo
                yellow "Continuing..."
                adb shell "twrp wipe data" </dev/null
                adb shell "twrp wipe cache" </dev/null
                adb push "$AMONET_DIR/f1r30s.zip" /sdcard/ </dev/null
                echo
                bold "[1/2] Installing $FW_FILE via sideload..."
                # adb sideload negotiates a special one-shot sideload adbd on
                # TWRP's end (started here via the backgrounded "twrp
                # sideload" shell command). It can drop mid-transfer on a
                # flaky USB link -- retry the whole handshake rather than a
                # single-shot attempt, and DO NOT continue to f1r30s.zip
                # unless this genuinely succeeded (patching f1r30s.zip on
                # top of a half-written base image is how we've bricked the
                # adb-never-comes-up state before).
                SIDELOAD_OK=0
                for attempt in 1 2 3; do
                    adb shell "twrp sideload" </dev/null &
                    SIDELOAD_SHELL_PID=$!
                    sleep 2
                    if adb sideload "$AMONET_DIR/$FW_FILE" </dev/null; then
                        wait "$SIDELOAD_SHELL_PID" 2>/dev/null || true
                        SIDELOAD_OK=1
                        break
                    fi
                    wait "$SIDELOAD_SHELL_PID" 2>/dev/null || true
                    yellow "  sideload attempt $attempt/3 failed."
                    if [[ "$attempt" -lt 3 ]]; then
                        yellow "  waiting for TWRP to settle before retrying..."
                        sleep 4
                        if ! check_adb "recovery sideload"; then
                            red "Device unreachable -- can't safely retry. Check the cable/LED and re-run option 6."
                            break
                        fi
                    fi
                done
                if [[ "$SIDELOAD_OK" -ne 1 ]]; then
                    red "FAILED: $FW_FILE did not install after 3 attempts."
                    red "Stopping here -- NOT installing f1r30s.zip on top of a failed/partial base flash."
                    yellow "Re-run option 6 from scratch once the device is reliably reachable."
                    pause
                    continue
                fi
                yellow "Watch for the LED to pulse green now (confirms $FW_FILE installed)."
                read -r -p "Saw the green pulse? Press enter to continue to f1r30s.zip..." _
                echo
                bold "[2/2] Installing f1r30s.zip..."
                # TWRP drops back to its normal (non-sideload) adbd once the
                # sideload above completes, and needs a moment to actually
                # settle into that state before it'll accept a shell command
                # -- firing "twrp install" immediately can race and fail with
                # a transient "no devices" even though the device is fine.
                # Poll for "recovery" state, then retry the install itself.
                RECOVERY_READY=0
                for wait_attempt in 1 2 3 4 5; do
                    if check_adb recovery 2>/dev/null; then RECOVERY_READY=1; break; fi
                    sleep 2
                done
                if [[ "$RECOVERY_READY" -ne 1 ]]; then
                    red "Device never settled back into recovery state after the sideload."
                    yellow "Check the cable/LED, then install f1r30s.zip manually:"
                    yellow "  adb shell \"twrp install /sdcard/f1r30s.zip\""
                    pause
                    continue
                fi
                INSTALL_OK=0
                for attempt in 1 2 3; do
                    if adb shell "twrp install /sdcard/f1r30s.zip" </dev/null; then
                        INSTALL_OK=1
                        break
                    fi
                    yellow "  twrp install attempt $attempt/3 failed, retrying..."
                    sleep 3
                done
                if [[ "$INSTALL_OK" -ne 1 ]]; then
                    red "FAILED: f1r30s.zip did not install after 3 attempts."
                    yellow "adb (force-enable) will NOT work reliably until this succeeds. Retry"
                    yellow "manually: adb shell \"twrp install /sdcard/f1r30s.zip\""
                    pause
                    continue
                fi
                echo
                yellow "Watch for a second green pulse now (confirms f1r30s.zip installed)."
                yellow "Look for \"Done processing script file\" in the output above -- that's"
                yellow "the real confirmation f1r30s.zip's patches (adb force-enable, dm-verity"
                yellow "disable, OTA block) actually applied."
                yellow "Reboot when ready -- adb is forcibly enabled by the exploit, so it'll"
                yellow "be reachable once booted."
                pause
                ;;
            7)
                echo
                bold "Boot to TWRP recovery:"
                echo "  1. Unplug the device from USB/power now."
                echo "  2. This will run boot-recovery.sh -- once it's running and waiting,"
                echo "     connect the device to your PC."
                echo
                if require_file "$AMONET_DIR/boot-recovery.sh" "amonet/README.md"; then
                    read -r -p "Device unplugged? Press enter to run boot-recovery.sh..." _
                    (cd "$AMONET_DIR" && sudo ./boot-recovery.sh)
                    echo
                    yellow "Success = constantly blinking cyan LED (TWRP)."
                fi
                echo
                yellow "If that didn't work, follow the manual instructions instead:"
                echo "  Unplug the device, reconnect it, and as soon as the blue LED"
                echo "  appears, press and hold the mute (microphone) button for about"
                echo "  5 seconds."
                pause
                ;;
            8)
                echo
                if check_adb; then
                    adb shell "reboot-amonet" </dev/null
                    yellow "(adb reboot won't work for this -- reboot-amonet is the right call)"
                else
                    yellow "No adb device. Manual option:"
                    echo "  Unplug, reconnect, and ~3s after the blue LED appears, hold the"
                    echo "  action (circle) button for about 5 seconds."
                fi
                pause
                ;;
            0|"") return ;;
            *) yellow "unrecognized option"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
health_check() {
    check_adb || return 1
    echo
    bold "-- Wyoming satellite --"
    echo "init.svc.wyoming-sat = $(adb shell 'getprop init.svc.wyoming-sat' </dev/null | tr -d '\r')"
    adb shell 'busybox netstat -ltnp 2>/dev/null | busybox grep -E "10700|8928"' </dev/null | tr -d '\r'
    echo
    bold "-- WAN block --"
    run_step "$SCRIPT_DIR/wan-block.sh" status
    echo
    bold "-- WiFi --"
    adb shell 'ip route' </dev/null | tr -d '\r'
    echo
    bold "-- Wake word --"
    adb shell 'settings get secure alexa_selected_wakeword_model' </dev/null | tr -d '\r'
}

# ---------------------------------------------------------------------------
# ModemManager control (host-side -- this computer, not the Echo)
# ---------------------------------------------------------------------------
# ModemManager auto-probes USB devices that look like modems, including
# things with a cdc_acm/serial-like interface -- which is exactly what shows
# up during Amonet's BROM/Preloader stages and briefly during some reboots.
# It's a candidate suspect any time adb/fastboot connectivity is flaky; this
# menu makes it easy to check/rule it out without hunting for systemctl
# incantations each time.
modemmanager_menu() {
    local script="$SCRIPT_DIR/modemmanager-toggle.sh"
    while true; do
        banner
        bold "-- ModemManager control (host-side) --"
        echo
        if [[ -x "$script" ]]; then
            "$script" status
        else
            red "Missing: $script"
        fi
        echo
        echo "  1) Status"
        echo "  2) Disable (stop + mask -- won't come back until re-enabled)"
        echo "  3) Re-enable (unmask + start)"
        echo "  0) Back"
        echo
        read_menu "#? "
        case "$REPLY_CHOICE" in
            1) run_step "$script" status; pause ;;
            2) run_step "$script" disable; pause ;;
            3) run_step "$script" enable; pause ;;
            0|"") return ;;
            *) yellow "unrecognized option"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Bluetooth manager
# ---------------------------------------------------------------------------
# This Android version has no built-in scriptable pairing interface (no
# bluetoothctl/cmd bluetooth). Scan/pair here are driven by Jam's own tiny
# headless companion app (bt-app/, jam-bt.apk) -- install it once (option 7)
# before scan/pair will work. Everything else (adapter on/off, viewing real
# bonded devices filtered out of a much larger scan-cache list, disconnect,
# remove) works without the app.
bluetooth_menu() {
    local script="$SCRIPT_DIR/bluetooth-manager.sh"
    while true; do
        banner
        bold "-- Bluetooth manager --"
        echo
        if [[ -x "$script" ]]; then
            "$script" status
        else
            red "Missing: $script"
        fi
        echo
        echo "  1) Status"
        echo "  2) List paired devices"
        echo "  3) Enable adapter"
        echo "  4) Disable adapter"
        echo "  5) Disconnect (restarts the BT stack -- no per-device disconnect"
        echo "     command exists on this Android version)"
        echo "  6) Remove a paired device"
        echo "  7) Install/reinstall the scan+pair companion app"
        echo "  8) Scan for nearby devices (~12s)"
        echo "  9) Pair with a device (also connects audio)"
        echo "  10) Play a test sound (notification stream -- talking to the"
        echo "      Echo directly is a more reliable connectivity check)"
        echo "  0) Back"
        echo
        read_menu "#? "
        case "$REPLY_CHOICE" in
            1) run_step "$script" status; pause ;;
            2) run_step "$script" list; pause ;;
            3) run_step "$script" enable; pause ;;
            4) run_step "$script" disable; pause ;;
            5) run_step "$script" disconnect; pause ;;
            6)
                read -r -p "MAC address to remove (AA:BB:CC:DD:EE:FF): " BT_MAC
                [[ -n "$BT_MAC" ]] && run_step "$script" remove "$BT_MAC"
                pause
                ;;
            7) run_step "$script" install-app; pause ;;
            8) run_step "$script" scan; pause ;;
            9)
                read -r -p "MAC address to pair with (AA:BB:CC:DD:EE:FF): " BT_MAC
                [[ -n "$BT_MAC" ]] && run_step "$script" pair "$BT_MAC"
                pause
                ;;
            10) run_step "$script" play-test; pause ;;
            0|"") return ;;
            *) yellow "unrecognized option"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# WAN block
# ---------------------------------------------------------------------------
wan_block_menu() {
    local script="$SCRIPT_DIR/wan-block.sh"
    while true; do
        banner
        bold "-- WAN block --"
        echo
        run_step "$script" status
        echo
        echo "  1) Status"
        echo "  2) Enable"
        echo "  3) Disable"
        echo "  0) Back"
        echo
        read_menu "#? "
        case "$REPLY_CHOICE" in
            1) run_step "$script" status; pause ;;
            2) run_step "$script" enable; pause ;;
            3) run_step "$script" disable; pause ;;
            0|"") return ;;
            *) yellow "unrecognized option"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        banner
        if command -v adb >/dev/null; then
            local state serial
            state=$(adb get-state 2>/dev/null </dev/null || true)
            if [[ -n "$state" ]]; then
                serial=$(adb get-serialno 2>/dev/null </dev/null)
                case "$state" in
                    device)   green  "Connected: $serial (booted)" ;;
                    recovery) yellow "Connected: $serial (TWRP recovery)" ;;
                    sideload) yellow "Connected: $serial (TWRP sideload)" ;;
                    *)        yellow "Connected: $serial (state: $state)" ;;
                esac
            else
                red "No adb device detected."
            fi
        fi
        echo
        bold "  Setup"
        echo "  1) Amonet unlock (submenu)"
        echo "  2) Wyoming Package: install / reinstall (submenu)"
        echo
        bold "  Device configuration"
        echo "  3) WiFi credentials"
        echo "  4) Wake word switcher"
        echo "  5) Bluetooth manager (submenu)"
        echo
        bold "  Network / security"
        echo "  6) WAN block (submenu)"
        echo
        bold "  Diagnostics"
        echo "  7) Quick health check"
        echo
        bold "  Host-side troubleshooting"
        echo "  8) Fix flaky USB/adb connection"
        echo "  9) ModemManager control (submenu)"
        echo
        echo "  10) Quit"
        echo
        read_menu "#? "
        case "$REPLY_CHOICE" in
            1) amonet_menu ;;
            2) wyoming_menu ;;
            3) run_step "$SCRIPT_DIR/wifi-credentials.sh"; pause ;;
            4) run_step "$SCRIPT_DIR/set-wake-word.sh"; pause ;;
            5) bluetooth_menu ;;
            6) wan_block_menu ;;
            7) health_check; pause ;;
            8) run_step "$SCRIPT_DIR/fix-adb-udev.sh"; pause ;;
            9) modemmanager_menu ;;
            10) echo "bye"; exit 0 ;;
            *) yellow "unrecognized option"; sleep 1 ;;
        esac
    done
}

main_menu
