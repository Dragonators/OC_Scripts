# OC_Scripts

OpenComputers scripts used on the Dragonators GTNH server.

## BeeMasterXXL fixed edition

The complete patched BeeMasterXXL package and its OpenOS network installer are in [`src/BeeMasterXXL`](src/BeeMasterXXL).

Run on the robot with an Internet Card:

```sh
wget -f https://raw.githubusercontent.com/Dragonators/OC_Scripts/beemasterxxl-fixed-v8/src/BeeMasterXXL/install.lua /tmp/beemaster-install.lua
lua /tmp/beemaster-install.lua /home
```

The installer preserves an existing `config.lua`, adds `worldAccelerator_mode = "fixed"` when upgrading an older BeeMasterXXL configuration, and does not touch `data.txt`.

## Forge of Gods ME interface + transposer automation

Installs the complete MagMatter and Quark-Gluon Plasma automation package into
OpenOS `/home`. Existing `exotic_quark.cfg` and `exotic_magmatter.cfg` files are
preserved. Version 8 restores the Wiki-style advanced storage input hatch,
ME dual fluid interface and transposer topology. All hint items and fluids are
returned to the main AE network; no IO Hub or matter condenser is required.

```sh
wget -f https://raw.githubusercontent.com/Dragonators/OC_Scripts/exotic-iohub-v8/src/ExoticIOHub/install.lua /tmp/exotic-install.lua
lua /tmp/exotic-install.lua /home
```

After filling in the component address prefixes, start either mode with:

```sh
quark
magmatter
```
