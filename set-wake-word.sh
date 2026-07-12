#!/usr/bin/env bash
# Change the wake word on a de-Amazonized Echo Dot (HA/Wyoming boot image).
#
# Switching to a wake word this Amazon account hasn't previously activated
# requires a one-time online DAVS entitlement check (checkVendableArtifact)
# -- Amazon's engine won't use a locally-bundled model until that check
# succeeds, even though the model files already exist on /system. This
# script automates the whole dance:
#   1. temporarily lift the on-device WAN block (via wan-block.sh)
#   2. write the new wake word into BOTH the persisted cache file
#      (the actual source of truth) and the secure setting (cosmetic mirror)
#   3. reboot and poll logs for the DAVS check result
#   4. re-apply the WAN block afterward, always, regardless of outcome
#
# Requires: adb, wan-block.sh in the same directory, a device already
# flashed per flash-ha-wyoming-boot.sh / install-wyoming.sh, connected via USB.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WANBLOCK="$SCRIPT_DIR/wan-block.sh"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

SETTING_KEY="alexa_selected_wakeword_model"
PREFS_FILE="/data/data/amazon.speech.sim/shared_prefs/amazon.speech.wakewordservice.wakewordinfoprovider.xml"
WAKE_WORDS=(alexa amazon computer echo ziggy)
DAVS_TIMEOUT_S=90

command -v adb >/dev/null || die "adb not in PATH"
[[ -x "$WANBLOCK" ]] || die "wan-block.sh not found next to this script ($WANBLOCK)"

# Re-applying the WAN block must never just give up -- a transient failure
# here (e.g. wlan0 not fully up yet right after reboot) must not leave the
# device sitting unblocked. Retry with backoff; only give up loudly.
reapply_wan_block() {
    local tries=0
    until "$WANBLOCK" enable; do
        tries=$((tries + 1))
        if [[ "$tries" -ge 15 ]]; then
            red "FATAL: could not re-apply the WAN block after $tries attempts."
            red "MANUAL INTERVENTION NEEDED -- this device may currently have unrestricted WAN access."
            red "Run '$WANBLOCK enable' by hand once the device is reachable."
            return 1
        fi
        yellow "wan-block enable failed (attempt $tries/15), retrying in 4s..."
        sleep 4
    done
    return 0
}

[[ -t 1 ]] && clear
bold "╔══════════════════════════════════════════╗"
bold "║        Echo Dot Wake Word Switcher        ║"
bold "╚══════════════════════════════════════════╝"
echo

echo "Checking for device..."
ADB_STATE=$(adb get-state 2>/dev/null </dev/null || true)
[[ "$ADB_STATE" == "device" ]] || die "no adb device detected. Plug in the Echo and unlock/authorize it first."

SERIAL=$(adb get-serialno 2>/dev/null </dev/null || echo "unknown")
green "  connected: $SERIAL"

CTX=$(adb shell 'cat /proc/self/attr/current 2>/dev/null' </dev/null | tr -d '\r\0')
[[ "$CTX" == "u:r:su:s0" ]] || die "adb shell context is '$CTX', expected u:r:su:s0 (root). Is this the HA/Wyoming boot image?"
green "  root context confirmed"
echo

CURRENT=$(adb shell "settings get secure $SETTING_KEY" 2>/dev/null </dev/null | tr -d '\r')
bold "Current wake word: ${CURRENT:-<unknown>}"
echo

echo "Available wake words:"
select CHOICE in "${WAKE_WORDS[@]}" "cancel"; do
    case "$CHOICE" in
        cancel|"")
            yellow "cancelled, nothing changed."
            exit 0
            ;;
        "$CURRENT")
            yellow "that's already the current wake word."
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

echo
yellow "Note: switching wake words requires a brief, one-time reconnection to"
yellow "the internet (Amazon's entitlement check) if this word hasn't been"
yellow "used on this Echo/account before. The WAN block is restored"
yellow "automatically afterward no matter what happens."
read -r -p "Set wake word to '$CHOICE'? [Y/n] " ans
[[ -z "$ans" || "$ans" =~ ^[Yy] ]] || { yellow "cancelled."; exit 0; }

# ---------------------------------------------------------------------------
# 1. Build the replacement shared_prefs file locally, preserving everything
#    except the active_wakewords field, then push it over.
# ---------------------------------------------------------------------------
echo
echo "Reading current wakeword-info cache..."
CURRENT_XML=$(adb shell "cat $PREFS_FILE" 2>/dev/null </dev/null | tr -d '\r')
[[ -n "$CURRENT_XML" ]] || die "could not read $PREFS_FILE"

