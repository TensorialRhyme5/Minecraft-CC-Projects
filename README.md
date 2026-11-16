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

**Recipes:** tap `RECIPES` to search every crafting-table recipe in All the Mons (23,600 recipes from the mod jars plus the
pack's KubeJS changes). Pick one to see the 3x3 grid, what you have and what's missing, choose how many crafts, and
`SEND INGREDIENTS` puts them in the pickup. Tag slots (any planks, any iron ingot...) use whatever you have the most of.
`CAN MAKE` filters to things you can craft right now. From an item's detail page, `SHOW RECIPE` jumps straight there.
The recipe book (`storage/recipes.txt`) is downloaded into memory at startup, so it doesn't use the computer's disk.
To rebuild it after a modpack update, see `storage/tools/`.

**Straight to you (Advanced Peripherals Inventory Manager):** wire an Inventory Manager to the storage network
(it can go anywhere on the network), and put an AP Memory Card bound to you inside. Item pages then get `SEND TO: ME / BARREL`,
and the main screen gets `PUT AWAY MY INVENTORY` (main inventory only - hotbar, armor and offhand stay).

**Auto-crafting (crafty turtle):** put a crafty turtle facing the pickup barrel with a full-block wired modem
touching its back (cabled to the network, right-clicked on). On the turtle:

```
wget https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-CC-Projects/main/storage/crafter_startup.lua startup.lua
reboot
```

Then `CRAFT` on a recipe sends the ingredients to the barrel, the turtle lays out the grid and crafts, and the finished
items land in the barrel (up to 64 crafts per turtle run, big orders run several times).

```
wget https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-CC-Projects/main/storage/startup.lua startup.lua
reboot
```

## Pocket Remote (`pocket/`)
An advanced pocket computer with a wireless or ender modem. ITEMS tab: search storage (typos OK), send items to you
or the barrel, put your inventory away. MUSIC tab: now playing, controls, jukebox volume, shuffle a playlist.
The storage computer and the jukebox need a wireless/ender modem too.

```
wget https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-CC-Projects/main/pocket/startup.lua startup.lua
reboot
```
