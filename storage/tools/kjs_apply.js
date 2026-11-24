// Run the modpack's KubeJS server scripts against base.json with a mock
// KubeJS API, applying recipe removals/additions and tag edits.
// usage: node kjs_apply.js base.json server_scripts_dir out.json
const fs = require('fs'), path = require('path'), vm = require('vm');
const [, , BASE, DIR, OUT] = process.argv;
const db = JSON.parse(fs.readFileSync(BASE, 'utf8'));
let recipes = db.recipes;            // array
const tags = db.tags;                // tag -> [values]
const log = { removed: 0, added: 0, replaced: 0, tagops: 0, errors: [] };

// ---------- a do-nothing object for every API we don't model ----------
function any() {
  const f = function () { return p; };
  const p = new Proxy(f, {
    get: (t, k) => (k === Symbol.toPrimitive ? () => '' : k === 'then' ? undefined : p),
    apply: () => p, construct: () => p, has: () => true, set: () => true,
  });
  return p;
}
const ANY = any();

// ---------- ingredients ----------
function parseStack(x) { // -> {opts:[...], count}
  if (x == null) return null;
  if (typeof x === 'string') {
    let m = x.match(/^(\d+)x\s+(.+)$/);
    if (m) return { opts: [m[2].trim()], count: +m[1] };
    return { opts: [x.trim()], count: 1 };
  }
  if (Array.isArray(x)) {
    let o = [];
    for (const y of x) { const s = parseStack(y); if (s) o = o.concat(s.opts); }
    return o.length ? { opts: o, count: 1 } : null;
  }
  if (x.__stack) return { opts: x.opts.slice(), count: x.count };
  if (typeof x === 'object') {
    if (x.item) return { opts: [x.item], count: x.count || 1 };
    if (x.id) return { opts: [x.id], count: x.count || 1 };
    if (x.tag) return { opts: ['#' + x.tag], count: x.count || 1 };
  }
  return null;
}
function mkStack(opts, count) {
  const s = { __stack: true, opts, count: count || 1 };
  s.withCount = s.withChance = s.withNBT = s.strongNBT = s.weakNBT = (n) => (typeof n === 'number' ? mkStack(opts, n) : s);
  s.toJson = () => ({ item: opts[0], count: s.count });
  s.getId = () => opts[0]; s.id = opts[0];
  s.or = (y) => { const b = parseStack(y); return mkStack(opts.concat(b ? b.opts : []), s.count); };
  s.isEmpty = () => opts.length === 0;
  return new Proxy(s, { get: (t, k) => (k in t ? t[k] : ANY) });
}
const Item = new Proxy({
  of: (id, c) => { const s = parseStack(id); return mkStack(s ? s.opts : [], typeof c === 'number' ? c : s ? s.count : 1); },
  exists: () => true, empty: mkStack([], 0),
}, { get: (t, k) => (k in t ? t[k] : ANY) });
const Ingredient = new Proxy({
  of: (x, c) => { const s = parseStack(x); return mkStack(s ? s.opts : [], c || 1); },
  all: mkStack(['*'], 1),
}, { get: (t, k) => (k in t ? t[k] : ANY) });

// ---------- recipe filters ----------
function strMatch(pat, val) {
  if (val == null) return false;
  if (pat instanceof RegExp || (pat && pat.constructor && pat.constructor.name === 'RegExp')) return new RegExp(pat.source, pat.flags).test(val);
  return String(pat) === val;
}
function ingHas(r, pat) {
  const all = r.k === 's' ? r.g.filter(Boolean) : (r.k === 'f' || r.k === 'b') ? [r.c] : r.i;
  const want = parseStack(pat);
  return all.some(opts => opts.some(o => (pat instanceof RegExp ? strMatch(pat, o) : want && want.opts.includes(o))));
}
function matches(r, f) {
  if (f == null) return false;
  if (typeof f === 'string' || f instanceof RegExp || (f && f.constructor && f.constructor.name === 'RegExp')) return strMatch(f, r.id);
  if (Array.isArray(f)) return f.some(x => matches(r, x));
  if (f.__stack) return r.out === f.opts[0];
  if (f.not && matches(r, f.not)) return false;
  if (f.or) return f.or.some(x => matches(r, x));
  const keys = Object.keys(f).filter(k => k !== 'not');
  if (!keys.length) return false;
  for (const k of keys) {
    const v = f[k];
    const test = (pv) => {
      switch (k) {
        case 'id': return strMatch(pv, r.id);
        case 'mod': return r.id.split(':')[0] === pv;
        case 'output': { if (pv && pv.__stack) pv = pv.opts[0]; return pv instanceof RegExp ? strMatch(pv, r.out) : String(pv) === r.out; }
        case 'input': return ingHas(r, pv);
        case 'type': {
          const t = String(pv);
          const full = { s: 'minecraft:crafting_shaped', l: 'minecraft:crafting_shapeless', f: 'minecraft:smelting', b: 'minecraft:blasting', w: 'ae2:transform' }[r.k];
          if (pv instanceof RegExp) return pv.test(full);
          if (r.k === 'f') return /smelting$/.test(t);
          if (r.k === 'b') return /blasting$/.test(t);
          if (r.k === 'w') return /transform$/.test(t);
          return r.k === 's' ? /crafting_shaped$|shaped/.test(t) : /shapeless/.test(t);
        }
        default: return false;
      }
    };
    if (!(Array.isArray(v) ? v.some(test) : test(v))) return false;
  }
  return true;
}

