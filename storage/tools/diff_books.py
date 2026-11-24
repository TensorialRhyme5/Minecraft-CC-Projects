"""Compare two recipes.txt files by meaning (item ids), not by line numbers."""
import sys, collections

def load(p):
    L = open(p, encoding='utf-8').read().split('\n')
    I = [l.split('\t')[1] for l in L if l.startswith('I\t')]
    T = [l.split('\t') for l in L if l.startswith('T\t')]
    G = [l[2:] for l in L if l.startswith('G\t')]
    def tagset(i):
        t = T[i - 1]
        return '#' + t[1]
    def g(i):
        return '|'.join(sorted(tagset(int(x[1:])) if x[0] == 't' else I[int(x) - 1] for x in G[i - 1].split(',')))
    R, S = collections.Counter(), collections.Counter()
    for l in L:
        f = l.split('\t')
        if f[0] == 'R':
            out, n, k, body = I[int(f[1]) - 1], f[2], f[3], f[4:]
            if k in ('l', 'w'):
                ing = ' + '.join(sorted(g(int(x)) for x in body[0].split(',') if x))
            else:   # shaped: keep grid shape
                ing = ' / '.join(body)
                ing = ','.join(('_' if x in ('', '0') else g(int(x))) for x in ing.replace(' / ', ',').split(','))
            R[(out, n, k, ing)] += 1
        elif f[0] == 'S':
            S[(I[int(f[1]) - 1], f[2], f[3], g(int(f[4])))] += 1
    return R, S, set(I)

oR, oS, oI = load(sys.argv[1])
nR, nS, nI = load(sys.argv[2])
gone = oR - nR; new = nR - oR
print('crafting: old', sum(oR.values()), 'new', sum(nR.values()), '| only in old', sum(gone.values()), '| only in new', sum(new.values()))
print('cooking: only in old', sum((oS - nS).values()), '| only in new', sum((nS - oS).values()))
byout = collections.defaultdict(lambda: [[], []])
for r in gone: byout[r[0]][0].append(r)
for r in new: byout[r[0]][1].append(r)
changed = [o for o, (a, b) in byout.items() if a and b]
removed = [o for o, (a, b) in byout.items() if a and not b]
added = [o for o, (a, b) in byout.items() if b and not a]
print('outputs changed', len(changed), 'removed', len(removed), 'added', len(added))
for name, lst in (('CHANGED', changed), ('REMOVED', removed), ('ADDED', added)):
    print('==', name)
    for o in sorted(lst)[:400]:
        print(' ', o, [ (r[1], r[2], r[3][:140]) for r in byout[o][0] ][:2], '->', [ (r[1], r[2], r[3][:140]) for r in byout[o][1] ][:2])
for r in sorted(oS - nS): print('S-', r)
for r in sorted(nS - oS): print('S+', r)
