"""final.json -> recipes.txt (compact line format read by storage.lua)"""
import json, re, sys, unicodedata
def ascii(s):
    s = unicodedata.normalize('NFKD', s)
    return ''.join(c for c in s if 32 <= ord(c) < 127)
d = json.load(open(sys.argv[1]))
OUT = sys.argv[2]
names = d['names']
ns = lambda x: x if ':' in x else 'minecraft:' + x
rawtags = {}
for k, vs in d['tags'].items():
    lst = rawtags.setdefault(ns(k), [])
    for v in vs:
        v = ('#' + ns(v[1:])) if v.startswith('#') else ns(v)
        if v not in lst: lst.append(v)
strip = lambda s: re.sub(r'\[.*$', '', s.strip())

items, iidx = [], {}
def item(i):
    i = strip(i)
    if ':' not in i: i = 'minecraft:' + i
    if i not in iidx:
        iidx[i] = len(items) + 1; items.append(i)
    return iidx[i]

memo = {}
def resolve(tag, seen=()):
    if tag in memo: return memo[tag]
    if tag in seen: return []
    out = []
    for v in rawtags.get(tag, []):
        if v.startswith('#'):
            for x in resolve(v[1:], seen + (tag,)):
                if x not in out: out.append(x)
        elif v not in out: out.append(v)
    memo[tag] = out
    return out

tags, tidx = [], {}
def tag(t):
    if t not in tidx:
        tidx[t] = len(tags) + 1; tags.append(t)
    return tidx[t]

# a fluid ingredient ("~fluid:c:creosote") is filled by that fluid's bucket, if the pack has one
BUCKETS = {}
for k in names:
    if k.endswith('_bucket'): BUCKETS.setdefault(k.split(':', 1)[1][:-len('_bucket')], []).append(k)
def bucket(f):
    x = f.split(':')[-1].split('/')[-1]
    b = 'minecraft:%s_bucket' % x
    return b if b in names else (sorted(BUCKETS.get(x, [])) or [None])[0]
ings, gidx = [], {}
def ing(opts):
    toks = []
    for o in opts:
        if o == '*': continue
        if o.startswith('~fluid:'):
            o = bucket(o[len('~fluid:'):])
            if not o: continue
        if o.startswith('#'):
            if not resolve(ns(o[1:])): continue     # a tag nothing in the pack is in (e.g. from a mod that isn't installed)
            tk = 't%d' % tag(ns(o[1:]))
        else: tk = str(item(o))
        if tk not in toks: toks.append(tk)
    key = ','.join(toks)
    if not key: return None
    if key not in gidx:
        gidx[key] = len(ings) + 1; ings.append(key)
    return gidx[key]

# ---- item variants written by KubeJS as "id[component=...]". The storage only knows item ids, so a recipe
# that needs a particular variant as an input is left out, and so is one that makes a variant of an item
# that also has other recipes (it would look like it makes the plain item). Colour/name-only data is fine.
COSMETIC = {'custom_name', 'item_name', 'hide_additional_tooltip', 'dyed_color', 'custom_model_data', 'block_state',
            'in_water'}   # Aquaculture's "in water right now" flag: false for any tool sitting in storage
def data_keys(s):
    m = re.search(r'\[(.*)\]\s*$', s.strip())
    if not m: return set()
    return {k.split(':')[-1] for k in re.findall(r'(?:^|,)\s*([a-z0-9_.:-]+)\s*=', m.group(1))} or {'?'}
def opts_of(r):
    if r['k'] in ('f', 'b'): return [r['c']]
    return [c for c in (r.get('g') if r['k'] == 's' else r.get('i')) or [] if c]
variants = 0
keep = []
by_out = {}
for r in d['recipes']:
    if any('[' in o and data_keys(o) - COSMETIC for c in opts_of(r) for o in c):
        variants += 1; continue
    r['_v'] = bool(data_keys(r['out']) - COSMETIC)
    by_out.setdefault(strip(r['out']), []).append(r)
    keep.append(r)
for rs in by_out.values():
    if len(rs) > 1 and any(x['_v'] for x in rs):
        for x in rs:
            if x['_v'] and not any(c == [x['out']] or [strip(o) for o in c] == [strip(x['out'])] for c in opts_of(x)):
                x['_drop'] = True; variants += 1     # (self-upgrades like Turtle + Pickaxe -> Turtle stay)
d['recipes'] = [r for r in keep if not r.get('_drop')]

rlines = []
slines = []
seen = set()
skipped = 0
for r in d['recipes']:
    out = item(r['out'])
    if r['k'] in ('f', 'b'):
        k = ing(r['c'])
        if k is None: skipped += 1; continue
        key = (out, r['n'], r['k'], k)
        if key in seen: continue
        seen.add(key)
        slines.append('S\t%d\t%d\t%s\t%d' % (out, r['n'], r['k'], k))
        continue
    if r['k'] == 's':
        g = []
        bad = False
        for c in r['g']:
            if c is None: g.append(0); continue
            k = ing(c)
            if k is None: bad = True; break
            g.append(k)
        if bad: skipped += 1; continue
        while g and g[-1] == 0: g.pop()
        body = 's\t' + ','.join(map(str, g))
    else:
        g = [ing(c) for c in r['i']]
        if None in g: skipped += 1; continue
        body = ('w' if r['k'] == 'w' else 'l') + '\t' + ','.join(map(str, sorted(g)))   # w = AE2 water transform
    key = (out, r['n'], body)
    if key in seen: continue
    seen.add(key)
    rlines.append('R\t%d\t%d\t%s' % (out, r['n'], body))

# tag members (make sure they are items too)
tlines = []
i = 0
while i < len(tags):
    t = tags[i]; i += 1
    mem = [item(x) for x in resolve(t)]
    tlines.append('T\t%s\t%s' % (t, ','.join(map(str, mem))))

def pretty(i):
    if i.endswith('@double'):
        return 'Double ' + pretty(i[:-len('@double')])
    n = names.get(i)
    if n is None and '@' in i:
        return pretty(i.split('@')[0])
    if n and '%' in n: n = n.replace('%s', '').strip()     # e.g. Sophisticated Storage's "%s%sIron Chest"
    if n and '%' not in n: return n
    return ' '.join(w.capitalize() for w in i.split(':')[1].replace('/', ' ').split('_'))
ilines = ['I\t%s\t%s' % (i, ascii(pretty(i)).strip() or i) for i in items]
glines = ['G\t' + g for g in ings]
with open(OUT, 'w', newline='\n') as f:
    f.write('V\t1\t%d\t%d\t%d\t%d\n' % (len(items), len(tags), len(ings), len(rlines)))
    for block in (ilines, tlines, glines, rlines, slines):
        f.write('\n'.join(block) + '\n')
print('items', len(items), 'tags', len(tags), 'ings', len(ings), 'recipes', len(rlines), 'cooking', len(slines), 'skipped', skipped, 'variant', variants)
