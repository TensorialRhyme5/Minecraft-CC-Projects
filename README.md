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
(it can go anywhere on the network), and put an AP Memory Card bound to you inside. Each player gets their own Inventory Manager + card.
Item pages then get `TO: <player> / BARREL`, and the main screen gets `PUT AWAY` buttons per player (main inventory only - hotbar, armor and offhand stay).

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

**Pairing (security):** the storage only answers paired remotes. On the storage screen tap `REMOTES`, pick whose
remote it is, and type the 8-character code on the pocket. Requests are signed with a key made from that code (the
code itself is never sent), so other people's ender modems can't use your storage. Remove a remote on the same page.

```
wget https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-CC-Projects/main/pocket/startup.lua startup.lua
reboot
```

## Pocket extras

- **MUSIC tab:** pair with the jukebox once (CONTROL > PAIRING on the jukebox), then use **SEARCH** to queue any song.
- **CONTROL tab:** WORLD / BASE / **ALERTS** pages. Alerts flash along the bottom of the screen for players joining or leaving,
  low stock, storage at 90% and server lag. Each can be turned on or off on the ALERTS page.
  (No sound: the ender modem takes the pocket's only upgrade slot.)
- The storage keeps a week of history (`storage_history.txt`) and counts the items put away each day (Mountain Time).

## Smelter (furnaces + blast furnaces)

Connect any number of **Furnaces** and **Blast Furnaces** to the storage's wired network (a wired modem on each,
right-click it so it turns red). They're never used as storage.

- When something that can be smelted lands in the input chest, it **waits there** and the storage screen asks:
  **SMELT**, **STORE**, **ALWAYS** (smelt this item from now on) or **NEVER**. Remembered choices are listed at the bottom
  of the SMELTER panel (tap X to forget one).
- Blast furnaces are used for things that can go in one (ores, raw metals); regular furnaces take everything else.
- Fuel comes from storage automatically: charcoal, coal, coal blocks, blaze rods, dried kelp blocks.
- **Crafting uses it too:** if a recipe needs something that has to be smelted first (stone for stone bricks, glass for
  panes...), the ingredient shows green and CRAFT smelts it as one of the steps.
