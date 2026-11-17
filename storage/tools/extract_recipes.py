"""Extract crafting-table recipes, item tags and English names from
vanilla data + mod jars + kubejs data folder.  Writes base.json."""
import zipfile, json, os, re, sys

MODS = '/mnt/user-data/uploads/mods'
KJS = '/mnt/user-data/uploads/kubejs'
VAN = '/home/claude/recipes_work/vanilla'
NEO = '/home/claude/recipes_work/neoforge/src/generated/resources'
VLANG = '/home/claude/recipes_work/en_us.json'
OUT = '/home/claude/recipes_work/base.json'

# mods present in the pack whose jars were not copied (libraries / client)
EXTRA_MODS = set('''minecraft neoforge appleskin architectury athena attributefix balm bookshelf
caelus cloth_config clumps codechickenlib commoncapabilities controlling cristellib ctm
cupboard curios accessories cyclopscore defaultoptions fusion geckolib guideme jade jei
journeymap kotlinforforge kubejs lithostitched mcjtylib modonomicon owo patchouli placebo
polymorph puzzleslib resourcefulconfig resourcefullib rhino smartbrainlib sodium iris
supermartijn642corelib supermartijn642configlib titanium yungsapi ftblibrary ftbquests
ftbteams ftbchunks ftbessentials ftbultimine ftbranks ftbxmodcompat alltheleaks terralith
modernfix ferritecore apothic_attributes konkrete fancymenu melody drippyloadingscreen
essential spark cobblepedia oracle_index jearchaeology justenoughbreeding jemm
justenoughprofessions moreoverlays invtweaks mousetweaks craftingtweaks fastbench fastsuite
fastfurnace trashslot toastcontrol searchables polylib octolib lionfishapi glodium
yet_another_config_lib_v3 fzzy_config prickle experiencelib edivadlib zerocore
brandonscore integratedscripting'''.split())

RE_RECIPE = re.compile(r'^data/([^/]+)/recipes?/(.+)\.json$')
RE_TAG = re.compile(r'^data/([^/]+)/tags/items?/(.+)\.json$')
RE_LANG = re.compile(r'^assets/([^/]+)/lang/en_us\.json$')

recipes = {}      # id -> recipe
DOUBLES = set()   # items that also have a "double" version (Sophisticated Storage chests)
tags = {}         # tag -> {'values': [...]}
names = {}
mods_loaded = set(EXTRA_MODS)
stats = {'bad': 0, 'cond_skip': 0}


def modids_of(z):
    ids = set()
    for nm in ('META-INF/neoforge.mods.toml', 'META-INF/mods.toml'):
        try:
            txt = z.read(nm).decode('utf-8', 'replace')
        except KeyError:
            continue
        ids.update(re.findall(r'^\s*modId\s*=\s*"([^"]+)"', txt, re.M))
    return ids


# ---- the pack's config files decide some mod-specific recipe conditions
CFG_DIR = '/mnt/user-data/uploads/config'
def _read(name):
    try: return open(os.path.join(CFG_DIR, name), encoding='utf-8', errors='replace').read()
    except OSError: return ''
def _toml_bool(txt, key, default):
    m = re.search(r'^\s*' + re.escape(key) + r'\s*=\s*(true|false)', txt, re.M)
    return default if not m else m.group(1) == 'true'
_rel = _read('reliquary-common.toml')
_ma = _read('mysticalagriculture-common.toml')
CONF = {
    'reliquary:mob_drops_craftable': _toml_bool(_rel, 'dropCraftingRecipesEnabled', False),
    'reliquary:alkahestry_enabled': not _toml_bool(_rel, 'alkahestryTome', False),
    'reliquary:handgun_enabled': not _toml_bool(_rel, 'handgun', False),
    'reliquary:potions_enabled': not _toml_bool(_rel, 'potion', False),
    'reliquary:pedestal_enabled': not _toml_bool(_rel, 'pedestal', False),
    'reliquary:passive_pedestal_enabled': not _toml_bool(_rel, 'passivePedestal', False),
    'reliquary:charm_enabled': not _toml_bool(_rel, 'charms', False),
    'mysticalagriculture:seed_crafting_recipes_enabled': _toml_bool(_ma, 'seedCraftingRecipes', True),
}
_soph = {}
for f in ('sophisticatedcore-common.toml',):
    for item, flag in re.findall(r'"([a-z0-9_:/]+)\|(true|false)"', _read(f)):
        _soph[item] = (flag == 'true')
