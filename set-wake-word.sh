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

# Retries a transient adb command a few times before giving up -- this USB
# link is known to drop mid-command intermittently (adb reporting "no
# devices/emulators found" or "error: closed" for no real reason). Used for
# every adb call between lifting the WAN block and re-applying it, since a
# `set -e` exit in that window would otherwise leave the device unblocked.
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

# Safety net: if this script exits for ANY reason (crashed adb call under
# set -e, Ctrl-C, whatever) after the WAN block has been lifted but before
# the deliberate re-apply near the end, re-apply it on the way out instead
# of silently leaving the device unblocked. Sourcing wan-block.sh directly
# (not the deliberate reapply_wan_block flow) since the trap can fire from
# a context where we don't know if the reboot/logs section ever ran.
WAN_BLOCK_SAFETY_NET=0
ensure_wan_block_on_exit() {
    local rc=$?
    if [[ "$WAN_BLOCK_SAFETY_NET" -eq 1 ]]; then
        red "Unexpected exit while the WAN block was lifted -- re-applying as a safety net."
        reapply_wan_block || true
    fi
    exit "$rc"
}
trap ensure_wan_block_on_exit EXIT

[[ -t 1 ]] && clear
bold "╔══════════════════════════════════════════╗"
bold "║        Echo Dot Wake Word Switcher        ║"
bold "╚══════════════════════════════════════════╝"
echo

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
        [[ "$tries" -ge 8 ]] && return 1
        sleep 3
    done
}

echo "Checking for device..."
ADB_STATE=$(adb_out_retry adb get-state || true)
[[ "$ADB_STATE" == "device" ]] || die "no adb device detected. Plug in the Echo and unlock/authorize it first."

SERIAL=$(adb_out_retry adb get-serialno || echo "unknown")
green "  connected: $SERIAL"

CTX=$(adb_out_retry adb shell 'cat /proc/self/attr/current 2>/dev/null')
[[ "$CTX" == "u:r:su:s0" ]] || die "adb shell context is '$CTX', expected u:r:su:s0 (root). Is this the HA/Wyoming boot image?"
green "  root context confirmed"
echo

CURRENT=$(adb_out_retry adb shell "settings get secure $SETTING_KEY")
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
CURRENT_XML=$(adb_out_retry adb shell "cat $PREFS_FILE" || true)
[[ -n "$CURRENT_XML" ]] || die "could not read $PREFS_FILE after retries"

TMP_XML=$(mktemp)
echo "$CURRENT_XML" | sed -E "s/active_wakewords&quot;:\[&quot;[a-z]+&quot;\]/active_wakewords\&quot;:[\&quot;$CHOICE\&quot;]/" > "$TMP_XML"

if ! grep -q "active_wakewords&quot;:\[&quot;$CHOICE&quot;\]" "$TMP_XML"; then
    rm -f "$TMP_XML"
    die "failed to patch active_wakewords in the cached prefs file (unexpected format?)"
fi

echo "Lifting WAN block for the entitlement check..."
"$WANBLOCK" enable >/dev/null 2>&1 || true   # ensure known state first (idempotent)

DISABLE_TRIES=0
until "$WANBLOCK" disable; do
    DISABLE_TRIES=$((DISABLE_TRIES + 1))
    if [[ "$DISABLE_TRIES" -ge 5 ]]; then
        die "could not lift the WAN block after $DISABLE_TRIES attempts (adb link too unstable right now)"
    fi
    yellow "wan-block disable failed (attempt $DISABLE_TRIES/5), retrying in 4s..."
    sleep 4
done
WAN_BLOCK_SAFETY_NET=1   # from here on, any unexpected exit must re-block

adb_retry adb push "$TMP_XML" /data/local/tmp/wwip_new.xml >/dev/null \
    || die "could not push updated wakeword cache after retries (WAN block will be re-applied)"
adb_retry adb shell "cp /data/local/tmp/wwip_new.xml $PREFS_FILE; restorecon $PREFS_FILE" \
    || die "could not install updated wakeword cache after retries (WAN block will be re-applied)"
rm -f "$TMP_XML"
adb_retry adb shell "settings put secure $SETTING_KEY $CHOICE" >/dev/null \
    || die "could not set secure setting after retries (WAN block will be re-applied)"

echo "Rebooting to apply..."
# A failed clear here (silently ignored before) risks a stale log line from
# a previous successful switch to this same word producing a false-positive
# "authorized" result on the very first poll below, before this attempt's
# reboot has even landed. Retry it properly instead of shrugging it off.
adb_retry adb logcat -c \
    || yellow "could not clear the log buffer after retries -- entitlement check below may be less reliable"
adb_retry adb reboot \
    || die "could not issue reboot after retries (WAN block will be re-applied)"

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

# A word that was already authorized on a previous run doesn't necessarily
# re-emit setCurrentWakeWordModel on a later switch back to it -- there's no
# fresh DAVS activation needed since it's already cached as valid. If we
# timed out above with no explicit denial either, check the actual
# persisted state directly rather than reporting a false "timed out".
if [[ "$RESULT" == "timeout" ]]; then
    PERSISTED=$(adb_out_retry adb shell "settings get secure $SETTING_KEY" || true)
    if [[ "$PERSISTED" == "$CHOICE" ]]; then
        RESULT="already-active"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Always re-apply the WAN block, regardless of what happened above.
# ---------------------------------------------------------------------------
echo
echo "Re-applying WAN block..."
reapply_wan_block
WAN_BLOCK_SAFETY_NET=0   # deliberately re-applied above; the trap no longer needs to

echo
case "$RESULT" in
    authorized)
        green "SUCCESS: '$CHOICE' passed the entitlement check and should now work offline."
        ;;
    already-active)
        green "SUCCESS: '$CHOICE' is set and persisted (was already authorized from a previous switch,"
        green "so no fresh activation log was expected this time)."
        ;;
    denied)
        red "DENIED: Amazon rejected '$CHOICE' for this account/device (not just an offline artifact)."
        yellow "Reverting to the previous wake word ('$CURRENT')."
        REVERT_XML=$(mktemp)
        echo "$CURRENT_XML" > "$REVERT_XML"
        if adb_retry adb push "$REVERT_XML" /data/local/tmp/wwip_revert.xml >/dev/null \
            && adb_retry adb shell "cp /data/local/tmp/wwip_revert.xml $PREFS_FILE; restorecon $PREFS_FILE" \
            && adb_retry adb shell "settings put secure $SETTING_KEY $CURRENT" >/dev/null; then
            rm -f "$REVERT_XML"
            adb_retry adb reboot || yellow "reboot command failed after retries -- reboot manually to apply the revert"
            yellow "Rebooting back to '$CURRENT'."
        else
            rm -f "$REVERT_XML"
            red "Could not revert after retries -- wake word may still be set to '$CHOICE' (denied by Amazon)."
            yellow "WAN block is still safely re-applied regardless. Re-run this script to retry the revert."
        fi
        ;;
    timeout)
        yellow "TIMED OUT waiting for a definitive result after ${DAVS_TIMEOUT_S}s."
        yellow "WAN block is re-applied either way. Check manually later --"
        yellow "if it never got authorized, re-run this script to retry."
        ;;
esac
