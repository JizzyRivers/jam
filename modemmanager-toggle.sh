#!/usr/bin/env bash
# Check/disable/re-enable ModemManager (host-side, not the Echo).
#
# ModemManager auto-probes any USB device that looks like it might be a
# modem (including things with a cdc_acm/serial-like interface, which shows
# up during Amonet's BROM/Preloader stages and briefly during some reboots).
# It's a candidate suspect any time adb/fastboot connectivity is flaky and
# ModemManager is running -- this gives a quick way to check/rule it out
# without hunting for the right systemctl incantation each time.
#
# Usage:
#   ./modemmanager-toggle.sh status
#   ./modemmanager-toggle.sh disable   # stop + mask (survives reboots,
#                                       # blocks D-Bus auto-activation too)
#   ./modemmanager-toggle.sh enable    # unmask + start

set -uo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

command -v systemctl >/dev/null || die "systemctl not found -- is this a systemd host?"

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null || die "not root and sudo not available -- re-run this as root"
    SUDO="sudo"
fi

unit_exists() {
    systemctl list-unit-files ModemManager.service >/dev/null 2>&1 \
        && systemctl list-unit-files ModemManager.service 2>/dev/null | grep -q ModemManager
}

do_status() {
    if ! unit_exists; then
        yellow "ModemManager isn't installed on this system -- nothing to check."
        return 0
    fi
    local active enabled
    active=$(systemctl is-active ModemManager 2>/dev/null || true)
    enabled=$(systemctl is-enabled ModemManager 2>/dev/null || true)
    case "$active" in
        active)  red    "ModemManager is currently RUNNING (active)." ;;
        *)       green  "ModemManager is currently stopped ($active)." ;;
    esac
    case "$enabled" in
        masked)   green  "  boot state: masked (won't auto-start, D-Bus activation blocked)." ;;
        disabled) yellow "  boot state: disabled (won't start at boot, but D-Bus can still auto-activate it on demand)." ;;
        enabled)  red    "  boot state: enabled (will start at boot)." ;;
        *)        yellow "  boot state: $enabled" ;;
    esac
}

do_disable() {
    unit_exists || { yellow "ModemManager isn't installed -- nothing to disable."; return 0; }
    $SUDO systemctl stop ModemManager 2>/dev/null || true
    # Plain "disable" isn't enough -- ModemManager is commonly D-Bus
    # activatable, so something requesting its bus name can still spin it
    # back up on demand even when "disabled". Mask blocks that too.
    $SUDO systemctl mask ModemManager || die "failed to mask ModemManager"
    green "ModemManager stopped and masked (won't come back until re-enabled)."
}

do_enable() {
    unit_exists || { yellow "ModemManager isn't installed -- nothing to enable."; return 0; }
    $SUDO systemctl unmask ModemManager 2>/dev/null || true
    $SUDO systemctl enable --now ModemManager || die "failed to enable/start ModemManager"
    green "ModemManager re-enabled and started."
}

case "${1:-}" in
    status)  do_status ;;
    disable) do_disable ;;
    enable)  do_enable ;;
    *) die "usage: $0 {status|disable|enable}" ;;
esac
