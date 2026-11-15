"""Extract crafting-table recipes, item tags and English names from
vanilla data + mod jars + kubejs data folder.  Writes base.json."""
import zipfile, json, os, re, sys

MODS = '/mnt/user-data/uploads/mods'
KJS = '/mnt/user-data/uploads/kubejs'
VAN = '/home/claude/recipes_work/vanilla'
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


def norm_result(r):
    if isinstance(r, str):
        return r, 1
    if isinstance(r, dict):
        it = r.get('id') or r.get('item')
        if isinstance(it, dict):
            return norm_result(it)
        return it, int(r.get('count', 1) or 1)
    return None, 0


def parse_recipe(rid, j):
    t = str(j.get('type', ''))
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
        return {'id': rid, 'k': 's', 'out': out, 'n': n, 'g': grid}
    if 'ingredients' in j:
        ings = []
        for i in j['ingredients']:
            o = norm_ing(i)
            if not o:
                return None
            ings.append(o)
        if not ings or len(ings) > 9:
            return None
        return {'id': rid, 'k': 'l', 'out': out, 'n': n, 'i': ings}
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

    json.dump({'recipes': list(recipes.values()), 'tags': tags, 'names': names,
               'mods': sorted(mods_loaded)}, open(OUT, 'w'))
    print('recipes', len(recipes), 'tags', len(tags), 'names', len(names), stats)


main()