# Supplementaries: "[blocks.flax] enabled = false" or "sus_recipes = false"
_supp_off = set()
cur = None
for line in _read('supplementaries-common.toml').splitlines():
    m = re.match(r'\s*\[([^\]]+)\]', line)
    if m: cur = m.group(1).split('.')[-1]; continue
    m = re.match(r'\s*([A-Za-z0-9_]+)\s*=\s*false', line)
    if m:
        if m.group(1) == 'enabled' and cur: _supp_off.add(cur)
        else: _supp_off.add(m.group(1))

def cond_ok(c):
    if not isinstance(c, dict):
        return True
    t = c.get('type', '')
    t = t.split(':')[-1]
    if t == 'mod_loaded':
        return c.get('modid') in mods_loaded
    if t == 'not':
        return not cond_ok(c.get('value'))
    if t == 'and':
        return all(cond_ok(v) for v in c.get('values', []))
    if t == 'or':
        return any(cond_ok(v) for v in c.get('values', []))
    if t == 'false':
        return False
    if t == 'item_exists':
        item = c.get('item', '')
        return item.split(':')[0] in mods_loaded
    if t == 'tag_empty':
        return False  # assume tags are populated
    full = c.get('type', '')
    if full in CONF:
        return CONF[full]
    if full == 'sophisticatedcore:item_enabled':
        return _soph.get(c.get('itemRegistryName'), True)
    if full in ('supplementaries:flag', 'amendments:flag'):
        return c.get('flag') not in _supp_off if full == 'supplementaries:flag' else True
    if full == 'expandedae:not_loaded':
        return c.get('modid') not in mods_loaded
    if full == 'dyenamics:lazy':
        return cond_ok(c.get('value'))
    if c.get('invert') is True:
        return False   # an inverted "feature enabled" check: features are on, so this is off
    return True


def conds_ok(j):
    cs = j.get('neoforge:conditions') or j.get('conditions') or []
    if isinstance(cs, dict):
        cs = [cs]
    return all(cond_ok(c) for c in cs)


def norm_ing(x):
    """-> list of options ('ns:item' or '#ns:tag'), or None if unusable"""
    if x is None:
        return None
    if isinstance(x, str):
        return [x] if x else None
    if isinstance(x, list):
        out = []
        for y in x:
            o = norm_ing(y)
            if o:
                out += o
        return out or None
    if isinstance(x, dict):
        if 'item' in x:
            return [x['item']]
        if 'tag' in x:
            return ['#' + x['tag']]
        t = x.get('type', '')
        if 'children' in x:
            return norm_ing(x['children'])
        if 'base' in x:
            return norm_ing(x['base'])
        if 'items' in x:
            return norm_ing(x['items'])
        if 'ingredient' in x:
            return norm_ing(x['ingredient'])
        if 'value' in x:
            return norm_ing(x['value'])
    return None


def result_wood(r):
    if isinstance(r, dict) and isinstance(r.get('components'), dict):
        return r['components'].get('sophisticatedstorage:wood_type')
    return None


def norm_result(r):
    if isinstance(r, str):
        return r, 1
    if isinstance(r, dict):
        it = r.get('id') or r.get('item')
        if isinstance(it, dict):
            return norm_result(it)
        return it, int(r.get('count', 1) or 1)
    return None, 0


# mods that put ordinary crafting-table recipes under their own recipe type (usually to copy data,
# contents or upgrades across); a turtle crafts these like any other shaped/shapeless recipe
CRAFT_TYPES = {
    'mekanism:mek_data', 'mekanismtools:paxel',
    'sophisticatedcore:upgrade_next_tier', 'sophisticatedstorage:storage_tier_upgrade',
    'sophisticatedstorage:double_chest_tier_upgrade',
    'sophisticatedstorage:shulker_box_from_chest', 'sophisticatedstorageinmotion:moving_storage_from_storage',
    'sophisticatedbackpacks:backpack_upgrade', 'functionalstorage:copy_components', 'actuallyadditions:copy_nbt',
    'immersiveengineering:turn_and_copy', 'fluxnetworks:flux_storage_recipe', 'ars_nouveau:book_upgrade',
    'pocketstorage:upgrade', 'utilityvest:upgrade',
}


