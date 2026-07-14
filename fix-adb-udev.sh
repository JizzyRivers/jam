#!/usr/bin/env bash
# Fix flaky USB/adb connectivity caused by the host's libmtp udev rules
# grabbing the Echo Dot and knocking it in and out of ADB mode every few
# seconds. This is a HOST-side fix (your computer, not the Echo itself) --
# unlike every other Jam script, this one runs no adb commands.
#
# Symptom: adb connects for a few seconds, drops, reconnects, repeat --
# but the same USB cable/port works fine in TWRP (which doesn't hit the
# libmtp claim at all).
#
# Fix: add an explicit udev rule telling libmtp to skip this device's
# vendor/product ID, so it never claims the interface adb needs.

set -uo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

RULES_FILE=/etc/udev/rules.d/69-libmtp.rules
SOURCE_RULES=""
for candidate in /lib/udev/rules.d/69-libmtp.rules /usr/lib/udev/rules.d/69-libmtp.rules; do
    [[ -f "$candidate" ]] && { SOURCE_RULES="$candidate"; break; }
done

command -v udevadm >/dev/null || die "udevadm not found -- is this actually Linux with systemd-udev?"

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null || die "not root and sudo not available -- re-run this as root"
    SUDO="sudo"
fi

if ! command -v lsusb >/dev/null; then
    yellow "lsusb not found -- it's part of the usbutils package, not installed by default"
    yellow "on every distro."
    if command -v apt-get >/dev/null; then
        read -r -p "Install usbutils now via apt? [Y/n] " ans
        if [[ -z "$ans" || "$ans" =~ ^[Yy] ]]; then
            $SUDO apt-get update -qq && $SUDO apt-get install -y -qq usbutils \
                || die "usbutils install failed -- install it manually and re-run"
            green "usbutils installed."
        else
            die "lsusb is required for this tool -- install usbutils and re-run"
        fi
    else
        die "lsusb not found and this isn't an apt-based system -- install the usbutils (or equivalent) package for your distro and re-run"
    fi
fi

[[ -t 1 ]] && clear
bold "╔══════════════════════════════════════════╗"
bold "║      Fix flaky USB/adb (host-side)        ║"
bold "╚══════════════════════════════════════════╝"
echo
bold "Symptom this fixes: adb connects for a few seconds, drops, reconnects,"
bold "repeat -- while TWRP over the same cable/port is rock solid."
echo
yellow "This edits udev rules on THIS computer, not the Echo. You'll need"
yellow "sudo access."
echo

bold "Current USB devices:"
lsusb | nl -w2 -s') '
echo

read -r -p "Line number for the Echo Dot: " LINE_NUM
[[ "$LINE_NUM" =~ ^[0-9]+$ ]] || die "not a number"

SELECTED=$(lsusb | sed -n "${LINE_NUM}p")
[[ -n "$SELECTED" ]] || die "no such line"
echo
green "Selected: $SELECTED"

# lsusb format: "Bus 001 Device 005: ID 1949:9981 Lab126, Inc."
IDPAIR=$(grep -oE 'ID [0-9a-fA-F]{4}:[0-9a-fA-F]{4}' <<<"$SELECTED" | awk '{print $2}')
[[ -n "$IDPAIR" ]] || die "couldn't parse a vendor:product ID out of that line"
VENDOR="${IDPAIR%%:*}"
PRODUCT="${IDPAIR##*:}"
echo "Vendor: $VENDOR   Product: $PRODUCT"
echo

read -r -p "Add a udev rule to exclude this device from libmtp? [Y/n] " ans
[[ -z "$ans" || "$ans" =~ ^[Yy] ]] || { yellow "cancelled."; exit 0; }

if [[ ! -f "$RULES_FILE" ]]; then
    if [[ -n "$SOURCE_RULES" ]]; then
        echo "Seeding $RULES_FILE from $SOURCE_RULES..."
        $SUDO cp "$SOURCE_RULES" "$RULES_FILE" || die "could not copy seed rules file"
    else
        yellow "No system libmtp rules file found to seed from -- creating a minimal one."
        printf 'LABEL="libmtp_rules_end"\n' | $SUDO tee "$RULES_FILE" >/dev/null
    fi
fi

if $SUDO grep -qE "idVendor}==\"$VENDOR\", ATTR\{idProduct}==\"$PRODUCT\"" "$RULES_FILE" 2>/dev/null; then
    yellow "A rule for $VENDOR:$PRODUCT already exists in $RULES_FILE -- nothing to add."
else
    TMP=$(mktemp)
    $SUDO awk -v vendor="$VENDOR" -v product="$PRODUCT" '
        /LABEL="libmtp_rules_end"/ && !done {
            print "ATTR{idVendor}==\"" vendor "\", ATTR{idProduct}==\"" product "\", GOTO=\"libmtp_rules_end\""
            done = 1
        }
        { print }
    ' "$RULES_FILE" > "$TMP" || die "failed to patch $RULES_FILE"

    if ! grep -q "idVendor}==\"$VENDOR\"" "$TMP"; then
        rm -f "$TMP"
        die "could not find LABEL=\"libmtp_rules_end\" in $RULES_FILE to insert before -- check its format manually"
    fi

    $SUDO cp "$TMP" "$RULES_FILE" || { rm -f "$TMP"; die "could not write updated rules file"; }
    rm -f "$TMP"
    green "Added rule for $VENDOR:$PRODUCT to $RULES_FILE"
fi

echo "Reloading udev rules..."
$SUDO udevadm control --reload-rules || die "udevadm reload failed"
$SUDO udevadm trigger || true

echo
green "Done. Unplug and replug the Echo Dot now for the new rule to take effect."
yellow "If it's still flaky after replugging, double check the vendor:product ID"
yellow "above actually matches the interface adb uses (some devices expose"
yellow "multiple USB interfaces/IDs, e.g. one for MTP and a separate one for adb)."
