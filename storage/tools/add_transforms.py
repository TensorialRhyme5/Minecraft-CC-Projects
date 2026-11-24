"""Add AE2 water-transform recipes to an existing recipes.txt without a full rebuild.

    python3 add_transforms.py ../recipes.txt <unzipped jar or datapack folder> [...]

Each folder is searched for data/*/recipe/**/*.json of type ae2:transform. Only water transforms are
added (that's what the transformer turtle can do); lava / explosion ones are skipped. Running it again
replaces the transform lines it added before. A full rebuild (extract_recipes.py) picks them up by itself.
"""
import json, os, re, sys

path, roots = sys.argv[1], sys.argv[2:]
lines = open(path, encoding='utf-8').read().split('\n')
while lines and lines[-1] == '':
    lines.pop()
lines = [l for l in lines if not re.match(r'^R\t\d+\t\d+\tw\t', l)]     # old transform lines

items, tags, groups = {}, {}, {}
ni = nt = ng = 0
last = {}
for i, l in enumerate(lines):
    k = l[:1]
    if k == 'I':
        ni += 1; items[l.split('\t')[1]] = ni
    elif k == 'T':
        nt += 1; tags[l.split('\t')[1]] = nt
    elif k == 'G':
        ng += 1; groups[l[2:]] = ng
    if k in 'ITG':
        last[k] = i

# tag files from the given folders, for tags the recipe book doesn't have yet
tagfiles = {}
recipes = []
for root in roots:
    for dp, _, fs in os.walk(root):
        rel = os.path.relpath(dp, root).replace(os.sep, '/')
        for f in fs:
            if not f.endswith('.json'):
                continue
            m = re.match(r'^data/([^/]+)/tags/items?(?:/(.*))?$', rel)
            try:
                j = json.load(open(os.path.join(dp, f), encoding='utf-8'))
            except Exception:
                continue
            if m:
                t = m.group(1) + ':' + ((m.group(2) + '/') if m.group(2) else '') + f[:-5]
                tagfiles.setdefault(t, []).extend(v if isinstance(v, str) else v.get('id', '') for v in j.get('values', []))
            elif re.match(r'^data/[^/]+/recipes?(/|$)', rel) and isinstance(j, dict) and j.get('type') == 'ae2:transform':
                recipes.append(j)

new_i, new_t, new_g, new_r = [], [], [], []
def item(x):
    global ni
    if x not in items:
        ni += 1; items[x] = ni; new_i.append('I\t%s\t%s' % (x, ' '.join(w.capitalize() for w in x.split(':')[1].split('_'))))
    return items[x]
def members(t, seen=()):
    out = []
    for v in tagfiles.get(t, []):
        if v.startswith('#'):
            if v[1:] not in seen: out += members(v[1:], seen + (t,))
        elif v and v not in out:
            out.append(v)
    return out
def tag(t):
    global nt
    if t not in tags:
        mem = members(t)
        if not mem:
            return None
        nt += 1; tags[t] = nt; new_t.append('T\t%s\t%s' % (t, ','.join(str(item(m)) for m in mem)))
    return tags[t]
def group(x):
    global ng
    xs = x if isinstance(x, list) else [x]
    toks = []
    for o in xs:
        if 'item' in o: toks.append(str(item(o['item'])))
        elif 'tag' in o:
            ti = tag(o['tag'])
            if ti: toks.append('t%d' % ti)
    if not toks:
        return None
    key = ','.join(toks)
    if key not in groups:
        ng += 1; groups[key] = ng; new_g.append('G\t' + key)
    return groups[key]

seen = set()
for j in recipes:
    c = j.get('circumstance') or {'type': 'fluid', 'tag': 'minecraft:water'}
    if c.get('type') != 'fluid' or c.get('tag') not in ('minecraft:water', 'c:water'):
        continue
    res = j.get('result') or {}
    out, n = res.get('id') or res.get('item'), int(res.get('count', 1))
    gs = [group(x) for x in j.get('ingredients', [])]
    if not out or not gs or None in gs:
        print('skipped', out); continue
    line = 'R\t%d\t%d\tw\t%s' % (item(out), n, ','.join(map(str, sorted(gs))))
    if line not in seen:
        seen.add(line); new_r.append(line); print('added', out, 'x%d' % n)

# keep the blocks in order (items, tags, groups, recipes, cooking); the indexes are only appended to
out = []
for i, l in enumerate(lines):
    out.append(l)
    if i == last.get('I'): out += new_i
    if i == last.get('T'): out += new_t
    if i == last.get('G'): out += new_g
first_s = next((i for i, l in enumerate(out) if l.startswith('S\t')), len(out))
out[first_s:first_s] = new_r
if out[0].startswith('V\t'):
    v = out[0].split('\t')
    v[2:6] = [str(ni), str(nt), str(ng), str(sum(1 for l in out if l.startswith('R\t')))]
    out[0] = '\t'.join(v)
open(path, 'w', encoding='utf-8', newline='\n').write('\n'.join(out) + '\n')
print('new items', len(new_i), 'new tags', len(new_t), 'new groups', len(new_g), 'transform recipes', len(new_r))
