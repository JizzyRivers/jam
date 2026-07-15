# Jam — for your Biscuit

Give your Biscuit (Echo Dot 2, `biscuit`, Fire OS 5) some Jam: on-device WAN
blocking, wake word switching (with automatic temporary WAN reconnection for
Amazon's entitlement check), and WiFi credential management — plus guided
menus for the Amonet unlock and the Wyoming Satellite install, neither of
which is Jam's own work (see below).

Run `./jam.sh` for a menu tying everything together, or run each script
directly.

## What's Jam, and what isn't

Jam itself is: `jam.sh`, `wan-block.sh`, `set-wake-word.sh`,
`wifi-credentials.sh`.

**Not Jam's own work**, and not bundled here — you supply these yourself:

- **`amonet/`** — the Amonet bootloader-unlock exploit. See
  `amonet/README.md` for what to place there. Jam's Amonet submenu walks
  through the unlock sequence and calls these scripts at the right points.
- **`wyomingpackage/`** — the on-device Wyoming Satellite + Sendspin
  installer. See `wyomingpackage/README.md` for what to place there. Jam's
  Wyoming Package submenu drives the flash + install steps.

Jam won't do anything with either submenu until you've populated those
directories — it'll tell you exactly what's missing and point at the
relevant README instead of failing with a raw "no such file."

## Overall Flow

1. **Amonet submenu** — unlock the bootloader (steps 1–8 in `./jam.sh` →
   option 1). This is the most hands-on part: physical button holds, LED
   colors, and in the worst case opening the device to short a pin. Ends
   with the device booting the exploited firmware, adb forcibly enabled.
2. **Wyoming Package submenu** — flash the HA/Wyoming boot image, do the
   one-time Alexa app setup for Wi-Fi + wake word, run the installer, reboot,
   add the Echo to Home Assistant as a Wyoming Satellite (`./jam.sh` →
   option 2).
3. **WAN block** (main menu) — lock it down to LAN-only right from Jam,
   no router config needed.
4. **Wake word switcher / WiFi credentials** (main menu) — change either any
   time afterward, without ever touching the Alexa app again.

**Known failure mode:** the HA/Wyoming boot image occasionally doesn't
properly take when flashed — the device still boots and looks completely
normal (lands in Amazon's Alexa-app setup screen like it's supposed to),
but adb never comes up because the image didn't actually force-enable it.
If you proceed to the Alexa app setup at that point, you end up stuck: a
fully set-up device with no adb, no way to run the installer, nothing to
do except start over. **Recovery does not require redoing the Amonet
unlock** — the bootloader unlock is a persistent, one-time hardware
change. Just re-enter rainbow fastboot manually (unplug, reconnect, wait
~3s after the blue LED, hold the action button ~5s) and reflash. Option 5
in the Wyoming Package submenu now verifies adb actually comes up after
flashing (polls for up to 90s) and will tell you clearly if it didn't,
*before* you waste time on the Alexa app setup.

## WAN Blocking

```bash
./wan-block.sh enable   # block WAN, allow LAN only
./wan-block.sh disable  # restore full WAN access
./wan-block.sh status   # show current state
```

Patches `/system/bin/firewall.sh` (from the Wyoming package's install) to
reject all outbound WiFi traffic except the Echo's own local subnet
(auto-detected from `ip route`), inserted before the stock catch-all
`-A OUTPUT -o wlan0 -j ACCEPT` line. Fully on-device — no router, DHCP
server, or upstream DNS cooperation required, unlike network-level tricks
(Pi-hole blocklists, gateway overrides, etc). Persists across reboots since
it's baked into `firewall.sh` itself, which the boot image re-runs from
scratch (`--flush` + rebuild) on every boot.

Note: the stock Amazon speech stack (`amazon.speech.sim` and friends) keeps
running alongside the Wyoming satellite rather than being replaced by it —
this is by design, not a bug. It's what wakes on the configured word in the
first place; blocking WAN just makes its cloud calls fail silently (the
Wyoming installer's LED/earcon patches hide that failure) so only the
Wyoming satellite's response is perceptible.

## Wake Word Switcher

```bash
./set-wake-word.sh
```

Switching to a wake word this Amazon account hasn't used on this device
before requires a one-time online entitlement check (`checkVendableArtifact`
against Amazon's DAVS service) — the engine won't activate a wake word,
even one already bundled locally under `/system`, until that check succeeds.
This script automates the whole thing safely:

1. Temporarily lifts the WAN block (`wan-block.sh disable`).
2. Writes the new wake word into the actual persisted cache
   (`amazon.speech.wakewordservice.wakewordinfoprovider.xml` — this is the
   real source of truth; the `settings put secure` key is just a cosmetic
   mirror and doesn't do anything by itself).
3. Reboots and polls logs for the real success signal
   (`setCurrentWakeWordModel: <word>_<locale>`), not just "no error seen yet"
   (a `CONNECTION_FAILED` DAVS response looks like "no error" too if you're
   not careful, but isn't success).
4. Re-applies the WAN block afterward unconditionally, with a retry loop —
   this step must never just give up and leave the Echo unblocked.
5. If Amazon explicitly denies the word (`UNAUTHORIZED`, not just a
   connectivity hiccup), automatically reverts to the previous wake word.

## WiFi Credentials

```bash
./wifi-credentials.sh
```

Changes the WiFi network directly, without the Alexa app or OOBE flow.
`wpa_cli`'s control socket hangs on this build for reasons we couldn't root
cause, so this edits `/data/misc/wifi/wpa_supplicant.conf` directly (plaintext,
writable as root) and restarts the radio via `svc wifi disable`/`enable` to
force a fresh read. Since `adb` runs over USB here, changing WiFi never risks
losing the connection to the device itself. A timestamped backup of the
previous config is kept on-device before writing the new one.

## Fix Flaky USB/adb (host-side)

```bash
./fix-adb-udev.sh
```

If `adb` connects for a few seconds, drops, then reconnects on repeat --
but the same cable/port is rock solid in TWRP -- this is usually your
computer's `libmtp` udev rules grabbing the device and knocking it out of
ADB mode. Unlike every other Jam script, this one runs **on your computer**,
not the Echo -- it doesn't touch adb/the device at all.

It walks you through `lsusb` to find the Echo's vendor:product ID (this
varies per device/host, so you pick the right line), then adds an explicit
udev rule excluding that ID from `libmtp` and reloads udev rules. Requires
sudo. Unplug and replug the Echo after running it.

## Quick Check

Run `./jam.sh` and pick **Quick health check**, or manually:

```bash
adb shell 'getprop init.svc.wyoming-sat'
adb shell 'busybox netstat -ltnp | busybox grep 10700'
adb shell 'busybox netstat -ltnp | busybox grep 8928'
adb shell 'busybox grep "dport 10700" /system/bin/firewall.sh'
adb shell 'busybox grep "dport 8928" /system/bin/firewall.sh'
adb shell 'p=$(busybox ps | busybox awk "/wapp/ {print \$1; exit}"); cat /proc/$p/attr/current'
```

Expected context:

```text
running

tcp        0      0 :::10700                :::*                    LISTEN      2009/wapp
tcp        0      0 :::8928                 :::*                    LISTEN      2009/wapp

$IPTABLES -A INPUT -i wlan0 -p tcp -m tcp --dport 10700 -j ACCEPT
$IPTABLES -A INPUT -i wlan0 -p tcp -m tcp --dport 8928 -j ACCEPT

u:r:shell:s0c
```

## Credits

Jam is just a menu wrapped around other people's work. None of the
following would be possible without them:

**Wyoming Package** (on-device Wyoming Satellite + Sendspin player):
[Download post](https://xdaforums.com/t/unlock-root-twrp-unbrick-amazon-echo-dot-2nd-gen-2016-biscuit.4761416/page-9#post-90631621)

- **kirkkirki** — for the Wyoming package itself.

**Amonet-Biscuit** (the bootloader unlock exploit for this device):
[XDA thread](https://xdaforums.com/t/unlock-root-twrp-unbrick-amazon-echo-dot-2nd-gen-2016-biscuit.4761416/)

- **@k4y0z**
- **@Rortiz2**

**Additional thanks:**

- **@xyz**
- **AntiEngineer**
