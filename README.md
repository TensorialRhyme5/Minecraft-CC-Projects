# Minecraft CC Projects

ComputerCraft (CC: Tweaked) builds. Each folder is one project with its own installer.

## Space Voyage
3D visualizer: fly through space past planets, UFOs, rockets, comets, asteroids and nebulae toward a wireframe shape that warps through 14 forms, each in its own colour. Made for an 8x6 advanced monitor (works on any size).

Install on an advanced computer touching (or wired to) the monitor:
```
wget https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-CC-Projects/main/space-voyage/startup.lua startup.lua
reboot
```
Tap the screen for a hyperspace boost + next shape. On the computer: Space = boost, Up/Down = speed, Q = quit.

## Ocean Voyage
Underwater visualizer: light rays, kelp, coral, fish schools, glowing jellyfish, a sea turtle, far-off whales and sharks, rising bubbles and marine snow. Made for an 8x6 advanced monitor (works on any size).

```
wget https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-CC-Projects/main/ocean-voyage/startup.lua startup.lua
reboot
```
Tap the screen for a burst of bubbles. Q on the computer = quit.

## Storage Manager
Tracks every storage chest on the wired network (made for 16 Sophisticated Storage iron double chests on a 6x3 monitor).
Search with the on-screen keyboard or by typing on the computer, see where items are, send 1/16/64/all to the pickup barrel,
set low-stock alerts, and dump items into the input chest to have them filed away automatically.

Input chest `minecraft:chest_0`, pickup barrel `minecraft:barrel_0` (change at the top of `storage/storage.lua`).
You can swap the pickup barrel for a placed Sophisticated Backpack: retrieved items go into the backpack, then put any barrel back.

```
wget https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-CC-Projects/main/storage/startup.lua startup.lua
reboot
```
