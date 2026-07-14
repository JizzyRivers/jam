# amonet/

This directory is **not part of Jam** — it's where you place your own copy
of the Amonet unlock toolkit (the bootloader-unlock exploit for this device),
plus whatever stock firmware / `f1r30s.zip` you're using. Jam's `amonet`
menu just calls into whatever you put here and walks you through the manual
hardware steps in between; it doesn't include or redistribute Amonet itself.

Place these here (from the Amonet project, however you obtained it):

```
amonet/
├── brick.sh
├── bootrom-step.sh
├── fastboot-step.sh
├── boot-recovery.sh
├── update.bin (or <whatever-your-stock-firmware-is-named>.zip / .bin)
└── f1r30s.zip
```

The stock firmware package can be either a `.zip` or a `.bin` (some
vendors ship OTA packages named `update.bin`). Jam looks for `amonet/update.bin`
first and uses it automatically if present; otherwise it asks for the exact
filename you placed there, whatever it's called. `f1r30s.zip` is always
expected under that exact name.

Once these are in place, Jam's **Amonet** submenu (`./jam.sh`) walks through
the unlock sequence step by step, running each script at the right point and
telling you what LED state / physical action to wait for in between.
