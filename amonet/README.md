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
├── <stock-firmware>.zip
└── f1r30s.zip
```

Once these are in place, Jam's **Amonet** submenu (`./jam.sh`) walks through
the unlock sequence step by step, running each script at the right point and
telling you what LED state / physical action to wait for in between.
