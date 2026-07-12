#!/usr/bin/env bash
# View/change WiFi credentials on a de-Amazonized Echo Dot directly, without
# the Alexa app or OOBE flow.
#
# wpa_cli's control socket hangs on this build for reasons we couldn't root
# cause, so this edits /data/misc/wifi/wpa_supplicant.conf directly (plaintext,
# writable as root) and restarts the WiFi radio via `svc wifi` to force a
# fresh read -- this works reliably and doesn't depend on wpa_cli at all.
#
# Since adb here runs over USB, changing WiFi never risks losing the
# connection to the device itself.

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

CONF=/data/misc/wifi/wpa_supplicant.conf

command -v adb >/dev/null || die "adb not in PATH"

ADB_STATE=$(adb get-state 2>/dev/null </dev/null || true)
[[ "$ADB_STATE" == "device" ]] || die "no adb device detected"

CTX=$(adb shell 'cat /proc/self/attr/current 2>/dev/null' </dev/null | tr -d '\r\0')
[[ "$CTX" == "u:r:su:s0" ]] || die "adb shell context is '$CTX', expected u:r:su:s0 (root)"

[[ -t 1 ]] && clear
bold "╔══════════════════════════════════════════╗"
bold "║          Echo Dot WiFi Credentials        ║"
bold "╚══════════════════════════════════════════╝"
echo

CURRENT_CONF=$(adb shell "cat $CONF" 2>/dev/null </dev/null | tr -d '\r')
[[ -n "$CURRENT_CONF" ]] || die "could not read $CONF"

CURRENT_SSID=$(grep -m1 '^\s*ssid=' <<<"$CURRENT_CONF" | sed -E 's/^\s*ssid="(.*)"$/\1/')
bold "Currently configured network: ${CURRENT_SSID:-<none found>}"
echo

read -r -p "New SSID: " NEW_SSID
[[ -n "$NEW_SSID" ]] || die "SSID cannot be empty"
read -r -s -p "New password (leave blank for an open network): " NEW_PSK
echo
echo

if [[ -n "$NEW_PSK" ]]; then
    if [[ "${#NEW_PSK}" -lt 8 ]]; then
        die "WPA-PSK passwords must be at least 8 characters"
    fi
fi

read -r -p "Set network to '$NEW_SSID'? [Y/n] " ans
[[ -z "$ans" || "$ans" =~ ^[Yy] ]] || { yellow "cancelled."; exit 0; }

# ---------------------------------------------------------------------------
# Build the replacement network{} block. We keep everything above the first
# "network={" line (global settings: device_name, ctrl_interface, etc) and
# replace all network blocks with a single new one.
# ---------------------------------------------------------------------------
TMP_CONF=$(mktemp)
awk '/^network=\{/{exit} {print}' <<<"$CURRENT_CONF" > "$TMP_CONF"

{
    echo "network={"
    echo "	ssid=\"$NEW_SSID\""
    if [[ -n "$NEW_PSK" ]]; then
        echo "	psk=\"$NEW_PSK\""
        echo "	key_mgmt=WPA-PSK"
    else
        echo "	key_mgmt=NONE"
    fi
    echo "	priority=31"
    echo "}"
} >> "$TMP_CONF"

echo "Backing up current config and writing new one..."
adb shell "cp $CONF ${CONF}.bak-\$(date +%s)" </dev/null || true
adb push "$TMP_CONF" /data/local/tmp/wpa_supplicant.conf.new >/dev/null </dev/null
adb shell "cp /data/local/tmp/wpa_supplicant.conf.new $CONF && chown wifi:wifi $CONF && chmod 0660 $CONF && restorecon $CONF" </dev/null
rm -f "$TMP_CONF"

echo "Restarting WiFi radio..."
adb shell "svc wifi disable" </dev/null
sleep 3
adb shell "svc wifi enable" </dev/null

echo "Waiting for reconnection (up to 30s)..."
WAITED=0
CONNECTED=0
while [[ "$WAITED" -lt 30 ]]; do
    sleep 3
    WAITED=$((WAITED + 3))
    ROUTE=$(adb shell "ip route" 2>/dev/null </dev/null | tr -d '\r' || true)
    if grep -q "^default" <<<"$ROUTE"; then
        CONNECTED=1
        break
    fi
done

echo
if [[ "$CONNECTED" -eq 1 ]]; then
    green "SUCCESS: connected, got a default route after ${WAITED}s."
    green "New network: $NEW_SSID"
else
    red "Did not get a default route within 30s -- '$NEW_SSID' may be wrong,"
    red "out of range, or using unsupported security."
    yellow "A backup of the previous config was saved on-device as ${CONF}.bak-<timestamp>."
    yellow "Restore it manually (cp it back over $CONF, chown wifi:wifi, restorecon, svc wifi disable/enable) if needed."
fi
