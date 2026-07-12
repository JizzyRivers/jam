#!/usr/bin/env bash
# On-device WAN blocking for a de-Amazonized Echo Dot (HA/Wyoming boot image).
#
# Patches /system/bin/firewall.sh so the device rejects all outbound WiFi
# traffic EXCEPT its local subnet (auto-detected). This is self-contained on
# the device -- no router/DHCP-server cooperation needed, unlike network-level
# tricks (Pi-hole DNS blocklists, gateway overrides, etc).
#
# Usage:
#   ./wan-block.sh enable    # block WAN, allow LAN only
#   ./wan-block.sh disable   # restore full WAN access
#   ./wan-block.sh status    # show current state

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

FW=/system/bin/firewall.sh
MARKER_START="# >>> wan-block.sh managed block >>>"
MARKER_END="# <<< wan-block.sh managed block <<<"
CATCHALL_LINE='    $IPTABLES -A OUTPUT -o wlan0 -j ACCEPT'

command -v adb >/dev/null || die "adb not in PATH"

# This USB link drops mid-command intermittently; retry these read-only
# pre-flight checks a few times before concluding the device really isn't
# there, rather than dying on the first hiccup.
adb_out_retry() {
    local tries=0 out
    while true; do
        out=$("$@" </dev/null 2>/dev/null | tr -d '\r\0')
        if [[ -n "$out" ]]; then
            printf '%s' "$out"
            return 0
        fi
        tries=$((tries + 1))
        [[ "$tries" -ge 5 ]] && return 1
        sleep 2
    done
}

ADB_STATE=$(adb_out_retry adb get-state || true)
[[ "$ADB_STATE" == "device" ]] || die "no adb device detected"

CTX=$(adb_out_retry adb shell 'cat /proc/self/attr/current 2>/dev/null')
[[ "$CTX" == "u:r:su:s0" ]] || die "adb shell context is '$CTX', expected u:r:su:s0 (root)"

detect_subnet() {
    local tries=0 out
    while true; do
        out=$(adb shell "ip route" </dev/null 2>/dev/null | tr -d '\r' \
            | busybox awk '/scope link/ && / wlan0 / {print $1; exit}')
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
        tries=$((tries + 1))
        [[ "$tries" -ge 5 ]] && return 1
        sleep 2
    done
}

fetch_firewall() {
    local tries=0 out
    while true; do
        out=$(adb shell "cat $FW" </dev/null 2>/dev/null | tr -d '\r')
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
        tries=$((tries + 1))
        [[ "$tries" -ge 5 ]] && return 1
        sleep 2
    done
}

current_state() {
    local content
    content=$(fetch_firewall)
    if grep -qF "$MARKER_START" <<<"$content"; then
        echo "blocked"
    else
        echo "open"
    fi
}

remount_rw() { adb shell "mount -o remount,rw /system" </dev/null >/dev/null; }
remount_ro() { adb shell "sync; mount -o remount,ro /system" </dev/null >/dev/null 2>&1 || {
    sleep 2
    adb shell "sync; mount -o remount,ro /system" </dev/null >/dev/null
}; }

apply_reload() {
    adb shell "sh $FW start default" </dev/null >/dev/null 2>&1 || true
}

do_enable() {
    local subnet content tmp state
    state=$(current_state)
    if [[ "$state" == "blocked" ]]; then
        yellow "already blocked."
        return 0
    fi

    subnet=$(detect_subnet)
    [[ -n "$subnet" ]] || die "could not auto-detect local subnet (ip route gave nothing on wlan0)"
    green "detected local subnet: $subnet"

    content=$(fetch_firewall)
    [[ -n "$content" ]] || die "could not read $FW"

    tmp=$(mktemp)
    # Insert our managed block immediately before the stock catch-all
    # "-A OUTPUT -o wlan0 -j ACCEPT" line. Everything destined for our
    # subnet is accepted first; everything else on wlan0 hits our REJECT
    # before ever reaching the stock ACCEPT line below it.
    awk -v subnet="$subnet" -v start="$MARKER_START" -v end="$MARKER_END" -v catchall="$CATCHALL_LINE" '
        index($0, catchall) == 1 && !done {
            print start
            print "    $IPTABLES -A OUTPUT -o wlan0 -d " subnet " -j ACCEPT"
            print "    $IPTABLES -A OUTPUT -o wlan0 -j REJECT --reject-with icmp-port-unreachable"
            print end
            done = 1
        }
        { print }
    ' <<<"$content" > "$tmp"

    grep -qF "$MARKER_START" "$tmp" || { rm -f "$tmp"; die "failed to locate insertion point in $FW (stock catch-all line not found -- has firewall.sh changed?)"; }

    remount_rw
    adb push "$tmp" /data/local/tmp/firewall.sh.new </dev/null >/dev/null
    adb shell "cp $FW $FW.orig.wanblock 2>/dev/null; cp /data/local/tmp/firewall.sh.new $FW && chmod 0755 $FW && restorecon $FW" </dev/null
    remount_ro
    rm -f "$tmp"

    apply_reload
    green "WAN blocked. LAN ($subnet) still allowed."
}

do_disable() {
    local content tmp state
    state=$(current_state)
    if [[ "$state" == "open" ]]; then
        yellow "already open."
        return 0
    fi

    content=$(fetch_firewall)
    tmp=$(mktemp)
    awk -v start="$MARKER_START" -v end="$MARKER_END" '
        $0 == start { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip { print }
    ' <<<"$content" > "$tmp"

    remount_rw
    adb push "$tmp" /data/local/tmp/firewall.sh.new </dev/null >/dev/null
    adb shell "cp /data/local/tmp/firewall.sh.new $FW && chmod 0755 $FW && restorecon $FW" </dev/null
    remount_ro
    rm -f "$tmp"

    apply_reload
    green "WAN access restored."
}

do_status() {
    local state
    state=$(current_state)
    if [[ "$state" == "blocked" ]]; then
        yellow "WAN is currently BLOCKED (LAN-only)."
    else
        green "WAN is currently OPEN."
    fi
}

case "${1:-}" in
    enable)  do_enable ;;
    disable) do_disable ;;
    status)  do_status ;;
    *) die "usage: $0 {enable|disable|status}" ;;
esac
