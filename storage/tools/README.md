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

Only crafting-table (3x3 shaped/shapeless) recipes are kept. Machine recipes are skipped.
