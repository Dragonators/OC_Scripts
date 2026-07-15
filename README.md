# OC_Scripts

OpenComputers scripts used on the Dragonators GTNH server.

## BeeMasterXXL fixed edition

The complete patched BeeMasterXXL package and its OpenOS network installer are in [`src/BeeMasterXXL`](src/BeeMasterXXL).

Run on the robot with an Internet Card:

```sh
wget -f https://raw.githubusercontent.com/Dragonators/OC_Scripts/beemasterxxl-fixed-v5/src/BeeMasterXXL/install.lua /tmp/beemaster-install.lua
lua /tmp/beemaster-install.lua /home
```

The installer preserves an existing `config.lua`, adds `worldAccelerator_mode = "fixed"` when upgrading an older BeeMasterXXL configuration, and does not touch `data.txt`.
