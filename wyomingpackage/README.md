# wyomingpackage/

This directory is **not part of Jam** — it's where you place your own copy of
the Echo Dot HA/Wyoming installer package (the on-device Wyoming Satellite +
Sendspin player project). Jam's `wyomingpackage` menu just calls into
whatever you put here; it doesn't include or redistribute that project
itself, since it isn't Jam's work to redistribute.

Place these here (from that project, however you obtained it):

```
wyomingpackage/
├── flash-ha-wyoming-boot.sh
├── install.sh
├── install-wyoming.sh
└── files/
    ├── echo-dot2-ha-wyoming-boot.img
    ├── wyoming-satellite.jar
    ├── wyoming-satellite.sh
    ├── earcon.pcm
    ├── timer_finished.pcm
    └── silence.mp3
```

Once these are in place, Jam's **Wyoming Package** submenu (`./jam.sh`) can
drive the flash + install steps for you.
