# Rebuilding recipes.txt

1. Copy the pack's `mods/*.jar` into one folder and `kubejs/` into another.
2. Clone NeoForge data: `git clone --depth 1 --filter=blob:none --sparse -b 1.21.1 https://github.com/neoforged/NeoForge.git neoforge` then `git -C neoforge sparse-checkout set src/generated/resources/data`.
   Clone vanilla data: `git clone --depth 1 -b 1.21.1-data https://github.com/misode/mcmeta.git vanilla`
   and download `https://raw.githubusercontent.com/misode/mcmeta/1.21.1-assets-json/assets/minecraft/lang/en_us.json`.
3. Edit the paths at the top of `extract_recipes.py`, then:

```
python3 extract_recipes.py                                       # -> base.json
node kjs_apply.js base.json <kubejs>/server_scripts final.json   # runs the pack's KubeJS recipe/tag scripts
python3 compact_recipes.py final.json ../recipes.txt
```

Crafting-table (3x3 shaped/shapeless) recipes become R lines (including mods' own crafting-table types listed in
`CRAFT_TYPES`, e.g. Mekanism and Sophisticated Storage tier upgrades) and furnace / blast furnace recipes become S lines
(`S out count f|b group`). Other machine recipes are skipped.

What gets left out on purpose (the storage only knows item ids, not their data components):
- recipes that need a particular variant as an ingredient (a specific potion, a typed bee comb, a filled syringe,
  a Nature's Aura bottle of one aura type...). A "plain, untouched item" requirement still counts as normal.
- recipes that make one of several variants sharing an id (Ender IO conduit types, Reliquary mob charm fragments,
  Patchouli books, IE blueprints, Compact Machines sizes...). Colour-only differences are kept, and so are
  self-upgrades like Turtle + Diamond Pickaxe -> Turtle (storage.lua gives those their own entry, "Mining Turtle").
- recipes with a slot nothing in the pack can fill (a tag from a mod that isn't installed).

Fluid ingredients ("1000 mB of creosote") are filled with that fluid's bucket. RFTools' `mcjtylib:copy_components`
recipes are unwrapped to the crafting recipe inside. To check a rebuild against the live book:
`python3 diff_books.py ../recipes.txt new_recipes.txt`.
AE2 water transforms (`ae2:transform` in water, e.g. Redstone Crystal, Fluix Crystal) become R lines of kind `w`, done by
the transformer turtle. To add them to an existing `recipes.txt` without a full rebuild, unzip the AE-family jars
(recipes and item tags) and run `python3 add_transforms.py ../recipes.txt <unzipped jar folders...>` (safe to re-run).