def parse_recipe(rid, j):
    t = str(j.get('type', ''))
    if t in CRAFT_TYPES and rid.startswith('sophisticatedstorage:double_'):
        return None        # double chests are upgrades of chests that are already double; left out to keep things simple
    double = False
    if t in CRAFT_TYPES:
        t = 'minecraft:crafting_shaped' if ('pattern' in j and 'key' in j) else 'minecraft:crafting_shapeless'
    if t in ('minecraft:smelting', 'minecraft:blasting', 'smelting', 'blasting'):
        ing = norm_ing(j.get('ingredient'))
        out, n = norm_result(j.get('result'))
        if not ing or not out:
            return None
        return {'id': rid, 'k': 'b' if t.endswith('blasting') else 'f', 'out': out, 'n': n, 'c': ing}
    if not re.search(r'shaped|shapeless', t) or 'mechanical' in t or 'cooking_pot' in t:
        return None
    out, n = norm_result(j.get('result') or j.get('output'))
    if not out:
        return None
    if 'pattern' in j and 'key' in j:
        pat = j['pattern']
        if not isinstance(pat, list) or len(pat) > 3 or any(len(r) > 3 for r in pat):
            return None
        key = {k: norm_ing(v) for k, v in j['key'].items()}
        grid = [None] * 9
        for y, row in enumerate(pat):
            for x, ch in enumerate(row):
                if ch == ' ':
                    continue
                ing = key.get(ch)
                if not ing:
                    return None
                grid[y * 3 + x] = ing
        if double:   # Sophisticated "double" chests share the single chest's item id: give them their own entry
            DOUBLES.add(out); out = out + '@double'
            # these recipes upgrade a chest that is ALREADY a double, so the chest in the middle is a double too
            for gi, cell in enumerate(grid):
                if cell and len(cell) == 1 and re.match(r'^sophisticatedstorage:([a-z_]*_)?chest$', cell[0]):
                    DOUBLES.add(cell[0]); grid[gi] = [cell[0] + '@double']
        return {'id': rid, 'k': 's', 'out': out, 'n': n, 'g': grid, 'wood': result_wood(j.get('result'))}
    if 'ingredients' in j:
        ings = []
        for i in j['ingredients']:
            o = norm_ing(i)
            if not o:
                return None
            ings.append(o)
        if not ings or len(ings) > 9:
            return None
        return {'id': rid, 'k': 'l', 'out': out, 'n': n, 'i': ings, 'wood': result_wood(j.get('result'))}
    return None


def add_tag(tag, j):
    vals = []
    for v in j.get('values', []):
        if isinstance(v, dict):
            v = v.get('id')
        if isinstance(v, str):
            vals.append(v)
    cur = tags.get(tag)
    if j.get('replace') or cur is None:
        tags[tag] = vals
    else:
        cur.extend(v for v in vals if v not in cur)


def load_tree(read, names_list):
    recs = []
    for nm in names_list:
        m = RE_TAG.match(nm)
        if m:
            try:
                add_tag(m.group(1) + ':' + m.group(2), json.loads(read(nm).decode('utf-8-sig')))
            except Exception:
                stats['bad'] += 1
            continue
        m = RE_LANG.match(nm)
        if m:
            try:
                d = json.loads(read(nm).decode('utf-8-sig'))
                for k, v in d.items():
                    if (k.startswith('item.') or k.startswith('block.')) and k.count('.') == 2:
                        _, ns, p = k.split('.')
                        names.setdefault(ns + ':' + p, v)
            except Exception:
                pass
            continue
        m = RE_RECIPE.match(nm)
        if m:
            recs.append((m.group(1) + ':' + m.group(2), nm))
    for rid, nm in recs:
        try:
            j = json.loads(read(nm).decode('utf-8-sig'))
        except Exception:
            stats['bad'] += 1
            continue
        if not isinstance(j, dict):
            continue
        if not conds_ok(j):
            stats['cond_skip'] += 1
            recipes.pop(rid, None)
            continue
        r = parse_recipe(rid, j)
        if r:
            recipes[rid] = r
        else:
            recipes.pop(rid, None)  # an override that is no longer a crafting recipe


# ---- Sophisticated Storage chests and barrels come in wood types (same item id, different look).
# Give every wood its own entry ("sophisticatedstorage:iron_chest@spruce") so upgrades keep their wood.
WOODS = ['oak', 'spruce', 'birch', 'jungle', 'acacia', 'dark_oak', 'mangrove', 'cherry', 'bamboo', 'crimson', 'warped']
WOOD_ITEM = re.compile(r'^sophisticatedstorage:((copper|iron|gold|diamond|netherite)_)?(chest|barrel)$'
                       r'|^sophisticatedstorage:limited_((copper|iron|gold|diamond|netherite)_)?barrel_[1-4]$')