TMP_XML=$(mktemp)
echo "$CURRENT_XML" | sed -E "s/active_wakewords&quot;:\[&quot;[a-z]+&quot;\]/active_wakewords\&quot;:[\&quot;$CHOICE\&quot;]/" > "$TMP_XML"

if ! grep -q "active_wakewords&quot;:\[&quot;$CHOICE&quot;\]" "$TMP_XML"; then
    rm -f "$TMP_XML"
    die "failed to patch active_wakewords in the cached prefs file (unexpected format?)"
fi

echo "Lifting WAN block for the entitlement check..."
"$WANBLOCK" enable >/dev/null 2>&1 || true   # ensure known state first (idempotent)
"$WANBLOCK" disable

adb push "$TMP_XML" /data/local/tmp/wwip_new.xml >/dev/null </dev/null
adb shell "cp /data/local/tmp/wwip_new.xml $PREFS_FILE; restorecon $PREFS_FILE" </dev/null
rm -f "$TMP_XML"
adb shell "settings put secure $SETTING_KEY $CHOICE" >/dev/null </dev/null

echo "Rebooting to apply..."
adb logcat -c 2>/dev/null </dev/null || true
adb reboot </dev/null

# ---------------------------------------------------------------------------
# 2. Wait for the device to come back, then poll for the DAVS result.
# ---------------------------------------------------------------------------
echo "Waiting for reboot..."
WAITED=0
until adb get-state 2>/dev/null </dev/null | grep -q device; do
    sleep 3
    WAITED=$((WAITED + 3))
    if [[ "$WAITED" -ge 120 ]]; then
        reapply_wan_block || true
        die "device did not come back online after 120s -- attempted to re-apply WAN block, verify manually"
    fi
done
green "back online after ${WAITED}s"

echo "Waiting for entitlement check (up to ${DAVS_TIMEOUT_S}s)..."
RESULT="timeout"
WAITED=0
while [[ "$WAITED" -lt "$DAVS_TIMEOUT_S" ]]; do
    sleep 5
    WAITED=$((WAITED + 5))
    adb shell "settings get secure $SETTING_KEY" >/dev/null 2>&1 </dev/null || true   # nudges the provider awake
    LOG=$(adb shell "logcat -d" 2>/dev/null </dev/null | tr -d '\r' || true)
    # Explicit denial: DAVS rejected this artifact for this account (a real
    # "no", not just "couldn't reach the network right now").
    if grep -qE "DAVS call failed.*ArtifactKey=$CHOICE, Response: \[\[UNAUTHORIZED" <<<"$LOG"; then
        RESULT="denied"
        break
    fi
    # Real success signal: this is the exact line observed when a wake word
    # actually activates (confirmed with the known-working "alexa" case) --
    # not just "no error seen yet", which is unreliable while a CONNECTION_FAILED
    # or similar transient DAVS failure could also produce no explicit denial.
    if grep -qiE "setCurrentWakeWordModel: ${CHOICE}_" <<<"$LOG"; then
        RESULT="authorized"
        break
    fi
done

# ---------------------------------------------------------------------------
# 3. Always re-apply the WAN block, regardless of what happened above.
# ---------------------------------------------------------------------------
echo
echo "Re-applying WAN block..."
reapply_wan_block

echo
case "$RESULT" in
    authorized)
        green "SUCCESS: '$CHOICE' passed the entitlement check and should now work offline."
        ;;
    denied)
        red "DENIED: Amazon rejected '$CHOICE' for this account/device (not just an offline artifact)."
        yellow "Reverting to the previous wake word ('$CURRENT')."
        REVERT_XML=$(mktemp)
        echo "$CURRENT_XML" > "$REVERT_XML"
        adb push "$REVERT_XML" /data/local/tmp/wwip_revert.xml >/dev/null </dev/null
        adb shell "cp /data/local/tmp/wwip_revert.xml $PREFS_FILE; restorecon $PREFS_FILE" </dev/null
        adb shell "settings put secure $SETTING_KEY $CURRENT" >/dev/null </dev/null
        rm -f "$REVERT_XML"
        adb reboot </dev/null
        yellow "Rebooting back to '$CURRENT'."
        ;;
    timeout)
        yellow "TIMED OUT waiting for a definitive result after ${DAVS_TIMEOUT_S}s."
        yellow "WAN block is re-applied either way. Check manually later --"
        yellow "if it never got authorized, re-run this script to retry."
        ;;
esac
