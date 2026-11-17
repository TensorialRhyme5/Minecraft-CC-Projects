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

ings, gidx = [], {}
def ing(opts):
    toks = []
    for o in opts:
        if o == '*': continue
        if o.startswith('#'): tk = 't%d' % tag(ns(o[1:]))
        else: tk = str(item(o))
        if tk not in toks: toks.append(tk)
    key = ','.join(toks)
    if not key: return None
    if key not in gidx:
        gidx[key] = len(ings) + 1; ings.append(key)
    return gidx[key]

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
        body = 'l\t' + ','.join(map(str, sorted(g)))
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
    if n and '%' in n: n = n.replace('%s', '').strip()     # e.g. Sophisticated Storage's "%s%sIron Chest"
    if n and '%' not in n: return n
    return ' '.join(w.capitalize() for w in i.split(':')[1].replace('/', ' ').split('_'))
ilines = ['I\t%s\t%s' % (i, ascii(pretty(i)).strip() or i) for i in items]
glines = ['G\t' + g for g in ings]
with open(OUT, 'w', newline='\n') as f:
    f.write('V\t1\t%d\t%d\t%d\t%d\n' % (len(items), len(tags), len(ings), len(rlines)))
    for block in (ilines, tlines, glines, rlines, slines):
        f.write('\n'.join(block) + '\n')
print('items', len(items), 'tags', len(tags), 'ings', len(ings), 'recipes', len(rlines), 'cooking', len(slines), 'skipped', skipped)