// ---------- recipe event ----------
let autoId = 0;
function addRecipe(r) {
  recipes = recipes.filter(x => x.id !== r.id);
  recipes.push(r); log.added++;
  const h = {};
  const chain = new Proxy(h, { get: (t, k) => (k === 'id' ? (id) => { const nid = String(id); recipes = recipes.filter(x => x === r || x.id !== nid); r.id = nid; return chain; } : () => chain) });
  return chain;
}
function outOf(o) { const s = parseStack(o); return s ? { out: s.opts[0], n: s.count } : null; }
function recipeEvent() {
  const e = {
    remove(f) { const before = recipes.length; recipes = recipes.filter(r => !matches(r, f)); log.removed += before - recipes.length; },
    shaped(out, pattern, key) {
      const o = outOf(out); if (!o || !Array.isArray(pattern)) return ANY;
      if (pattern.length > 3 || pattern.some(p => p.length > 3)) return ANY;
      const g = Array(9).fill(null);
      for (let y = 0; y < pattern.length; y++) for (let x = 0; x < pattern[y].length; x++) {
        const ch = pattern[y][x]; if (ch === ' ') continue;
        const s = parseStack(key[ch]); if (!s) return ANY;
        g[y * 3 + x] = s.opts;
      }
      return addRecipe({ id: 'kubejs:auto_' + (autoId++), k: 's', out: o.out, n: o.n, g });
    },
    shapeless(out, ings) {
      const o = outOf(out); if (!o) return ANY;
      const list = [];
      for (const i of (Array.isArray(ings) ? ings : [ings])) {
        const s = parseStack(i); if (!s) return ANY;
        for (let c = 0; c < s.count; c++) list.push(s.opts);
      }
      if (!list.length || list.length > 9) return ANY;
      return addRecipe({ id: 'kubejs:auto_' + (autoId++), k: 'l', out: o.out, n: o.n, i: list });
    },
    replaceInput(f, from, to) {
      const a = parseStack(from), b = parseStack(to); if (!a || !b) return;
      for (const r of recipes) {
        if (!matches(r, f) && !(f && typeof f === 'object' && !Object.keys(f).length)) continue;
        const fix = (opts) => (opts && opts.some(o => a.opts.includes(o)) ? (log.replaced++, b.opts.slice()) : opts);
        if (r.k === 's') r.g = r.g.map(fix); else if (r.k === 'f' || r.k === 'b') r.c = fix(r.c); else r.i = r.i.map(fix);
      }
    },
    replaceOutput(f, from, to) {
      const a = parseStack(from), b = parseStack(to); if (!a || !b) return;
      for (const r of recipes) if (matches(r, f) && a.opts.includes(r.out)) r.out = b.opts[0];
    },
    custom(j) {
      try {
        const t = String(j.type || '');
        if (/smelting$/.test(t) || /blasting$/.test(t)) return e._cook(/blasting$/.test(t) ? 'b' : 'f', j.result, j.ingredient);
        if (!/crafting_shaped|crafting_shapeless/.test(t)) return ANY;
        const res = j.result || j.output; const o = outOf(res); if (!o) return ANY;
        if (j.pattern && j.key) {
          const key = {}; for (const k in j.key) key[k] = j.key[k];
          return e.shaped(res, j.pattern, key);
        }
        if (j.ingredients) return e.shapeless(res, j.ingredients);
      } catch (err) { log.errors.push('custom ' + err.message); }
      return ANY;
    },
    findRecipes: () => ANY, forEachRecipe: () => {}, countRecipes: () => 0, containsRecipe: () => false,
    smithing: () => ANY, smoking: () => ANY,
    smelting(out, input) { return e._cook('f', out, input); },
    blasting(out, input) { return e._cook('b', out, input); },
    _cook(k, out, input) {
      const o = outOf(out); const s = parseStack(input);
      if (!o || !s) return ANY;
      return addRecipe({ id: 'kubejs:auto_' + (autoId++), k, out: o.out, n: o.n, c: s.opts });
    },
    campfireCooking: () => ANY, stonecutting: () => ANY,
  };
  return new Proxy(e, { get: (t, k) => (k in t ? t[k] : ANY) });
}

