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
                yellow "From rainbow fastboot:"
                echo
                if require_file "$WYOMING_DIR/flash-ha-wyoming-boot.sh" "wyomingpackage/README.md"; then
                    (cd "$WYOMING_DIR" && ./flash-ha-wyoming-boot.sh)
                fi
                echo
                yellow "The Echo will boot up. Wait until it's in setup mode before continuing."
                pause
                ;;
            6)
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
                    (cd "$WYOMING_DIR" && ./install.sh)
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
                adb shell "twrp sideload" </dev/null &
                sleep 2
                adb sideload "$AMONET_DIR/$FW_FILE" </dev/null
                adb shell "twrp install /sdcard/f1r30s.zip" </dev/null
                echo
                yellow "Success = LED pulses green after each package installs. Reboot when ready --"
                yellow "adb is forcibly enabled by the exploit, so it'll be reachable once booted."
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
        echo "  1) Amonet unlock (submenu)"
        echo "  2) Wyoming Package: install / reinstall (submenu)"
        echo "  3) WiFi credentials"
        echo "  4) Wake word switcher"
        echo "  5) WAN block: enable"
        echo "  6) WAN block: disable"
        echo "  7) WAN block: status"
        echo "  8) Quick health check"
        echo "  9) Fix flaky USB/adb connection (host-side)"
        echo "  10) Quit"
        echo
        read_menu "#? "
        case "$REPLY_CHOICE" in
            1) amonet_menu ;;
            2) wyoming_menu ;;
            3) run_step "$SCRIPT_DIR/wifi-credentials.sh"; pause ;;
            4) run_step "$SCRIPT_DIR/set-wake-word.sh"; pause ;;
            5) run_step "$SCRIPT_DIR/wan-block.sh" enable; pause ;;
            6) run_step "$SCRIPT_DIR/wan-block.sh" disable; pause ;;
            7) run_step "$SCRIPT_DIR/wan-block.sh" status; pause ;;
            8) health_check; pause ;;
            9) run_step "$SCRIPT_DIR/fix-adb-udev.sh"; pause ;;
            10) echo "bye"; exit 0 ;;
            *) yellow "unrecognized option"; sleep 1 ;;
        esac
    done
}

main_menu
