#!/usr/bin/env bash
# Manage Bluetooth on a de-Amazonized Echo Dot (HA/Wyoming boot image).
#
# This build (Android 5.1.1 / API 22) predates Android's `cmd`/
# `bluetoothctl`-style scriptable Bluetooth interface, so there's no shell
# command to drive scan/pair directly. bt-app/ is Jam's own tiny headless
# companion app (BluetoothAdapter.startDiscovery()/BluetoothDevice.
# createBond(), no UI -- the Echo has no screen anyway) that closes that
# gap; scan/pair below drive it via `am startservice` (NOT `am broadcast` --
# broadcasts to its receiver were reliably swallowed somewhere between
# delivery and the receiver's onReceive(), confirmed live across repeated
# attempts, while a direct startservice call reliably reached the app every
# time). See bt-app/README or its source comments for why.
#
# Usage:
#   ./bluetooth-manager.sh status
#   ./bluetooth-manager.sh enable
#   ./bluetooth-manager.sh disable
#   ./bluetooth-manager.sh list
#   ./bluetooth-manager.sh disconnect        # kicks the whole BT stack --
#                                             # blunt, but this Android
#                                             # version has no per-device
#                                             # disconnect shell command
#   ./bluetooth-manager.sh remove <MAC>       # forget a paired device
#   ./bluetooth-manager.sh install-app        # push/install bt-app/jam-bt.apk
#   ./bluetooth-manager.sh scan               # ~12s discovery, prints found devices
#   ./bluetooth-manager.sh pair <MAC>         # pair with a discovered device

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BT_APK="$SCRIPT_DIR/bt-app/jam-bt.apk"
BT_PKG=com.jam.bt

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

BT_CONFIG=/data/misc/bluedroid/bt_config.xml

command -v adb >/dev/null || die "adb not in PATH"

adb_out_retry() {
    local tries=0 out
    while true; do
        out=$("$@" </dev/null 2>/dev/null | tr -d '\r\0')
        if [[ -n "$out" ]]; then
            printf '%s' "$out"
            return 0
        fi
        tries=$((tries + 1))
        [[ "$tries" -ge 8 ]] && return 1
        sleep 3
    done
}

adb_retry() {
    local tries=0
    until "$@" </dev/null; do
        tries=$((tries + 1))
        if [[ "$tries" -ge 10 ]]; then
            return 1
        fi
        yellow "  (adb hiccup, retrying: $* -- attempt $tries/10)"
        sleep 3
    done
    return 0
}

ADB_STATE=$(adb_out_retry adb get-state || true)
[[ "$ADB_STATE" == "device" ]] || die "no adb device detected. Plug in the Echo and unlock/authorize it first."

CTX=$(adb_out_retry adb shell 'cat /proc/self/attr/current 2>/dev/null')
[[ "$CTX" == "u:r:su:s0" ]] || die "adb shell context is '$CTX', expected u:r:su:s0 (root). Is this the HA/Wyoming boot image?"

do_status() {
    bold "-- Adapter --"
    adb shell 'dumpsys bluetooth_manager 2>/dev/null' </dev/null | tr -d '\r' \
        | busybox awk '/^enabled:|^state:|^address:|^name:/ {print}'
    echo
    bold "-- Connections (A2DP / headset profiles) --"
    adb shell 'dumpsys bluetooth_manager 2>/dev/null' </dev/null | tr -d '\r' \
        | busybox awk '
            /^Profile: (A2dpService|HeadsetService)/ { p=$0; next }
            /mCurrentDevice:|mTargetDevice:|curState=/ { if (p) { print p": "$0; p="" } }
        '
    echo
    do_list
}

