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

Installs the from-scratch MagMatter and Quark-Gluon Plasma automation into
OpenOS `/home`. Version 10 replaces the v8 runtime instead of loading any of its
shared modules. Existing v9/v10 `fog_quark.cfg` and `fog_magmatter.cfg` files are
preserved; v9 default timing values are upgraded automatically, while incompatible
v8 configuration is deliberately not migrated. All hint items and fluids are
returned to the main AE network through the dual ME interface. Fluid requests are
configured in parallel across its six tanks (MagMatter in one batch, Quark in 6+1).
Forge-of-Gods Iron/Copper phantom inputs are omitted before interface configuration,
and a cycle completes only after the next full prompt confirms machine consumption.

```sh
wget -f https://raw.githubusercontent.com/Dragonators/OC_Scripts/exotic-iohub-v10/src/ExoticIOHub/install.lua /tmp/fog-exotic-install.lua
lua /tmp/fog-exotic-install.lua /home
```

After filling in the component address prefixes, start either mode with:

```sh
quark
magmatter
```