def split_by_wood():
    def cells(r):
        return r['g'] if r['k'] == 's' else r['i'] if r['k'] == 'l' else [r['c']]
    def set_cells(r, c):
        if r['k'] == 's': r['g'] = c
        elif r['k'] == 'l': r['i'] = c
        else: r['c'] = c[0]
    def woody(cell):
        return cell and any(WOOD_ITEM.match(o) for o in cell)
    new = {}
    for rid, r in list(recipes.items()):
        out = r['out']
        if WOOD_ITEM.match(out) and r.get('wood'):            # made from planks: its wood is known
            r['out'] = out + '@' + r['wood']
            new[rid] = r
        elif WOOD_ITEM.match(out):                             # an upgrade: one copy per wood, keeping it
            if not any(woody(c) for c in cells(r)):
                continue                                       # no wood item to carry over: leave it out
            for w in WOODS:
                c2 = [([o + '@' + w if WOOD_ITEM.match(o) else o for o in c] if c else c) for c in cells(r)]
                r2 = dict(r); r2['out'] = out + '@' + w; set_cells(r2, c2)
                new[rid + '@' + w] = r2
        else:                                                  # uses one as an ingredient: any wood will do
            if any(woody(c) for c in cells(r)):
                c2 = []
                for c in cells(r):
                    if c and woody(c):
                        c = [o2 for o in c for o2 in ([o + '@' + w for w in WOODS] if WOOD_ITEM.match(o) else [o])]
                    c2.append(c)
                set_cells(r, c2)
            new[rid] = r
    recipes.clear(); recipes.update(new)
    wn = {'dark_oak': 'Dark Oak'}
    for r in new.values():
        o = r['out']
        if '@' in o and not o.endswith('@double'):
            base, w = o.split('@', 1)
            bn = (names.get(base) or base.split(':')[-1].replace('_', ' ').title()).replace('%s', '').strip()
            names[o] = wn.get(w, w.title()) + ' ' + bn


def main():
    jars = []
    for f in sorted(os.listdir(MODS)):
        try:
            z = zipfile.ZipFile(os.path.join(MODS, f))
        except Exception:
            continue
        mods_loaded.update(modids_of(z))
        jars.append(z)
    # vanilla
    vfiles = []
    for root, _, fs in os.walk(os.path.join(VAN, 'data')):
        for f in fs:
            vfiles.append(os.path.relpath(os.path.join(root, f), VAN).replace(os.sep, '/'))
    load_tree(lambda p: open(os.path.join(VAN, p), 'rb').read(), vfiles)
    # NeoForge's own data (the shared c: tags like c:ingots/iron, plus its vanilla recipe tweaks)
    nfiles = []
    for root, _, fs in os.walk(os.path.join(NEO, 'data')):
        for f in fs:
            nfiles.append(os.path.relpath(os.path.join(root, f), NEO).replace(os.sep, '/'))
    load_tree(lambda p: open(os.path.join(NEO, p), 'rb').read(), nfiles)
    for k, v in json.load(open(VLANG)).items():
        if (k.startswith('item.minecraft.') or k.startswith('block.minecraft.')) and k.count('.') == 2:
            names.setdefault('minecraft:' + k.split('.')[2], v)
    # mods (jar order alphabetical, like the loader roughly does)
    for z in jars:
        load_tree(z.read, z.namelist())
    # kubejs data folder (datapack, loaded last)
    kfiles = []
    for root, _, fs in os.walk(os.path.join(KJS, 'data')):
        for f in fs:
            kfiles.append('data/' + os.path.relpath(os.path.join(root, f), os.path.join(KJS, 'data')).replace(os.sep, '/'))
    load_tree(lambda p: open(os.path.join(KJS, p), 'rb').read(), kfiles)

    for x in DOUBLES:
        names[x + '@double'] = 'Double ' + names.get(x, x.split(':')[-1].replace('_', ' ').title())
    split_by_wood()
    json.dump({'recipes': list(recipes.values()), 'tags': tags, 'names': names,
               'mods': sorted(mods_loaded)}, open(OUT, 'w'))
    print('recipes', len(recipes), 'tags', len(tags), 'names', len(names), stats)


main()
