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
AE2 water transforms (`ae2:transform` in water, e.g. Redstone Crystal, Fluix Crystal) become R lines of kind `w`, done by
the transformer turtle. To add them to an existing `recipes.txt` without a full rebuild, unzip the AE-family jars
(recipes and item tags) and run `python3 add_transforms.py ../recipes.txt <unzipped jar folders...>` (safe to re-run).