do_list() {
    bold "-- Paired (bonded) devices --"
    local xml
    xml=$(adb shell "cat $BT_CONFIG 2>/dev/null" </dev/null | tr -d '\r')
    [[ -n "$xml" ]] || { yellow "could not read $BT_CONFIG -- BT stack may not have run yet."; return 0; }
    # This same config also caches every device ever SEEN during a scan
    # (classic inquiry or BLE) -- on an Echo that's often hundreds of
    # entries (neighbors' Echo Dots, passing phones, etc), NOT devices this
    # unit is actually bonded to. Confirmed live: a freshly-flashed unit
    # with zero real pairings still listed ~300 scan-cache entries here,
    # none of them carrying any link-key material. Only trust a section as
    # a real pairing if it has a LinkKey/LE_KEY_* tag -- that's the actual
    # bonding evidence, not mere presence in this cache.
    # Uses only sub()/gsub() (no gawk-only 3-arg match()) since busybox awk
    # is plain POSIX awk, not gawk.
    #
    # Nesting must be tracked by distinguishing a PURE opener/closer line
    # (nothing else on it) from a single-line leaf that both opens and
    # closes on the same line (e.g. "<N1 Tag=\"Timestamp\" ...>123</N1>").
    # An earlier version treated any line ending in "</N#>" as the block's
    # own closing tag -- which misfired on the very first leaf child inside
    # a device's block (Timestamp always comes before Name/LinkKey), exiting
    # before Name or LinkKey were ever seen. Confirmed live: a genuinely
    # bonded device (with LinkKey) still printed nothing under that logic.
    echo "$xml" | busybox awk '
        function is_mac(s) {
            return s ~ /^[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]$/
        }
        !in_dev && /^[ \t]*<N[0-9]+ Tag="[0-9a-fA-F:]+">[ \t]*$/ {
            line = $0
            sub(/^.*Tag="/, "", line)
            sub(/".*$/, "", line)
            if (line != "Local" && is_mac(line)) {
                mac = line; in_dev = 1; depth = 1; name = ""; bonded = 0
                next
            }
        }
        in_dev {
            if ($0 ~ /^[ \t]*<N[0-9]+ [^>]*>[ \t]*$/) { depth++; next }
            if ($0 ~ /^[ \t]*<\/N[0-9]+>[ \t]*$/) {
                depth--
                if (depth == 0) {
                    if (mac != "" && bonded) print mac"  "name
                    in_dev = 0; mac = ""; bonded = 0
                }
                next
            }
            if ($0 ~ /Tag="Name"/) {
                line = $0
                sub(/^[^>]*>/, "", line)
                sub(/<.*$/, "", line)
                name = line
            }
            if ($0 ~ /Tag="LinkKey"/ || $0 ~ /Tag="LE_KEY_/) bonded = 1
        }
    ' 2>/dev/null
    echo "(only entries with real link-key material are shown -- this file also"
    echo " caches every device merely SEEN during a scan, which is not the same"
    echo " as paired; run the 'raw' subcommand to inspect $BT_CONFIG directly)"
}

do_raw() {
    adb shell "cat $BT_CONFIG 2>/dev/null" </dev/null | tr -d '\r'
}

do_enable() {
    adb_retry adb shell 'am broadcast -a com.amazon.device.csmbluetooth.action.ENABLE_BT_ADAPTER' \
        || die "could not send enable broadcast after retries"
    green "Sent ENABLE_BT_ADAPTER."
}

do_disable() {
    adb_retry adb shell 'am broadcast -a com.amazon.device.csmbluetooth.action.DISABLE_BT_ADAPTER' \
        || die "could not send disable broadcast after retries"
    green "Sent DISABLE_BT_ADAPTER."
}

do_disconnect() {
    yellow "This Android version has no per-device disconnect shell command --"
    yellow "restarting the whole Bluetooth stack instead (disconnects everything,"
    yellow "reconnects automatically afterward for anything still paired/in range)."
    adb_retry adb shell 'am force-stop com.android.bluetooth' \
        || die "could not force-stop the Bluetooth stack after retries"
    green "Bluetooth stack restarted."
}

do_remove() {
    local mac="${1:-}"
    [[ -n "$mac" ]] || die "usage: $0 remove <MAC address>"
    [[ "$mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || die "'$mac' doesn't look like a MAC address (expected AA:BB:CC:DD:EE:FF)"

    local xml
    xml=$(adb shell "cat $BT_CONFIG 2>/dev/null" </dev/null | tr -d '\r')
    [[ -n "$xml" ]] || die "could not read $BT_CONFIG"

    if ! grep -qiF "Tag=\"$mac\"" <<<"$xml"; then
        die "no device found with MAC $mac at all (check './bluetooth-manager.sh list' for the exact address)"
    fi
    # Presence in this file isn't enough -- it also caches every device ever
    # merely SEEN during a scan (hundreds of entries on a typical Echo).
    # Only proceed if this device's own block actually has bond evidence
    # (a LinkKey/LE_KEY_* tag), matching do_list's stricter definition.
    # Same pure-opener/pure-closer distinction as do_list (a single-line
    # leaf like "<N1 Tag=\"Timestamp\" ...>123</N1>" must not be mistaken
    # for the device block's own closing tag -- see do_list's comment).
    local block_is_bonded
    block_is_bonded=$(echo "$xml" | busybox awk -v mac="$mac" '
        BEGIN { IGNORECASE = 1 }
        $0 ~ "Tag=\"" mac "\"" && !in_dev { in_dev = 1; depth = 1; next }
        in_dev {
            if ($0 ~ /Tag="LinkKey"/ || $0 ~ /Tag="LE_KEY_/) { print "yes"; exit }
            if ($0 ~ /^[ \t]*<N[0-9]+ [^>]*>[ \t]*$/) { depth++; next }
            if ($0 ~ /^[ \t]*<\/N[0-9]+>[ \t]*$/) {
                depth--
                if (depth == 0) exit
            }
        }
    ')
    if [[ "$block_is_bonded" != "yes" ]]; then
        die "$mac has been SEEN (scan cache) but was never actually bonded/paired -- nothing to remove"
    fi

    yellow "Stopping Bluetooth before editing its config..."
    adb_retry adb shell 'am force-stop com.android.bluetooth' || die "could not stop Bluetooth after retries"
    sleep 1

    local tmp
    tmp=$(mktemp)
    # Same pure-opener/pure-closer distinction as do_list/block_is_bonded --
    # a single-line leaf must not be mistaken for the block's own closer.
    echo "$xml" | busybox awk -v mac="$mac" '
        BEGIN { IGNORECASE = 1 }
        $0 ~ "Tag=\"" mac "\"" && !in_dev { in_dev = 1; depth = 1; next }
        in_dev {
            if ($0 ~ /^[ \t]*<N[0-9]+ [^>]*>[ \t]*$/) { depth++; next }
            if ($0 ~ /^[ \t]*<\/N[0-9]+>[ \t]*$/) { depth--; if (depth == 0) { in_dev = 0 }; next }
            next
        }
        { print }
    ' > "$tmp"

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        die "editing produced an empty file -- refusing to push this, config format may not match what this script expects. Nothing was changed on-device."
    fi

    adb_retry adb push "$tmp" /data/local/tmp/bt_config.xml.new >/dev/null || { rm -f "$tmp"; die "push failed after retries"; }
    adb_retry adb shell "cp $BT_CONFIG $BT_CONFIG.orig.jam 2>/dev/null; cp /data/local/tmp/bt_config.xml.new $BT_CONFIG && chmod 0660 $BT_CONFIG && chown bluetooth:net_bt_stack $BT_CONFIG && restorecon $BT_CONFIG" \
        || { rm -f "$tmp"; die "could not install updated config after retries"; }
    rm -f "$tmp"

    adb_retry adb shell 'am start-service com.android.bluetooth/.btservice.AdapterService' >/dev/null 2>&1 || true
    green "Removed $mac from paired devices. Bluetooth stack was restarted; a backup of the"
    green "previous config is at $BT_CONFIG.orig.jam on-device if anything looks wrong."
}

do_install_app() {
    [[ -f "$BT_APK" ]] || die "missing $BT_APK -- run bt-app/build.sh first (see bt-app/build.sh header for requirements)"
    adb_retry adb install -r "$BT_APK" || die "install failed after retries"
    green "Installed $BT_PKG."
}

require_app() {
    local installed
    installed=$(adb_out_retry adb shell "pm list packages $BT_PKG" || true)
    if [[ "$installed" != *"$BT_PKG"* ]]; then
        die "$BT_PKG isn't installed on the device -- run '$0 install-app' first"
    fi
}

do_scan() {
    require_app
    yellow "Scanning for ~12s..."
    adb shell 'logcat -c' </dev/null || true
    adb_retry adb shell "am startservice -n $BT_PKG/.JamBtService -a $BT_PKG.SCAN" \
        || die "could not start scan after retries"
    sleep 13
    local log
    log=$(adb shell 'logcat -d -s JamBT:*' </dev/null | tr -d '\r')
    if ! grep -q "SCAN_DONE" <<<"$log"; then
        yellow "scan may not have finished cleanly -- showing whatever was captured:"
    fi
    bold "-- Found devices --"
    grep "FOUND:" <<<"$log" | sed -E 's/.*FOUND: /  /' | sort -u -t' ' -k1,1
}

do_pair() {
    local mac="${1:-}"
    [[ -n "$mac" ]] || die "usage: $0 pair <MAC address>"
    [[ "$mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || die "'$mac' doesn't look like a MAC address (expected AA:BB:CC:DD:EE:FF)"
    require_app
    yellow "Pairing with $mac..."
    adb shell 'logcat -c' </dev/null || true
    adb_retry adb shell "am startservice -n $BT_PKG/.JamBtService -a $BT_PKG.PAIR --es mac $mac" \
        || die "could not start pairing after retries"
    sleep 8
    local log result a2dp_result
    log=$(adb shell 'logcat -d -s JamBT:*' </dev/null | tr -d '\r')
    result=$(grep "BOND_STATE: $mac ->" <<<"$log" | tail -1 | sed -E 's/.*-> //')
    a2dp_result=$(grep "A2DP_STATE: $mac ->" <<<"$log" | tail -1 | sed -E 's/.*-> //')
    # An already-bonded device (re-pairing after a power cycle, say) never
    # fires a new BOND_STATE_CHANGED -- the app connects A2DP directly in
    # that case instead, so a successful outcome can show up as only an
    # A2DP_STATE result with no BOND_STATE line at all. Check both.
    if [[ "$a2dp_result" == "CONNECTED" ]]; then
        green "Connected to $mac (audio profile is live)."
    else
    case "$result" in
        BONDED)  green "Paired successfully with $mac." ;;
        BONDING) yellow "Still bonding -- check './bluetooth-manager.sh list' shortly, or a PIN/confirmation may be needed on the speaker itself." ;;
        NONE)    red "Pairing failed or was rejected by $mac." ;;
        *)       yellow "No definitive result yet -- check './bluetooth-manager.sh list' or the log:"; echo "$log" | grep -i "$mac\|PAIR" ;;
    esac
    fi
}

do_play_test() {
    require_app
    adb_retry adb shell "am startservice -n $BT_PKG/.JamBtService -a $BT_PKG.PLAY_TEST" \
        || die "could not start test playback after retries"
    green "Playing the default notification sound -- listen for it on whichever device is currently the active audio route (check './bluetooth-manager.sh status' to see what that is)."
}

case "${1:-}" in
    status)      do_status ;;
    list)        do_list ;;
    raw)         do_raw ;;
    enable)      do_enable ;;
    disable)     do_disable ;;
    disconnect)  do_disconnect ;;
    remove)      do_remove "${2:-}" ;;
    install-app) do_install_app ;;
    scan)        do_scan ;;
    pair)        do_pair "${2:-}" ;;
    play-test)   do_play_test ;;
    *) die "usage: $0 {status|list|raw|enable|disable|disconnect|remove <MAC>|install-app|scan|pair <MAC>|play-test}" ;;
esac