// ---------- tag event ----------
function tagVals(x) {
  if (Array.isArray(x)) return x.flatMap(tagVals);
  if (x && x.__stack) return x.opts;
  if (typeof x === 'string') return [x];
  return [];
}
function tagEvent() {
  const e = {
    add(tag, items) { const t = (tags[tag] = tags[tag] || []); for (const v of tagVals(items)) if (!t.includes(v)) t.push(v); log.tagops++; return e; },
    remove(tag, items) { const vs = tagVals(items); if (tags[tag]) tags[tag] = tags[tag].filter(v => !vs.includes(v)); log.tagops++; return e; },
    removeAll(tag) { tags[tag] = []; log.tagops++; return e; },
    removeAllTagsFrom(items) { const vs = tagVals(items); for (const k in tags) tags[k] = tags[k].filter(v => !vs.includes(v)); return e; },
    get(tag) { return { add: (i) => e.add(tag, i), remove: (i) => e.remove(tag, i), removeAll: () => e.removeAll(tag), getObjectIds: () => [] }; },
  };
  return new Proxy(e, { get: (t, k) => (k in t ? t[k] : ANY) });
}

// ---------- load scripts ----------
const recipeCbs = [], tagCbs = [];
const ServerEvents = new Proxy({
  recipes: (cb) => recipeCbs.push(cb),
  tags: (type, cb) => { if (String(type).includes('item')) tagCbs.push(cb); },
}, { get: (t, k) => (k in t ? t[k] : () => {}) });

const known = { ServerEvents, Item, Ingredient, console: { log() {}, info() {}, warn() {}, error() {} },
  JSON, Math, Object, Array, String, Number, RegExp, Boolean, Date, parseInt, parseFloat, isNaN, Map, Set,
  Symbol, Error, Infinity, NaN, undefined, global: {}, Utils: ANY, Platform: ANY, Java: ANY, JsonIO: ANY };
const sandbox = new Proxy(known, {
  has: () => true,
  get: (t, k) => (k in t ? t[k] : k === Symbol.unscopables ? undefined : ANY),
  set: (t, k, v) => { t[k] = v; return true; },
});
const ctx = vm.createContext(sandbox);

function walk(d) {
  let out = [];
  for (const f of fs.readdirSync(d).sort()) {
    const p = path.join(d, f);
    if (fs.statSync(p).isDirectory()) out = out.concat(walk(p)); else if (f.endsWith('.js')) out.push(p);
  }
  return out;
}
for (const f of walk(DIR)) {
  try { vm.runInContext(fs.readFileSync(f, 'utf8'), ctx, { filename: f, timeout: 5000 }); }
  catch (err) { log.errors.push(path.relative(DIR, f) + ': ' + err.message); }
}
for (const cb of tagCbs) { try { cb(tagEvent()); } catch (err) { log.errors.push('tags: ' + err.message); } }
for (const cb of recipeCbs) { try { cb(recipeEvent()); } catch (err) { log.errors.push('recipes: ' + (err.stack || err.message).split('\n').slice(0, 2).join(' | ')); } }

db.recipes = recipes;
fs.writeFileSync(OUT, JSON.stringify(db));
console.log(JSON.stringify({ ...log, errors: log.errors.slice(0, 20), nerr: log.errors.length, total: recipes.length }, null, 1));
