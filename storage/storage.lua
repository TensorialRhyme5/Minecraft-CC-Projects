-- ============================================================
--  STORAGE MANAGER  -  CC: Tweaked
--  Tracks every storage chest on the wired network, searches,
--  retrieves to a pickup barrel, auto-sorts an input chest and
--  warns when items run low.
-- ============================================================

local CFG = {
  input      = "minecraft:chest_0",    -- dump items here, they get filed away
  pickup     = "minecraft:barrel_0",   -- usual pickup barrel (any barrel works if this one is replaced)
  textScale  = 0.5,
  scanEvery  = 10,                     -- seconds between full re-scans
  sortEvery  = 2,                      -- seconds between input-chest checks
}

-- ---------------------------------------------------------- monitor
local mons = {}
for _, m in ipairs({ peripheral.find("monitor") }) do
  if m.isColour() then mons[#mons + 1] = { p = m, name = peripheral.getName(m), last = {} } end
end
if #mons == 0 then error("No advanced monitor found.", 0) end
local monNames = {}
for _, m in ipairs(mons) do monNames[m.name] = true end
local speaker = peripheral.find("speaker")

local PAL = {
  [colors.black] = 0x070912, [colors.brown] = 0x151a2e, [colors.blue] = 0x2a3270,
  [colors.gray] = 0x4c5272, [colors.lightGray] = 0xa0a6c4, [colors.white] = 0xf2f4ff,
  [colors.cyan] = 0x38c6ff, [colors.lime] = 0x6fd65a, [colors.yellow] = 0xffd23f,
  [colors.orange] = 0xff9a3a, [colors.red] = 0xff4a4a, [colors.purple] = 0x9b5cff, [colors.green] = 0x2f9e4f,
}
for _, m in ipairs(mons) do for c, v in pairs(PAL) do m.p.setPaletteColour(c, v) end end
local WHITE, ORANGE, YELLOW, LIME, GRAY, LGRAY = "0", "1", "4", "5", "7", "8"
local CYAN, PURPLE, HILITE, PANEL, RED, BLACK = "9", "a", "b", "c", "e", "f"
local GREEN = "d"

-- ---------------------------------------------------------- framebuffer
local W, H = math.huge, math.huge
for _, m in ipairs(mons) do
  m.p.setTextScale(CFG.textScale)
  local w, h = m.p.getSize()
  W, H = math.min(W, w), math.min(H, h)
  m.p.setBackgroundColour(colors.black); m.p.clear()
end
local fbC, fbF, fbB = {}, {}, {}
for y = 1, H do fbC[y], fbF[y], fbB[y] = {}, {}, {} end
local function clear()
  for y = 1, H do for x = 1, W do fbC[y][x], fbF[y][x], fbB[y][x] = " ", WHITE, BLACK end end
end
local function setCell(x, y, ch, fg, bg)
  if x < 1 or x > W or y < 1 or y > H then return end
  fbC[y][x] = ch
  if fg then fbF[y][x] = fg end
  if bg then fbB[y][x] = bg end
end
local function text(x, y, s, fg, bg) for i = 1, #s do setCell(x + i - 1, y, s:sub(i, i), fg, bg) end end
local function fill(x1, y1, x2, y2, bg) for y = y1, y2 do for x = x1, x2 do setCell(x, y, " ", WHITE, bg) end end end
local function present()
  for y = 1, H do
    local c, f, b = table.concat(fbC[y]), table.concat(fbF[y]), table.concat(fbB[y])
    local key = c .. f .. b
    for _, m in ipairs(mons) do
      if m.last[y] ~= key then m.p.setCursorPos(1, y); m.p.blit(c, f, b); m.last[y] = key end
    end
  end
end

-- ---------------------------------------------------------- helpers
local function now() return os.epoch("utc") / 1000 end
local function commas(n)
  local s = tostring(math.floor(n))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end
local function prettyId(id)                                  -- "minecraft:iron_ingot" -> "Iron Ingot"
  local n = id:match(":(.+)$") or id
  n = n:gsub("_", " ")
  return (n:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end
local function clean(s)
  s = tostring(s or "")
  return (s:gsub("\194\167.", ""):gsub("[\192-\255][\128-\191]*", "?"))   -- strip colour codes / unicode
end
local function shortInv(name)                                -- "sophisticatedstorage:chest_3" -> "chest 3"
  local n = name:match(":(.+)$") or name
  return (n:gsub("_", " "))
end
local function fit(s, w) if #s > w then return s:sub(1, math.max(1, w - 1)) .. "." end return s end

-- ---------------------------------------------------------- saved settings (alerts + item names)
local SAVE = "storage_data.txt"
local data = { alerts = {}, names = {}, sort = "count" }
if fs.exists(SAVE) then
  local f = fs.open(SAVE, "r")
  local ok, d = pcall(textutils.unserialize, f.readAll())
  f.close()
  if ok and type(d) == "table" then
    data.alerts = type(d.alerts) == "table" and d.alerts or {}
    data.names = type(d.names) == "table" and d.names or {}
    data.sort = d.sort == "name" and "name" or "count"
  end
end
local dirty = false
local function save()
  local f = fs.open(SAVE, "w"); f.write(textutils.serialize(data)); f.close()
  dirty = false
end

-- ---------------------------------------------------------- inventory index
local storages = {}          -- names of storage inventories
local index = {}             -- key -> { id, name, count, locs = { {inv, slot, count} } }
                             -- key is the item id, or "id#variant" for enchanted books, potions, enchanted gear...
local byName = {}            -- item id -> every variant together (what recipes use)
local items = {}             -- sorted list for display
local stats = { slots = 0, used = 0, total = 0, types = 0, scanned = 0 }
local status = { msg = "Scanning storage...", col = LGRAY, at = 0 }
local function setStatus(msg, col) status.msg, status.col, status.at = msg, col or LGRAY, now() end

-- the pickup spot can hold a barrel OR a Sophisticated Backpack; neither is ever used as storage
local function isPickupName(name)
  return name == CFG.pickup or name:find("^minecraft:barrel") ~= nil or name:find("^sophisticatedbackpacks:") ~= nil
end
local function currentPickup()
  local barrel
  for _, name in ipairs(peripheral.getNames()) do
    if name:find("^sophisticatedbackpacks:") then return name, "BACKPACK" end   -- a docked backpack wins
    if not barrel and (name == CFG.pickup or name:find("^minecraft:barrel")) then barrel = name end
  end
  if peripheral.isPresent(CFG.pickup) then barrel = CFG.pickup end
  return barrel, barrel and "BARREL" or nil
end

local function isInventory(name)
  if name == CFG.input or isPickupName(name) then return false end
  if monNames[name] then return false end
  if peripheral.hasType then
    local ok, has = pcall(peripheral.hasType, name, "inventory")
    if ok then return has end
  end
  local ok, methods = pcall(peripheral.getMethods, name)        -- older CC: look for inventory methods
  if not ok or type(methods) ~= "table" then return false end
  for _, m in ipairs(methods) do if m == "pushItems" then return true end end
  return false
end

local function findStorages()
  storages = {}
  for _, name in ipairs(peripheral.getNames()) do
    if isInventory(name) then storages[#storages + 1] = name end
  end
  table.sort(storages)
end

-- ---------------------------------------------------------- recipe book
-- recipes.txt is built from the modpack (mod jars + KubeJS scripts) and lives in the repo.
-- It is downloaded into memory at startup, so it never uses the computer's disk space.
local RECIPE_URL = "https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-CC-Projects/main/storage/recipes.txt"
local R = {
  state = "loading", msg = "Loading recipe book...",
  id = {}, name = {}, byId = {},       -- item index <-> id / display name
  tagName = {}, tagRaw = {}, tagMem = {},
  grpRaw = {}, grpMem = {},           -- ingredient groups ("3,t12" -> list of item indexes)
  byOut = {},                         -- item index -> { {n=, k=, g=raw}, ... }
  outs = {},                          -- sorted list of craftable item indexes
}

local function rYield(i) if i % 2000 == 0 then os.queueEvent("recipe_yield"); os.pullEvent("recipe_yield") end end

local function loadRecipes()
  R.state, R.msg = "loading", "Downloading recipe book..."
  local ok, h = pcall(http.get, RECIPE_URL .. "?t=" .. os.epoch("utc"))
  if not ok or not h then R.state, R.msg = "failed", "Recipe download failed (tap RECIPES to retry)"; return end
  local body = h.readAll(); h.close()
  if not body or #body < 1000 then R.state, R.msg = "failed", "Recipe file was empty (tap RECIPES to retry)"; return end
  R.msg = "Reading recipe book..."
  local id, name, byId, tagName, tagRaw, grpRaw, byOut = {}, {}, {}, {}, {}, {}, {}
  local ni, nt, ng, i = 0, 0, 0, 0
  for line in body:gmatch("[^\n]+") do
    i = i + 1; rYield(i)
    local kind = line:sub(1, 1)
    if kind == "R" then
      local out, n, k, g = line:match("^R\t(%d+)\t(%d+)\t(%a)\t(.*)$")
      if out then
        out = tonumber(out)
        local l = byOut[out]; if not l then l = {}; byOut[out] = l end
        l[#l + 1] = { n = tonumber(n), k = k, g = g }
      end
    elseif kind == "G" then ng = ng + 1; grpRaw[ng] = line:sub(3)
    elseif kind == "I" then
      local a, b = line:match("^I\t([^\t]+)\t(.*)$")
      ni = ni + 1; id[ni] = a; name[ni] = b; byId[a] = ni
    elseif kind == "T" then
      local a, b = line:match("^T\t([^\t]+)\t(.*)$")
      nt = nt + 1; tagName[nt] = a; tagRaw[nt] = b or ""
    end
  end
  body = nil
  local seenName = {}                             -- two items called "Chest"? add the mod name
  for j = 1, ni do seenName[name[j]] = (seenName[name[j]] or 0) + 1 end
  for j = 1, ni do
    if seenName[name[j]] > 1 then name[j] = name[j] .. " (" .. (id[j]:match("^([^:]+)") or "?") .. ")" end
  end
  local outs = {}
  for o in pairs(byOut) do outs[#outs + 1] = o end
  table.sort(outs, function(a, b) return name[a] < name[b] end)
  R.id, R.name, R.byId, R.tagName, R.tagRaw, R.grpRaw, R.byOut, R.outs = id, name, byId, tagName, tagRaw, grpRaw, byOut, outs
  R.tagMem, R.grpMem = {}, {}
  R.lower = {}
  R.lname, R.lns = {}, {}
  for j, o in ipairs(outs) do
    R.lname[j] = name[o]:lower(); R.lower[j] = R.lname[j] .. "\0" .. id[o]
    R.lns[j] = R.lname[j]:gsub(" %(.*%)$", ""):gsub("%s+", "")
  end
  R.state, R.msg = "ready", #outs .. " craftable items, " .. i .. " lines"
end

local function splitNums(s)
  local t = {}
  for v in s:gmatch("[^,]+") do t[#t + 1] = v end
  return t
end
local function tagMembers(t)
  local m = R.tagMem[t]
  if not m then
    m = {}
    for _, v in ipairs(splitNums(R.tagRaw[t] or "")) do m[#m + 1] = tonumber(v) end
    R.tagMem[t] = m
  end
  return m
end
-- every item that can fill an ingredient slot
local function groupItems(g)
  local m = R.grpMem[g]
  if not m then
    m = {}
    local seen = {}
    for _, tok in ipairs(splitNums(R.grpRaw[g] or "")) do
      if tok:sub(1, 1) == "t" then
        for _, it in ipairs(tagMembers(tonumber(tok:sub(2)))) do if not seen[it] then seen[it] = true; m[#m + 1] = it end end
      else
        local it = tonumber(tok)
        if not seen[it] then seen[it] = true; m[#m + 1] = it end
      end
    end
    R.grpMem[g] = m
  end
  return m
end
local function groupLabel(g)                      -- a real item name for a slot (vanilla first), else the tag
  local items = groupItems(g)
  local pick
  for _, it in ipairs(items) do if (R.id[it] or ""):find("^minecraft:") then pick = it; break end end
  pick = pick or items[1]
  if pick then return (R.name[pick]:gsub(" %(.*%)$", "")) end
  local tok = (R.grpRaw[g] or ""):match("^[^,]+") or ""
  if tok:sub(1, 1) == "t" then return "#" .. (R.tagName[tonumber(tok:sub(2))] or "?") end
  return "?"
end
local function itemName(i)                        -- recipe item index -> display name
  local id = R.id[i]
  return (id and data.names[id]) or R.name[i] or "?"
end
local function stock(i) local e = byName[R.id[i] or ""]; return e and e.count or 0 end

-- slots of a recipe: list of 9 (shaped, 0 = empty) or n (shapeless) group numbers
local function recipeSlots(rc)
  if not rc.slots then
    rc.slots = {}
    for _, v in ipairs(splitNums(rc.g)) do rc.slots[#rc.slots + 1] = tonumber(v) end
  end
  return rc.slots
end

-- Work out which items to pull for `crafts` crafts. Tags/alternatives use whatever is in stock,
-- most-stocked first, and may mix (e.g. oak + birch planks both work in a planks slot).
local function craftPlan(rc, crafts)
  local need = {}
  local order = {}
  for _, g in ipairs(recipeSlots(rc)) do
    if g > 0 then
      if not need[g] then need[g] = 0; order[#order + 1] = g end
      need[g] = need[g] + crafts
    end
  end
  table.sort(order, function(a, b) return #groupItems(a) < #groupItems(b) end)   -- pickiest slots first
  local used, take, missing, pick = {}, {}, {}, {}
  for _, g in ipairs(order) do
    local opts = {}
    for _, it in ipairs(groupItems(g)) do
      local free = stock(it) - (used[it] or 0)
      if free > 0 then opts[#opts + 1] = { it = it, free = free } end
    end
    table.sort(opts, function(a, b) return a.free > b.free end)
    local left = need[g]
    for _, o in ipairs(opts) do
      if left <= 0 then break end
      local n = math.min(left, o.free)
      used[o.it] = (used[o.it] or 0) + n
      take[o.it] = (take[o.it] or 0) + n
      pick[g] = pick[g] or o.it
      left = left - n
    end
    if left > 0 then missing[g] = left end
  end
  local list, short = {}, 0
  for it, n in pairs(take) do list[#list + 1] = { it = it, n = n } end
  for _, n in pairs(missing) do short = short + n end
  return { take = list, missing = missing, need = need, order = order, pick = pick, short = short }
end
local function canCraft(rc, crafts) return craftPlan(rc, crafts or 1).short == 0 end
local pickupFree = nil        -- free slots in the pickup barrel/backpack (nil = unknown)
local function fitsPickup(plan)
  if not pickupFree then return true end
  local slots = 0
  for _, x in ipairs(plan.take) do slots = slots + math.ceil(x.n / 64) end
  return slots <= pickupFree
end
local function okCrafts(rc, n) local p = craftPlan(rc, n); return p.short == 0 and fitsPickup(p) end
local function maxCrafts(rc)                      -- most crafts you have items for AND that fit in the pickup
  if not okCrafts(rc, 1) then return canCraft(rc, 1) and 1 or 0 end
  local canCraft = okCrafts
  local lo, hi = 1, 2
  while hi <= 4096 and canCraft(rc, hi) do lo = hi; hi = hi * 2 end
  if hi > 4096 then return 4096 end
  while hi - lo > 1 do local mid = math.floor((lo + hi) / 2); if canCraft(rc, mid) then lo = mid else hi = mid end end
  return lo
end
-- best recipe to show first: one you can make, else the one missing the least
local function rankRecipes(out)
  local l = R.byOut[out] or {}
  local ranked = {}
  for _, rc in ipairs(l) do ranked[#ranked + 1] = { rc = rc, short = craftPlan(rc, 1).short } end
  table.sort(ranked, function(a, b) return a.short < b.short end)
  local res = {}
  for i, r in ipairs(ranked) do res[i] = r.rc end
  return res
end

local UI = { search = "", page = 1, selected = nil, perPage = 0, lowAlerted = {},
  mode = "items", rsel = nil, rvar = 1, crafts = 1, canMake = false }

-- ---------------------------------------------------------- typo-tolerant search
-- Edit distance that also counts two swapped letters as one mistake ("daimnod" -> "diamond" = 2).
local function typoDist(a, b, limit)
  local la, lb = #a, #b
  if math.abs(la - lb) > limit then return limit + 1 end
  local prev2, prev, cur = {}, {}, {}
  for j = 0, lb do prev[j] = j end
  for i = 1, la do
    cur = { [0] = i }
    local ai, rowMin = a:byte(i), i
    for j = 1, lb do
      local bj = b:byte(j)
      local cost = ai == bj and 0 or 1
      local v = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
      if i > 1 and j > 1 and ai == b:byte(j - 1) and a:byte(i - 1) == bj then v = math.min(v, prev2[j - 2] + 1) end
      cur[j] = v
      if v < rowMin then rowMin = v end
    end
    if rowMin > limit then return limit + 1 end
    prev2, prev = prev, cur
  end
  return prev[lb]
end

local wordCache = setmetatable({}, { __mode = "k" })
local function wordsOf(lowerName)
  local w = wordCache[lowerName]
  if not w then
    w = {}
    for word in lowerName:gmatch("[%w']+") do w[#w + 1] = word end
    wordCache[lowerName] = w
  end
  return w
end

-- every word you typed must be close to some word of the name; returns total mistakes or nil
local function fuzzyScore(qwords, lowerName)
  local words = wordsOf(lowerName)
  local total = 0
  for _, qw in ipairs(qwords) do
    local n = #qw
    local allow = n <= 2 and 0 or (n <= 4 and 1 or (n <= 7 and 2 or 3))
    local best = allow + 1
    local q1, q2 = qw:sub(1, 1), qw:sub(2, 2)
    for _, w in ipairs(words) do
      local w1 = w:sub(1, 1)
      if w1 == q1 or w1 == q2 or w:sub(2, 2) == q1 then          -- cheap filter: the start has to be close
        local d
        if allow == 0 then d = (w:sub(1, n) == qw) and 0 or 1
        else
          d = typoDist(qw, w, allow)
          if d > 0 and #w > n then d = math.min(d, typoDist(qw, w:sub(1, n), allow) + 0.5) end   -- still typing
        end
        if d < best then best = d; if d == 0 then break end end
      end
    end
    if best > allow + 0.5 then return nil end
    total = total + best
  end
  return total
end
local function queryWords(q)
  local t = {}
  for w in q:gmatch("[%w']+") do t[#t + 1] = w end
  return t
end
local FUZZY_BELOW = 10        -- look for close matches when the normal search finds fewer than this

local function rebuildList(quick)
  items = {}
  UI.fuzzy, UI.didYouMean = false, nil
  UI.fuzzyAt = nil
  local q = UI.search:lower()
  local qs = q:gsub("%s+", "")                     -- "pokeball" also finds "Poke Ball"
  local wantFuzzy = #q >= 3 and not quick
  if UI.mode == "recipes" then
    if R.state ~= "ready" then return end
    local only = UI.canMake and R.canSet
    for j, o in ipairs(R.outs) do
      if (q == "" or R.lower[j]:find(q, 1, true) or (#qs >= 3 and R.lns[j]:find(qs, 1, true)))
         and (not UI.canMake or (only and only[o])) then
        local nm = R.name[o]
        local l = nm:lower():gsub(" %(.*%)$", "")
        local ls = R.lns[j]
        local rank = q == "" and 2 or ((l == q or ls == qs) and 0 or ((l:sub(1, #q) == q or ls:sub(1, #qs) == qs) and 1 or 2))
        items[#items + 1] = { ri = o, name = nm, rank = rank }
      end
    end
    local qw = queryWords(q)
    if #items < FUZZY_BELOW and #q >= 3 and #qw > 0 and not wantFuzzy then UI.fuzzyAt = now() + 0.4 end
    if #items < FUZZY_BELOW and wantFuzzy and #qw > 0 then
      local have = {}
      for _, it in ipairs(items) do have[it.ri] = true end
      for j, o in ipairs(R.outs) do
        if not have[o] and (not UI.canMake or (only and only[o])) then
          local sc = fuzzyScore(qw, R.lname[j])
          if sc then
            items[#items + 1] = { ri = o, name = R.name[o], rank = 3 + sc, len = #(R.lname[j]:gsub(" %(.*%)$", "")) }
            UI.fuzzy = true
          end
        end
      end
    end
    if q ~= "" then
      table.sort(items, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.rank >= 3 and a.len ~= b.len then return a.len < b.len end   -- shortest close match = best guess
        local am, bm = R.id[a.ri]:find("^minecraft:") ~= nil, R.id[b.ri]:find("^minecraft:") ~= nil
        if am ~= bm then return am end                                     -- vanilla first on ties
        return a.name < b.name
      end)
    end
    if UI.fuzzy and items[1] and items[1].rank >= 3 then UI.didYouMean = items[1].name:gsub(" %(.*%)$", "") end
    return
  end
  for id, it in pairs(index) do
    local name = data.names[id] or prettyId(id)
    if q == "" or name:lower():find(q, 1, true) or id:lower():find(q, 1, true)
       or (#qs >= 3 and name:lower():gsub("%s+", ""):find(qs, 1, true)) then
      items[#items + 1] = { id = id, name = name, count = it.count }
    end
  end
  local qw = queryWords(q)
  if #items < FUZZY_BELOW and #q >= 3 and #qw > 0 and not wantFuzzy then UI.fuzzyAt = now() + 0.4 end
  if #items < FUZZY_BELOW and wantFuzzy and #qw > 0 then
    local have = {}
    for _, it in ipairs(items) do have[it.id] = true end
    local close = {}
    for id, it in pairs(index) do
      if not have[id] then
        local name = data.names[id] or prettyId(id)
        local sc = fuzzyScore(qw, name:lower())
        if sc then close[#close + 1] = { id = id, name = name, count = it.count, sc = sc } end
      end
    end
    table.sort(close, function(a, b)
      if a.sc ~= b.sc then return a.sc < b.sc end
      if #a.name ~= #b.name then return #a.name < #b.name end
      return a.count > b.count
    end)
    if #close > 0 then UI.fuzzy = true; if #items == 0 then UI.didYouMean = close[1].name end end
    table.sort(items, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.name < b.name end)
    for _, c in ipairs(close) do items[#items + 1] = c end
    return                                         -- exact hits first, then closest typos
  end
  if data.sort == "name" then
    table.sort(items, function(a, b) return a.name:lower() < b.name:lower() end)
  else
    table.sort(items, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.name < b.name end)
  end
end

-- these items always carry data (stored enchantments, potion type) even when list() has no "nbt" hash
local ALWAYS_VARIES = { ["minecraft:enchanted_book"] = true, ["minecraft:potion"] = true, ["minecraft:splash_potion"] = true,
  ["minecraft:lingering_potion"] = true, ["minecraft:tipped_arrow"] = true }
local variantCache = {}
local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }
local function enchList(d)
  local out = {}
  for _, e in ipairs(type(d.enchantments) == "table" and d.enchantments or {}) do
    local nm = e.displayName and clean(e.displayName)
    if not nm or nm == "" then
      nm = prettyId(e.name or "?")
      if e.level and e.level > 1 then nm = nm .. " " .. (ROMAN[e.level] or tostring(e.level)) end
    end
    out[#out + 1] = nm
  end
  return out
end
-- name shown in the list for an item that has enchantments / a potion type
local function variantLabel(d)
  local base = clean(d.displayName or prettyId(d.name or "?"))
  local ench = enchList(d)
  if #ench == 0 then return base end
  if d.name == "minecraft:enchanted_book" then return "Book: " .. table.concat(ench, ", ") end
  return base .. " (" .. table.concat(ench, ", ") .. ")"
end
local function variantOf(d)
  local ench = enchList(d)
  local sig
  if #ench > 0 then sig = table.concat(ench, ","):lower():gsub("%s+", "_")
  else sig = clean(d.displayName or ""):lower():gsub("%s+", "_") end
  return { sig = sig, label = variantLabel(d) }
end

local function scan()
  findStorages()
  local lists, sizes = {}, {}
  local jobs = {}
  for i, name in ipairs(storages) do
    jobs[#jobs + 1] = function()                               -- all chests are read at the same time
      local ok, l = pcall(peripheral.call, name, "list")
      lists[i] = ok and l or {}
      local ok2, s = pcall(peripheral.call, name, "size")
      sizes[i] = ok2 and s or 0
    end
  end
  if #jobs > 0 then parallel.waitForAll(table.unpack(jobs)) end
  -- items that only differ by enchantments / potion type get their own entry
  local need = {}
  for i, name in ipairs(storages) do
    for slot, it in pairs(lists[i] or {}) do
      if not it.nbt and ALWAYS_VARIES[it.name] then
        local ck = name .. ":" .. slot .. ":" .. it.name .. ":" .. it.count
        if not variantCache[ck] then need[#need + 1] = { inv = name, slot = slot, ck = ck } end
      end
    end
  end
  if #need > 0 then
    local fetch = {}
    for _, x in ipairs(need) do
      fetch[#fetch + 1] = function()
        local ok, d = pcall(peripheral.call, x.inv, "getItemDetail", x.slot)
        variantCache[x.ck] = (ok and type(d) == "table") and variantOf(d) or false
      end
    end
    for k = 1, #fetch, 64 do parallel.waitForAll(table.unpack(fetch, k, math.min(#fetch, k + 63))) end
  end
  local newIndex, newByName, seen = {}, {}, {}
  local slots, used, total = 0, 0, 0
  for i, name in ipairs(storages) do
    slots = slots + (sizes[i] or 0)
    for slot, it in pairs(lists[i] or {}) do
      used = used + 1
      total = total + it.count
      local key, label = it.name, nil
      if it.nbt then key = it.name .. "#" .. it.nbt
      elseif ALWAYS_VARIES[it.name] then
        local ck = name .. ":" .. slot .. ":" .. it.name .. ":" .. it.count
        seen[ck] = true
        local v = variantCache[ck]
        if v then key, label = it.name .. "#" .. v.sig, v.label end
      end
      if label and not data.names[key] then data.names[key] = label; dirty = true end
      local e = newIndex[key]
      if not e then e = { id = key, name = it.name, count = 0, locs = {} }; newIndex[key] = e end
      e.count = e.count + it.count
      local loc = { inv = name, slot = slot, count = it.count, plain = key == it.name }
      e.locs[#e.locs + 1] = loc
      local b = newByName[it.name]
      if not b then b = { id = it.name, name = it.name, count = 0, locs = {} }; newByName[it.name] = b end
      b.count = b.count + it.count
      b.locs[#b.locs + 1] = loc
    end
  end
  for ck in pairs(variantCache) do if not seen[ck] then variantCache[ck] = nil end end
  for _, b in pairs(newByName) do                    -- plain copies get used first by recipes
    table.sort(b.locs, function(a, c) if a.plain ~= c.plain then return a.plain end return a.count > c.count end)
  end
  index, byName = newIndex, newByName
  R.ready = {}
  local pk = currentPickup()
  pickupFree = nil
  if pk then
    local ok, l = pcall(peripheral.call, pk, "list")
    local ok2, sz = pcall(peripheral.call, pk, "size")
    if ok and ok2 and type(l) == "table" and type(sz) == "number" then
      local used = 0
      for _ in pairs(l) do used = used + 1 end
      pickupFree = sz - used
    end
  end
  local types = 0
  for _ in pairs(index) do types = types + 1 end
  stats = { slots = slots, used = used, total = total, types = types, scanned = now(), chests = #storages }
  rebuildList()
  -- low-stock ping (once per item until it recovers)
  for id, limit in pairs(data.alerts) do
    local have = index[id] and index[id].count or 0
    if have < limit then
      if not UI.lowAlerted[id] then
        UI.lowAlerted[id] = true
        if speaker then pcall(speaker.playNote, "bell", 1, 18) end
      end
    else UI.lowAlerted[id] = nil end
  end
end

-- fill in real display names a few at a time (they are remembered between restarts)
local function resolveNames(limit)
  local done = 0
  for id, e in pairs(index) do
    if not data.names[id] and e.locs[1] then
      local l = e.locs[1]
      local ok, d = pcall(peripheral.call, l.inv, "getItemDetail", l.slot)
      if ok and type(d) == "table" and d.displayName then
        data.names[id] = (id ~= e.name) and variantLabel(d) or clean(d.displayName); dirty = true
      else
        data.names[id] = prettyId(e.name or id); dirty = true
      end
      done = done + 1
      if done >= limit then break end
    end
  end
  if done > 0 then rebuildList() end
  if dirty then save() end
  return done
end

-- ---------------------------------------------------------- moving items
local tasks = {}
local busy = nil              -- progress text while organizing / crafting
local function queue(t) tasks[#tasks + 1] = t; os.queueEvent("storage_task") end

local function retrieve(id, want)
  local e = id:find("#", 1, true) and index[id] or byName[id]   -- a plain id means "any copy" (recipes)
  if not e then return 0 end
  local target = currentPickup()
  if not target then return 0, "no barrel or backpack connected" end
  local moved = 0
  for _, l in ipairs(e.locs) do
    if moved >= want then break end
    local ok, n = pcall(peripheral.call, l.inv, "pushItems", target, l.slot, math.min(want - moved, l.count))
    if ok and type(n) == "number" then moved = moved + n end
    if ok and n == 0 then break end                             -- pickup barrel is full
  end
  return moved
end

-- ---------------------------------------------------------- auto-crafting (crafty turtle)
-- Layout: [full wired modem] [TURTLE] -> [pickup barrel]. We put the ingredients in the barrel,
-- line them up at the front of it, and tell the turtle which item goes in which grid slot.
local PROTO = "storagecraft"
local CRAFTER = { id = nil, checked = 0 }
local netOpen = false
local function openNet()
  if netOpen then return true end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then pcall(rednet.open, name); netOpen = true end
  end
  return netOpen
end
local function findCrafter(force)
  if CRAFTER.id and not force then return CRAFTER.id end
  if not openNet() then return nil end
  local id = rednet.lookup(PROTO)
  if type(id) == "table" then id = id[1] end
  CRAFTER.id, CRAFTER.checked = id, now()
  return id
end

local maxStackCache = {}
local function maxStack(id)
  if maxStackCache[id] then return maxStackCache[id] end
  local e = byName[id]
  local m = 64
  if e and e.locs[1] then
    local ok, d = pcall(peripheral.call, e.locs[1].inv, "getItemDetail", e.locs[1].slot)
    if ok and type(d) == "table" and d.maxCount then m = d.maxCount end
  end
  maxStackCache[id] = m
  return m
end

-- every grid cell needs k of ONE item (a turtle slot can't mix oak and birch planks)
local function cellAssign(rc, k)
  local slots = recipeSlots(rc)
  local cells = {}
  for i, g in ipairs(slots) do if g > 0 then cells[#cells + 1] = { i = i, g = g } end end
  table.sort(cells, function(a, b) return #groupItems(a.g) < #groupItems(b.g) end)
  local used, assign = {}, {}
  for _, c in ipairs(cells) do
    local best, bestFree
    for _, it in ipairs(groupItems(c.g)) do
      local free = stock(it) - (used[it] or 0)
      if free >= k and (not best or free > bestFree) then best, bestFree = it, free end
    end
    if not best then return nil end
    used[best] = (used[best] or 0) + k
    assign[c.i] = best
  end
  for it in pairs(used) do if maxStack(R.id[it]) < k then return nil end end
  return assign, used
end
local function biggestBatch(rc, want)            -- largest batch (<= 64) we can lay out right now
  local lo, hi = 0, math.min(64, want)
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if cellAssign(rc, mid) then lo = mid else hi = mid - 1 end
  end
  if lo == 0 then return 0 end
  local a, u = cellAssign(rc, lo)
  return lo, a, u
end

-- move the job's items to the first slots of the barrel so the turtle grabs them first
local function arrangePickup(pk, need)
  local okL, l = pcall(peripheral.call, pk, "list")
  local okS, size = pcall(peripheral.call, pk, "size")
  if not (okL and okS and type(l) == "table") then return false end
  local jobSlots = {}
  for slot, it in pairs(l) do if need[it.name] then jobSlots[#jobSlots + 1] = slot end end
  table.sort(jobSlots)
  local front = 1
  for _, s in ipairs(jobSlots) do
    if s ~= front then
      if l[front] then                                   -- something else is in the way: park it at the back
        local empty
        for e = size, front + 1, -1 do if not l[e] then empty = e; break end end
        if not empty then return false end
        pcall(peripheral.call, pk, "pushItems", pk, front, nil, empty)
        l[empty], l[front] = l[front], nil
      end
      pcall(peripheral.call, pk, "pushItems", pk, s, nil, front)
      l[front], l[s] = l[s], nil
    end
    front = front + 1
  end
  return true
end

local jobCounter = 0
local function autoCraft(t)
  local id = findCrafter(true)
  if not id then return 0, "no crafter turtle found on the network" end
  local remaining, made = t.crafts, 0
  while remaining > 0 do
    scan()
    local pk = currentPickup()
    if not pk then return made, "no barrel or backpack connected" end
    local k, assign, used = biggestBatch(t.rc, remaining)
    if k == 0 then return made, made > 0 and "ran out of ingredients" or "missing ingredients" end
    busy = (t.step or "") .. "Crafting " .. t.name .. "  " .. (t.crafts - remaining) .. "/" .. t.crafts
    local need = {}
    for it, n in pairs(used) do
      local got = retrieve(R.id[it], n)
      need[R.id[it]] = n
      if got < n then return made, "pickup is full" end
    end
    if not arrangePickup(pk, need) then return made, "pickup is too full to sort" end
    jobCounter = jobCounter + 1
    local cells = {}
    for cell, it in pairs(assign) do
      local r, c = math.floor((cell - 1) / 3), (cell - 1) % 3
      cells[r * 4 + c + 1] = R.id[it]
    end
    local nslots = 0
    for _ in pairs(cells) do nslots = nslots + 1 end
    local job = { type = "craft", job = jobCounter, cells = cells, k = k, out = R.id[t.out], slots = nslots, n = t.rc.n }
    rednet.send(id, job, PROTO)
    local deadline = os.clock() + 20 + k * 0.3
    local reply
    repeat
      local from, msg = rednet.receive(PROTO, math.max(0.1, deadline - os.clock()))
      if from == id and type(msg) == "table" and msg.type == "done" and msg.job == jobCounter then reply = msg end
    until reply or os.clock() >= deadline
    if not reply then return made, "the crafter turtle didn't answer" end
    if not reply.ok then return made, reply.err or "craft failed" end
    made = made + (reply.made or 0)
    remaining = remaining - k
  end
  return made
end

-- ---------------------------------------------------------- crafting missing parts first
-- Plans a whole chain (logs -> planks -> sticks -> pickaxe) against a "virtual" copy of the
-- storage counts, so a slot only turns green when everything under it can really be made.
local CHAIN_DEPTH, CHAIN_BUDGET = 8, 2500          -- how deep / how much the search may look
local BASE = setmetatable({}, { __index = function(_, it) return stock(it) end })
local function child(vs) return setmetatable({}, { __index = vs }) end
local function commit(from, to) for k, v in pairs(from) do to[k] = v end end

-- how short a recipe is of being craftable straight from storage (0 = ready now)
local shortMemo = {}
local function directShort(rc)
  local m = shortMemo[rc]
  if not m or m.scan ~= stats.scanned then m = { scan = stats.scanned, v = craftPlan(rc, 1).short }; shortMemo[rc] = m end
  return m.v
end
-- recipes for an item, the ones closest to craftable first
local function orderedRecipes(it)
  local l = {}
  for _, rc in ipairs(R.byOut[it]) do l[#l + 1] = rc end
  table.sort(l, function(a, b) return directShort(a) < directShort(b) end)
  return l
end
local function craftCandidates(g, chain)
  local list, score = {}, {}
  for _, it in ipairs(groupItems(g)) do
    if R.byOut[it] and not chain[it] then
      list[#list + 1] = it
      local best = math.huge
      for _, rc in ipairs(R.byOut[it]) do best = math.min(best, directShort(rc)) end
      score[it] = best
    end
  end
  table.sort(list, function(a, b)
    if score[a] ~= score[b] then return score[a] < score[b] end
    local am, bm = (R.id[a] or ""):find("^minecraft:") ~= nil, (R.id[b] or ""):find("^minecraft:") ~= nil
    if am ~= bm then return am end
    return a < b
  end)
  while #list > 12 do table.remove(list) end
  return list
end

local planRecipe
-- make `amount` of something that fits group g (on top of what's in vs); returns steps or nil
local function planMake(g, amount, vs, depth, chain, budget)
  if depth >= (budget.max or CHAIN_DEPTH) then return nil end
  for _, it in ipairs(craftCandidates(g, chain)) do
    local recs = orderedRecipes(it)
    for r = 1, math.min(8, #recs) do
      local rc2 = recs[r]
      budget.n = budget.n - 1
      if budget.n < 0 then return nil end
      local sub = math.ceil(amount / rc2.n)
      local c = child(vs)
      chain[it] = true
      local steps = planRecipe(rc2, sub, c, depth + 1, chain, budget)
      chain[it] = nil
      if steps then
        commit(c, vs)
        vs[it] = vs[it] + sub * rc2.n - amount           -- the extra goes back into storage
        steps[#steps + 1] = { rc = rc2, out = it, crafts = sub }
        return steps
      end
    end
  end
  return nil
end

planRecipe = function(rc, crafts, vs, depth, chain, budget)
  local need, order = {}, {}
  for _, g in ipairs(recipeSlots(rc)) do
    if g > 0 then
      if not need[g] then need[g] = 0; order[#order + 1] = g end
      need[g] = need[g] + crafts
    end
  end
  table.sort(order, function(a, b) return #groupItems(a) < #groupItems(b) end)
  local steps = {}
  for _, g in ipairs(order) do
    local left = need[g]
    local opts = {}
    for _, it in ipairs(groupItems(g)) do if vs[it] > 0 then opts[#opts + 1] = it end end
    table.sort(opts, function(a, b) return vs[a] > vs[b] end)
    for _, it in ipairs(opts) do
      if left <= 0 then break end
      local n = math.min(left, vs[it])
      vs[it] = vs[it] - n; left = left - n
    end
    if left > 0 then
      local sub = planMake(g, left, vs, depth, chain, budget)
      if not sub then return nil, g end
      for _, st in ipairs(sub) do steps[#steps + 1] = st end   -- (planMake already used up what it made)
    end
  end
  return steps
end

-- whole plan for `crafts` of rc: list of sub-crafts to do first (empty = nothing to make first)
local chainCache = {}
local function chainPlan(rc, crafts, out)
  local key = tostring(rc) .. ":" .. crafts .. ":" .. tostring(stats.scanned)
  local c = chainCache[key]
  if c == nil then
    c = false
    for d = 1, CHAIN_DEPTH do                       -- shortest chains first
      local steps = planRecipe(rc, crafts, child(BASE), 0, { [out or -1] = true }, { n = CHAIN_BUDGET, max = d })
      if steps then c = steps; break end
    end
    chainCache = { [key] = c }                       -- only keep the latest
  end
  return c or nil
end
-- can the shortfall for this one slot be crafted from what's in storage?
local slotCache = {}
local function slotCraftable(g, short, out)
  local key = g .. ":" .. short .. ":" .. tostring(stats.scanned)
  if slotCache[key] == nil then
    if not next(slotCache) or slotCache._scan ~= stats.scanned then slotCache = { _scan = stats.scanned } end
    local okp = false
    for d = 1, CHAIN_DEPTH do
      if planMake(g, short, child(BASE), 0, { [out or -1] = true }, { n = CHAIN_BUDGET, max = d }) then okp = true; break end
    end
    slotCache[key] = okp
  end
  return slotCache[key]
end

-- crafted parts land in the pickup; put them back into storage so the next step can use them
local function pickupToStorage(id)
  local pk = currentPickup()
  if not pk then return end
  local ok, l = pcall(peripheral.call, pk, "list")
  if not ok or type(l) ~= "table" then return end
  for slot, it in pairs(l) do
    if it.name == id then
      local left = it.count
      local order, tried = {}, {}
      local e = byName[id]
      if e then for _, loc in ipairs(e.locs) do if not tried[loc.inv] then tried[loc.inv] = true; order[#order + 1] = loc.inv end end end
      for _, name in ipairs(storages) do if not tried[name] then order[#order + 1] = name end end
      for _, target in ipairs(order) do
        if left <= 0 then break end
        local ok2, n = pcall(peripheral.call, pk, "pushItems", target, slot)
        if ok2 and type(n) == "number" then left = left - n end
      end
    end
  end
end

local function chainCraft(t)
  scan()
  local steps
  for d = 1, CHAIN_DEPTH do
    steps = planRecipe(t.rc, t.crafts, child(BASE), 0, { [t.out] = true }, { n = CHAIN_BUDGET, max = d })
    if steps then break end
  end
  if not steps then return 0, "missing ingredients that can't be crafted" end
  local total = #steps + 1
  for i, st in ipairs(steps) do
    local name = itemName(st.out)
    local made, err = autoCraft({ rc = st.rc, out = st.out, crafts = st.crafts, name = name,
      step = "Step " .. i .. "/" .. total .. ": " })
    if err then return 0, "while making " .. name .. ": " .. err end
    pickupToStorage(R.id[st.out])
  end
  t.step = "Step " .. total .. "/" .. total .. ": "
  local made, err = autoCraft(t)
  return made, err, #steps
end

-- ORGANIZE: gather each item into one "home" chest (the one already holding the most of it),
-- then merge its partial stacks there so they take as few slots as possible.
local function organize()
  scan()
  local ids = {}
  for id in pairs(index) do ids[#ids + 1] = id end
  table.sort(ids)
  local moves, freed0 = 0, stats.used
  for n, id in ipairs(ids) do
    busy = "Organizing " .. n .. "/" .. #ids .. "  " .. (data.names[id] or prettyId(id))
    local e = index[id]
    if e then
      local per = {}
      for _, l in ipairs(e.locs) do per[l.inv] = (per[l.inv] or 0) + l.count end
      local home, best = nil, -1
      for inv, c in pairs(per) do if c > best or (c == best and inv < home) then home, best = inv, c end end
      -- 1) pull stacks from other chests into the home chest
      for _, l in ipairs(e.locs) do
        if l.inv ~= home then
          local ok, m = pcall(peripheral.call, l.inv, "pushItems", home, l.slot)
          if ok and type(m) == "number" and m > 0 then moves = moves + 1 end
        end
      end
      -- 2) merge partial stacks inside the home chest
      local ok, list = pcall(peripheral.call, home, "list")
      if ok and type(list) == "table" then
        local slots = {}
        for slot, it in pairs(list) do if it.name == id then slots[#slots + 1] = slot end end
        table.sort(slots)
        local first, last = 1, #slots
        while first < last do
          local ok2, m = pcall(peripheral.call, home, "pushItems", home, slots[last], nil, slots[first])
          if ok2 and type(m) == "number" and m > 0 then moves = moves + 1 end
          local ok3, d = pcall(peripheral.call, home, "getItemDetail", slots[last])
          if not (ok3 and d) then last = last - 1          -- emptied that stack
          else first = first + 1 end                       -- target stack is full, move to the next
        end
      end
    end
  end
  busy = nil
  scan()
  return moves, freed0 - stats.used
end

local function sortInput()
  if not peripheral.isPresent(CFG.input) then return 0, 0 end
  local ok, l = pcall(peripheral.call, CFG.input, "list")
  if not ok or type(l) ~= "table" then return 0, 0 end
  local moved, stuck = 0, 0
  for slot, it in pairs(l) do
    local left = it.count
    -- 1) chests that already hold this item, 2) every other chest
    local tried, order = {}, {}
    local e = byName[it.name]
    if e then for _, loc in ipairs(e.locs) do if not tried[loc.inv] then tried[loc.inv] = true; order[#order + 1] = loc.inv end end end
    for _, name in ipairs(storages) do if not tried[name] then order[#order + 1] = name end end
    for _, target in ipairs(order) do
      if left <= 0 then break end
      local ok2, n = pcall(peripheral.call, CFG.input, "pushItems", target, slot)
      if ok2 and type(n) == "number" then left = left - n; moved = moved + n end
    end
    if left > 0 then stuck = stuck + left end
  end
  return moved, stuck
end

-- ---------------------------------------------------------- drawing
local hits, flash = {}, {}
local function hit(id, x1, y1, x2, y2, fn) hits[#hits + 1] = { id = id, x1 = x1, y1 = y1, x2 = x2, y2 = y2, fn = fn } end
local function button(id, x1, y1, x2, y2, label, fg, bg, fn)
  if flash[id] and now() - flash[id] < 0.15 then fg, bg = BLACK, WHITE end
  fill(x1, y1, x2, y2, bg)
  text(x1 + math.floor((x2 - x1 + 1 - #label) / 2), math.floor((y1 + y2) / 2), label, fg, bg)
  hit(id, x1, y1, x2, y2, fn)
end

local LX1, LX2 = 2, 80               -- item list area
local RX1, RX2 = 83, 121             -- right panel
local function layout()
  RX2 = W; RX1 = W - 38
  LX2 = RX1 - 3
end
layout()

local function drawHeader()
  fill(1, 1, W, 3, PANEL)
  text(3, 2, "STORAGE", YELLOW, PANEL)
  local info = commas(stats.total) .. " items  " .. string.char(7) .. "  " .. stats.types .. " types  " ..
               string.char(7) .. "  " .. (stats.chests or 0) .. " chests"
  text(13, 2, info, LGRAY, PANEL)
  -- capacity bar
  local frac = stats.slots > 0 and stats.used / stats.slots or 0
  local bx1, bx2 = W - 52, W - 2
  local bw = bx2 - bx1 + 1
  local col = frac < 0.6 and LIME or (frac < 0.85 and YELLOW or RED)
  local label = "Slots " .. commas(stats.used) .. "/" .. commas(stats.slots) .. " (" .. math.floor(frac * 100 + 0.5) .. "%)"
  local filled = math.floor(frac * bw + 0.5)
  for i = 1, bw do setCell(bx1 + i - 1, 2, " ", WHITE, i <= filled and col or GRAY) end
  local lx = bx1 + math.floor((bw - #label) / 2)
  for i = 1, #label do
    local x = lx + i - 1
    setCell(x, 2, label:sub(i, i), (x - bx1 + 1) <= filled and BLACK or WHITE, nil)   -- readable on both parts
  end
  for x = 1, W do setCell(x, 4, "\140", YELLOW, BLACK) end
end

local function setMode(m)
  UI.mode = m; UI.page = 1; UI.selected = nil; UI.rsel = nil
  if m == "recipes" and R.state == "failed" then R.state = "loading"; queue({ kind = "loadrecipes" }) end
  rebuildList()
end
local function drawSearchBar()
  fill(LX1, 5, LX2, 5, PANEL)
  local rec = UI.mode == "recipes"
  local q = UI.search == "" and (rec and "search recipes" or "tap letters or type to search") or UI.search
  text(LX1 + 1, 5, "Search:", YELLOW, PANEL)
  local qtxt = fit(q, LX2 - LX1 - 58) .. (UI.search ~= "" and "_" or "")
  text(LX1 + 9, 5, qtxt, UI.search == "" and GRAY or WHITE, PANEL)
  if UI.didYouMean then
    local room = LX2 - 48 - (LX1 + 9 + #qtxt + 2)
    local dym = (room >= #UI.didYouMean + 17) and ("did you mean " .. UI.didYouMean .. "?") or ("-> " .. UI.didYouMean .. "?")
    if room > 6 then text(LX1 + 9 + #qtxt + 2, 5, fit(dym, room), CYAN, PANEL) end
  end
  button("mode", LX2 - 47, 5, LX2 - 36, 5, rec and "ITEMS" or "RECIPES", BLACK, rec and CYAN or PURPLE, function()
    setMode(rec and "items" or "recipes")
  end)
  if rec then
    button("canmake", LX2 - 33, 5, LX2 - 21, 5, "CAN MAKE", UI.canMake and BLACK or LGRAY, UI.canMake and LIME or GRAY, function()
      UI.canMake = not UI.canMake; UI.page = 1
      if UI.canMake and R.state == "ready" then
        if R.canSig ~= stats.total .. ":" .. stats.types then R.canSet = nil; queue({ kind = "canmake" }) end
      end
      rebuildList()
    end)
    text(LX2 - 19, 5, R.state == "ready" and fit(commas(#R.outs) .. " recipes", 20) or "loading...", GRAY, PANEL)
    return
  end
  button("organize", LX2 - 33, 5, LX2 - 21, 5, busy and "WORKING" or "ORGANIZE", BLACK, busy and YELLOW or LIME, function()
    if not busy then
      busy = "Organizing..."
      queue({ kind = "organize" })
    end
  end)
  button("sortCount", LX2 - 19, 5, LX2 - 11, 5, "COUNT", data.sort == "count" and BLACK or LGRAY,
    data.sort == "count" and CYAN or GRAY, function() data.sort = "count"; save(); rebuildList() end)
  button("sortName", LX2 - 9, 5, LX2, 5, "A-Z", data.sort == "name" and BLACK or LGRAY,
    data.sort == "name" and CYAN or GRAY, function() data.sort = "name"; save(); rebuildList() end)
end

-- open a recipe; `fromCurrent` remembers where you were so BACK can return there
local function openRecipe(o, fromCurrent, crafts)
  if fromCurrent and UI.rsel then
    UI.rhist = UI.rhist or {}
    UI.rhist[#UI.rhist + 1] = { o = UI.rsel, rvar = UI.rvar, crafts = UI.crafts, rlist = UI.rlist }
    if #UI.rhist > 20 then table.remove(UI.rhist, 1) end
  elseif not fromCurrent then UI.rhist = {} end
  UI.rsel, UI.rvar, UI.crafts, UI.rlist = o, 1, math.max(1, crafts or 1), rankRecipes(o)
end
local function goBack()
  local h = UI.rhist and table.remove(UI.rhist)
  if h then UI.rsel, UI.rvar, UI.crafts, UI.rlist = h.o, h.rvar, h.crafts, h.rlist end
end
-- which item to look up for an ingredient slot: one that has a recipe, preferring one you
-- can already make, then the item shown in the slot, then vanilla
local function ingredientTarget(g, shown)
  local best, bestScore
  for _, it in ipairs(groupItems(g)) do
    if R.byOut[it] then
      local sc = 0
      if it == shown then sc = sc + 2 end
      if (R.id[it] or ""):find("^minecraft:") then sc = sc + 1 end
      for _, rc in ipairs(R.byOut[it]) do if canCraft(rc, 1) then sc = sc + 4; break end end
      if not bestScore or sc > bestScore then best, bestScore = it, sc end
    end
  end
  return best
end
local function drillInto(g, shown, short)
  local t = ingredientTarget(g, shown)
  if not t then setStatus("No crafting-table recipe for " .. (shown and itemName(shown) or groupLabel(g)), RED); return end
  local first = rankRecipes(t)[1]
  local crafts = (short and short > 0 and first) and math.ceil(short / first.n) or 1
  openRecipe(t, true, crafts)
end

local function drawList()
  local top, bottom = 7, H - 4
  local rows = bottom - top + 1
  local colW = math.floor((LX2 - LX1 - 1) / 2)
  UI.perPage = rows * 2
  local pages = math.max(1, math.ceil(#items / UI.perPage))
  if UI.page > pages then UI.page = pages end
  local first = (UI.page - 1) * UI.perPage
  if #items == 0 then
    local msg = stats.scanned == 0 and "Scanning chests..." or "Nothing found"
    if UI.mode == "recipes" then
      msg = R.state ~= "ready" and R.msg or (UI.canMake and not R.canSet and "Checking what you can craft...") or
            (UI.canMake and "Nothing craftable matches" or "No recipe matches")
    end
    text(LX1 + 2, top + 1, msg, R.state == "failed" and UI.mode == "recipes" and RED or GRAY)
  end
  for i = 1, UI.perPage do
    local it = items[first + i]
    if not it then break end
    if it.ri then                                    -- recipe-mode row
      local col = (i <= rows) and 0 or 1
      local y = top + (i - 1) % rows
      local x = LX1 + col * (colW + 1)
      local o = it.ri
      local sel = UI.rsel == o
      local ready = R.ready[o]
      if ready == nil then
        ready = false
        for _, rc in ipairs(R.byOut[o]) do if canCraft(rc, 1) then ready = true; break end end
        R.ready[o] = ready
      end
      local bg = sel and HILITE or ((i % 2 == 0) and BLACK or PANEL)
      fill(x, y, x + colW - 1, y, bg)
      local nr = #R.byOut[o]
      local tag = ready and "READY" or (nr > 1 and (nr .. " ways") or "")
      text(x + 1, y, fit(it.name, colW - #tag - 4), sel and YELLOW or (ready and WHITE or LGRAY), bg)
      text(x + colW - #tag - 1, y, tag, ready and LIME or GRAY, bg)
      hit("rec:" .. o, x, y, x + colW - 1, y, function()
        if UI.rsel == o then UI.rsel = nil else openRecipe(o, false) end
      end)
    else
      local col = (i <= rows) and 0 or 1
      local y = top + (i - 1) % rows
      local x = LX1 + col * (colW + 1)
      local sel = UI.selected == it.id
      local limit = data.alerts[it.id]
      local low = limit and it.count < limit
      local bg = sel and HILITE or ((i % 2 == 0) and BLACK or PANEL)
      fill(x, y, x + colW - 1, y, bg)
      local cnt = commas(it.count)
      text(x + 1, y, fit(it.name, colW - #cnt - 4), sel and YELLOW or WHITE, bg)
      text(x + colW - #cnt - 1, y, cnt, low and RED or CYAN, bg)
      if low then text(x + colW - #cnt - 3, y, "!", RED, bg) end
      local id = it.id
      hit("item:" .. id, x, y, x + colW - 1, y, function() UI.selected = (UI.selected == id) and nil or id end)
    end
  end
  -- paging
  local py = H - 2
  button("prev", LX1, py, LX1 + 9, H, string.char(17) .. " PREV", YELLOW, UI.page > 1 and GRAY or PANEL,
    function() if UI.page > 1 then UI.page = UI.page - 1 end end)
  button("next", LX2 - 9, py, LX2, H, "NEXT " .. string.char(16), YELLOW, UI.page < pages and GRAY or PANEL,
    function() if UI.page < pages then UI.page = UI.page + 1 end end)
  local pg = "page " .. UI.page .. "/" .. pages .. "   " .. #items .. " shown" .. (UI.fuzzy and "  (incl. close matches)" or "")
  text(LX1 + math.floor((LX2 - LX1 - #pg) / 2), py, pg, LGRAY)
  local age = now() - status.at
  if busy then
    local b = fit(busy, LX2 - LX1 - 24)
    text(LX1 + math.floor((LX2 - LX1 - #b) / 2), H, b, YELLOW)
  elseif age < 20 then text(LX1 + math.floor((LX2 - LX1 - #status.msg) / 2), H, fit(status.msg, LX2 - LX1 - 24), status.col) end
end

local KEYS = { "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM" }
local function drawKeyboard(y0)
  text(RX1, y0, "SEARCH KEYBOARD", YELLOW)
  local y = y0 + 2
  for r, row in ipairs(KEYS) do
    local offset = (r - 1) * 2
    for i = 1, #row do
      local ch = row:sub(i, i)
      local x = RX1 + offset + (i - 1) * 4
      button("key" .. ch, x, y, x + 2, y + 2, ch, WHITE, GRAY, function() UI.search = UI.search .. ch:lower(); UI.page = 1; rebuildList(true) end)
    end
    y = y + 4
  end
  button("space", RX1, y, RX1 + 14, y + 2, "SPACE", WHITE, GRAY, function() UI.search = UI.search .. " "; rebuildList(true) end)
  button("del", RX1 + 16, y, RX1 + 26, y + 2, "DEL", WHITE, GRAY, function() UI.search = UI.search:sub(1, -2); UI.page = 1; rebuildList(true) end)
  button("clr", RX1 + 28, y, RX2, y + 2, "CLEAR", BLACK, RED, function() UI.search = ""; UI.page = 1; rebuildList() end)
  return y + 4
end

local function drawAlerts(y0)
  text(RX1, y0, "LOW STOCK", RED)
  local y = y0 + 1
  local any = false
  local list = {}
  for id, limit in pairs(data.alerts) do
    local have = index[id] and index[id].count or 0
    list[#list + 1] = { id = id, have = have, limit = limit, low = have < limit }
  end
  table.sort(list, function(a, b) if a.low ~= b.low then return a.low end return a.id < b.id end)
  for _, a in ipairs(list) do
    if y > H - 1 then break end
    local name = data.names[a.id] or prettyId(a.id)
    local right = commas(a.have) .. "/" .. commas(a.limit)
    text(RX1, y, fit(name, 38 - #right - 1), a.low and WHITE or GRAY)
    text(RX2 - #right + 1, y, right, a.low and RED or LIME)
    local id = a.id
    hit("alert:" .. id, RX1, y, RX2, y, function() UI.selected = id end)
    any = true
    y = y + 1
  end
  if not any then text(RX1, y, "none set - tap an item, then", GRAY); text(RX1, y + 1, "use ALERT +/- to add one", GRAY) end
end

local function drawDetail()
  local id = UI.selected
  local e = index[id]
  local name = data.names[id] or prettyId(id)
  fill(RX1 - 1, 5, RX2, H, PANEL)
  text(RX1, 6, fit(name, 38), YELLOW, PANEL)
  text(RX1, 7, fit(e and e.name or id, 38), GRAY, PANEL)
  if e and e.name ~= id and e.locs[1] then        -- list the enchantments under the name
    UI.enchCache = UI.enchCache or {}
    local ench = UI.enchCache[id]
    if not ench then
      local ok, d = pcall(peripheral.call, e.locs[1].inv, "getItemDetail", e.locs[1].slot)
      ench = (ok and type(d) == "table") and enchList(d) or {}
      UI.enchCache[id] = ench
    end
    if #ench > 0 then
      local line = table.concat(ench, ", ")
      text(RX1, 8, fit(line, 38), PURPLE, PANEL)
    end
  end
  local have = e and e.count or 0
  text(RX1, 9, "In storage:", LGRAY, PANEL)
  text(RX1 + 12, 9, commas(have), CYAN, PANEL)
  -- where it is
  local per = {}
  if e then for _, l in ipairs(e.locs) do per[l.inv] = (per[l.inv] or 0) + l.count end end
  local invs = {}
  for inv, n in pairs(per) do invs[#invs + 1] = { inv = inv, n = n } end
  table.sort(invs, function(a, b) return a.n > b.n end)
  text(RX1, 11, "Found in " .. #invs .. " chest" .. (#invs == 1 and "" or "s") .. ":", LGRAY, PANEL)
  for i = 1, math.min(5, #invs) do
    text(RX1 + 1, 11 + i, fit(shortInv(invs[i].inv), 26), WHITE, PANEL)
    local n = commas(invs[i].n)
    text(RX2 - #n, 11 + i, n, CYAN, PANEL)
  end
  if #invs > 5 then text(RX1 + 1, 17, "+" .. (#invs - 5) .. " more", GRAY, PANEL) end
  -- retrieve
  local _, kind = currentPickup()
  text(RX1, 19, "SEND TO PICKUP", YELLOW, PANEL)
  text(RX1 + 15, 19, kind and (string.char(16) .. " " .. kind) or "(none connected!)", kind == "BACKPACK" and CYAN or (kind and LIME or RED), PANEL)
  local amounts = { { "1", 1 }, { "16", 16 }, { "64", 64 }, { "ALL", math.huge } }
  for i, a in ipairs(amounts) do
    local x = RX1 + (i - 1) * 10
    button("get" .. a[1], x, 21, x + 8, 23, a[1], BLACK, LIME, function()
      queue({ kind = "retrieve", id = id, n = a[2] })
      setStatus("Sending " .. a[1] .. " " .. name .. "...", LIME)
    end)
  end
  -- alert threshold
  local limit = data.alerts[id] or 0
  text(RX1, 25, "LOW-STOCK ALERT BELOW:", YELLOW, PANEL)
  local lim = limit > 0 and commas(limit) or "off"
  text(RX1 + 23, 25, lim, limit > 0 and (have < limit and RED or LIME) or GRAY, PANEL)
  local steps = { { "-64", -64 }, { "-8", -8 }, { "+8", 8 }, { "+64", 64 } }
  for i, s in ipairs(steps) do
    local x = RX1 + (i - 1) * 10
    button("al" .. s[1], x, 27, x + 8, 29, s[1], WHITE, GRAY, function()
      local v = math.max(0, (data.alerts[id] or 0) + s[2])
      data.alerts[id] = v > 0 and v or nil
      save()
    end)
  end
  local ri = R.byId[e and e.name or id]
  if R.state == "ready" and ri and R.byOut[ri] then
    button("showrec", RX1, 31, RX2, 33, "SHOW RECIPE", BLACK, PURPLE, function()
      UI.mode = "recipes"; UI.selected = nil; UI.rhist = {}; UI.rsel = ri; UI.rvar = 1; UI.crafts = 1; UI.rlist = rankRecipes(ri)
      rebuildList()
    end)
  end
  button("close", RX1, H - 3, RX2, H - 1, "CLOSE", WHITE, RED, function() UI.selected = nil end)
end

-- recipe view: 3x3 grid, what you have / are missing, how many to craft, send to pickup
local function drawRecipe()
  local o = UI.rsel
  local list = UI.rlist or rankRecipes(o)
  if UI.rvar > #list then UI.rvar = 1 end
  local rc = list[UI.rvar]
  fill(RX1 - 1, 5, RX2, H, PANEL)
  local hasBack = UI.rhist and #UI.rhist > 0
  text(RX1, 6, fit(R.name[o], hasBack and 30 or 38), YELLOW, PANEL)
  if hasBack then
    button("rback", RX2 - 7, 6, RX2, 6, string.char(17) .. " BACK", BLACK, YELLOW, goBack)
  end
  text(RX1, 7, "makes " .. rc.n .. (rc.k == "l" and "  (shapeless)" or ""), LGRAY, PANEL)
  if #list > 1 then
    local lbl = UI.rvar .. "/" .. #list
    text(RX2 - 9 - #lbl, 7, lbl, LGRAY, PANEL)
    button("rprev", RX2 - 7, 7, RX2 - 5, 7, string.char(17), YELLOW, GRAY, function() UI.rvar = (UI.rvar - 2) % #list + 1; UI.crafts = 1 end)
    button("rnext", RX2 - 2, 7, RX2, 7, string.char(16), YELLOW, GRAY, function() UI.rvar = UI.rvar % #list + 1; UI.crafts = 1 end)
  end
  local plan = craftPlan(rc, UI.crafts)
  local one = craftPlan(rc, 1)
  -- grid: 7x4-character cells look (nearly) square on a monitor (characters are taller than wide)
  local CW, CH = 7, 4
  local function wrap(label, w, maxl)
    local lines, cur = {}, ""
    local words = {}
    for word in label:gmatch("%S+") do words[#words + 1] = word end
    for wi, word in ipairs(words) do
      if #word > w and #words > 1 then word = word:sub(1, w - 1) .. "." end   -- "Redstone" -> "Redsto."
      while #word > w do                           -- a single long word gets split over lines
        if cur ~= "" then lines[#lines + 1] = cur; cur = "" end
        lines[#lines + 1] = word:sub(1, w); word = word:sub(w + 1)
      end
      if cur == "" then cur = word elseif #cur + 1 + #word <= w then cur = cur .. " " .. word
      else lines[#lines + 1] = cur; cur = word end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    if #lines > maxl then lines[maxl] = fit(lines[maxl] .. lines[maxl + 1], w); for k = #lines, maxl + 1, -1 do lines[k] = nil end end
    return lines
  end
  local function cellText(cx, cy, label, fg, bg)
    local lines = wrap(label, CW, CH)
    local top = cy + math.floor((CH - #lines) / 2)
    for k, l in ipairs(lines) do text(cx + math.floor((CW - #l) / 2), top + k - 1, l, fg, bg) end
  end
  local gx, gy = RX1, 9
  fill(gx - 1, gy - 1, gx + 3 * CW + 2, gy + 3 * CH + 2, BLACK)   -- crafting table frame
  local slots = recipeSlots(rc)                    -- shapeless recipes are laid out in order
  for cell = 1, 9 do
    local g = slots[cell] or 0
    local cx = gx + ((cell - 1) % 3) * (CW + 1)
    local cy = gy + math.floor((cell - 1) / 3) * (CH + 1)
    if g == 0 then
      fill(cx, cy, cx + CW - 1, cy + CH - 1, HILITE)
    else
      local miss = plan.missing[g]
      local bg = miss and (slotCraftable(g, miss, o) and GREEN or RED) or GRAY
      fill(cx, cy, cx + CW - 1, cy + CH - 1, bg)
      local label = one.pick[g] and itemName(one.pick[g]) or groupLabel(g)
      label = label:gsub("^#c:", "#"):gsub("^#minecraft:", "#"):gsub("[/_]", " ")
      cellText(cx, cy, label, WHITE, bg)
      local shown, short = one.pick[g], plan.missing[g]
      hit("cell" .. cell, cx, cy, cx + CW - 1, cy + CH - 1, function() drillInto(g, shown, short) end)
    end
  end
  -- arrow + result slot
  local midY = gy + CH + 1 + math.floor(CH / 2)
  text(gx + 3 * CW + 4, midY - 1, "\140\140" .. string.char(16), YELLOW, PANEL)
  local ox, oy = gx + 3 * CW + 8, gy + CH + 1
  fill(ox - 1, oy - 1, ox + CW, oy + CH, BLACK)
  fill(ox, oy, ox + CW - 1, oy + CH - 1, PURPLE)
  cellText(ox, oy, (R.name[o]:gsub(" %(.*%)$", "")), WHITE, PURPLE)
  local mk = "x" .. commas(rc.n)
  text(ox + math.floor((CW - #mk) / 2), oy + CH + 1, mk, YELLOW, PANEL)
  if plan.short > 0 then                           -- hint under the result slot
    local hx = gx + 3 * CW + 4
    text(hx, gy + 3 * CH - 2, "tap a slot", GRAY, PANEL)
    text(hx, gy + 3 * CH - 1, "to see its", GRAY, PANEL)
    text(hx, gy + 3 * CH, "recipe", GRAY, PANEL)
  end
  -- ingredient totals
  local y = 24
  text(RX1, y, "NEED FOR " .. UI.crafts .. " CRAFT" .. (UI.crafts == 1 and "" or "S") .. " (" .. commas(rc.n * UI.crafts) .. " made)", YELLOW, PANEL)
  y = y + 1
  for k, g in ipairs(plan.order) do
    if y == 28 and #plan.order > k then
      text(RX1, y, "+" .. (#plan.order - k + 1) .. " more ingredients", GRAY, PANEL); break
    end
    local need = plan.need[g]
    local short = plan.missing[g] or 0
    local nm = plan.pick[g] and itemName(plan.pick[g]) or groupLabel(g)
    local canMake = short > 0 and slotCraftable(g, short, o)
    local right = (canMake and "craft " .. commas(short) .. "  " or "") .. commas(need - short) .. "/" .. commas(need)
    text(RX1, y, fit(nm, 38 - #right - 1), short > 0 and WHITE or LGRAY, PANEL)
    local pk = plan.pick[g]
    hit("ing" .. k, RX1, y, RX2, y, function() drillInto(g, pk, short) end)
    text(RX2 - #right + 1, y, right, short > 0 and (canMake and GREEN or RED) or LIME, PANEL)
    y = y + 1
  end
  -- how many
  local mx = maxCrafts(rc)
  text(RX1, 29, "CRAFTS: " .. UI.crafts, WHITE, PANEL)
  local chainOk = plan.short == 0 or chainPlan(rc, UI.crafts, o) ~= nil
  if mx == 0 and chainOk then text(RX1 + 14, 29, "(after crafting parts)", GREEN, PANEL)
  else text(RX1 + 14, 29, "(can make " .. commas(mx) .. ")", mx > 0 and LIME or RED, PANEL) end
  local steps = { { "-1", -1 }, { "+1", 1 }, { "+8", 8 }, { "MAX", 0 } }
  for i, st in ipairs(steps) do
    local x = RX1 + (i - 1) * 10
    button("cr" .. st[1], x, 30, x + 8, 32, st[1], WHITE, GRAY, function()
      if st[2] == 0 then UI.crafts = math.max(1, mx) else UI.crafts = math.max(1, math.min(4096, UI.crafts + st[2])) end
    end)
  end
  local short = plan.short
  if short == 0 and not fitsPickup(plan) then text(RX1, 33, "too much for the pickup - lower CRAFTS", ORANGE, PANEL) end
  local label = short == 0 and "SEND ITEMS" or (#plan.take > 0 and "SEND SOME" or "MISSING")
  local col = short == 0 and LIME or (#plan.take > 0 and YELLOW or GRAY)
  local canAuto = chainOk and not busy
  if short > 0 and chainOk then text(RX1, 33, "CRAFT will make the green parts first", GREEN, PANEL) end
  button("autocraft", RX1, H - 3, RX1 + 11, H - 1, "CRAFT", BLACK, canAuto and (short > 0 and GREEN or CYAN) or GRAY, function()
    if busy then return end
    if not chainOk then setStatus("Missing ingredients you can't craft yet - tap the red slots to see why", RED); return end
    queue({ kind = "autocraft", rc = rc, out = o, crafts = UI.crafts, name = itemName(o) })
    setStatus("Crafting " .. UI.crafts .. "x " .. itemName(o) .. "...", CYAN)
  end)
  button("craftsend", RX1 + 13, H - 3, RX2 - 13, H - 1, label, BLACK, col, function()
    if #plan.take == 0 then setStatus("You don't have any of the ingredients", RED); return end
    queue({ kind = "craft", list = plan.take, missing = short, crafts = UI.crafts, name = itemName(o) })
    setStatus("Sending ingredients for " .. UI.crafts .. "x " .. itemName(o) .. "...", LIME)
  end)
  button("rclose", RX2 - 11, H - 3, RX2, H - 1, "CLOSE", WHITE, RED, function() UI.rsel = nil end)
end

local function draw()
  clear(); hits = {}
  layout()
  drawHeader()
  drawSearchBar()
  drawList()
  for y = 5, H do setCell(RX1 - 2, y, "\149", YELLOW, BLACK) end
  if UI.mode == "recipes" and UI.rsel then drawRecipe()
  elseif UI.mode == "items" and UI.selected then drawDetail()
  else
    local y = drawKeyboard(6)
    drawAlerts(y + 1)
  end
  present()
end

-- ---------------------------------------------------------- loops
local function worker()
  local lastScan, lastSort = -100, -100
  while true do
    if #tasks > 0 then
      local t = table.remove(tasks, 1)
      if t.kind == "organize" then
        setStatus("Organizing storage...", YELLOW)
        local moves, freed = organize()
        setStatus("Organized! " .. commas(moves) .. " moves, freed " .. commas(math.max(0, freed)) .. " slots", LIME)
        if speaker then pcall(speaker.playNote, "chime", 1, 12) end
      elseif t.kind == "autocraft" then
        local made, err, parts = chainCraft(t)
        busy = nil
        if err then
          setStatus((made > 0 and ("Made " .. commas(made) .. " " .. t.name .. ", then stopped: ") or "Couldn't craft: ") .. err, made > 0 and YELLOW or RED)
        else
          setStatus("Crafted " .. commas(made) .. " " .. t.name .. (parts and parts > 0 and (" (made " .. parts .. " part" .. (parts == 1 and "" or "s") .. " first)") or "") .. " - it's in the pickup", LIME)
          if speaker then pcall(speaker.playNote, "chime", 1, 16) end
        end
        scan()
      elseif t.kind == "craft" then
        local sent, short, why = 0, 0, nil
        for _, x in ipairs(t.list) do
          local n, w = retrieve(R.id[x.it], x.n)
          sent = sent + n
          if n < x.n then short = short + (x.n - n); why = why or w or "pickup full" end
        end
        if sent > 0 and short == 0 and t.missing == 0 then
          setStatus("Sent ingredients for " .. t.crafts .. "x " .. t.name, LIME)
          if speaker then pcall(speaker.playNote, "pling", 0.8, 12) end
        elseif sent > 0 and short > 0 then
          setStatus("Sent " .. commas(sent) .. " items, " .. commas(short) .. " didn't fit (" .. why .. ")", YELLOW)
        elseif sent > 0 then
          setStatus("Sent what you have - still missing " .. commas(t.missing) .. " for " .. t.name, YELLOW)
        else
          setStatus("Couldn't send ingredients for " .. t.name, RED)
        end
        scan()
      elseif t.kind == "findcrafter" then
        local id = findCrafter(true)
        setStatus(id and ("Found the crafter turtle (#" .. id .. ")") or "No crafter turtle on the network", id and LIME or RED)
      elseif t.kind == "loadrecipes" then
        loadRecipes(); rebuildList()
      elseif t.kind == "canmake" then
        busy = "Checking what you can craft..."
        local set, n = {}, 0
        for j, o in ipairs(R.outs) do
          if j % 300 == 0 then os.queueEvent("recipe_yield"); os.pullEvent("recipe_yield") end
          for _, rc in ipairs(R.byOut[o]) do
            if canCraft(rc, 1) then set[o] = true; n = n + 1; break end
          end
        end
        R.canSet, R.canSig = set, stats.total .. ":" .. stats.types
        busy = nil
        rebuildList()
        setStatus("You can craft " .. commas(n) .. " things right now", LIME)
      elseif t.kind == "retrieve" then
        local n, why = retrieve(t.id, t.n)
        local name = data.names[t.id] or prettyId(t.id)
        local _, kind = currentPickup()
        local where = kind == "BACKPACK" and "backpack" or "barrel"
        if n > 0 then
          setStatus("Sent " .. commas(n) .. " " .. name .. " to the " .. where, LIME)
          if speaker then pcall(speaker.playNote, "pling", 0.8, 12) end
        else
          setStatus("Couldn't send " .. name .. " (" .. (why or (where .. " full or none left")) .. ")", RED)
        end
        scan()
      end
    elseif now() - lastSort >= CFG.sortEvery then
      lastSort = now()
      local moved, stuck = sortInput()
      if moved > 0 then
        setStatus("Sorted " .. commas(moved) .. " items from the input chest", LIME)
        scan(); lastScan = now()
      end
      if stuck > 0 then setStatus(commas(stuck) .. " items couldn't fit - storage is full!", RED) end
    elseif now() - lastScan >= CFG.scanEvery then
      lastScan = now()
      scan()
      if UI.mode == "recipes" and UI.canMake and R.state == "ready" and R.canSig ~= stats.total .. ":" .. stats.types then
        queue({ kind = "canmake" })
      end
      if stats.scanned and status.msg == "Scanning storage..." then
        setStatus("Found " .. (stats.chests or 0) .. " storage chests", LIME)
      end
    else
      if resolveNames(4) == 0 then
        local id = os.startTimer(0.5)
        repeat local _, p = os.pullEvent() until p == id or _ == "storage_task"
      end
    end
  end
end

local function ui()
  local timer = os.startTimer(0)
  while true do
    local ev, a, b, c = os.pullEventRaw()
    if ev == "terminate" then return
    elseif ev == "timer" and a == timer then
      if UI.fuzzyAt and now() >= UI.fuzzyAt then rebuildList() end   -- typo search once you stop typing
      draw(); timer = os.startTimer(0.25)
    elseif ev == "monitor_touch" and monNames[a] then
      for i = #hits, 1, -1 do
        local h = hits[i]
        if b >= h.x1 and b <= h.x2 and c >= h.y1 and c <= h.y2 then flash[h.id] = now(); h.fn(b, c); break end
      end
      draw()
    elseif ev == "char" then
      UI.search = UI.search .. a; UI.page = 1; rebuildList(true); draw()
    elseif ev == "key" then
      if a == keys.backspace then UI.search = UI.search:sub(1, -2); UI.page = 1; rebuildList(true); draw()
      elseif a == keys.enter then UI.search = ""; rebuildList(); draw() end
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      os.queueEvent("storage_task")
    end
  end
end

term.clear(); term.setCursorPos(1, 1)
term.setTextColour(colors.yellow); print("STORAGE MANAGER")
term.setTextColour(colors.white)
print("Input chest:  " .. CFG.input .. (peripheral.isPresent(CFG.input) and "" or "  (NOT FOUND)"))
local pk, pkind = currentPickup()
print("Pickup:       " .. (pk and (pk .. " (" .. pkind:lower() .. ")") or "NOT FOUND - place a barrel or backpack"))
term.setTextColour(colors.lightGray)
print("Type to search, Backspace to delete,")
print("Enter to clear. Hold Ctrl+T to stop.")
if _G.__JB_TEST then
  _G.__JB = { hits = function() return hits end, UI = UI, index = function() return index end,
    items = function() return items end, stats = function() return stats end, data = data, status = status,
    busy = function() return busy end, R = R, rebuild = function() rebuildList() end, chainPlan = chainPlan, BASEchild = function() return nil end, rankRecipes = rankRecipes, craftPlan = craftPlan }
end

parallel.waitForAny(ui, worker, function()
  loadRecipes(); rebuildList()
  findCrafter(true)
  while true do os.pullEvent("never") end
end)
for _, m in ipairs(mons) do
  for i = 0, 15 do m.p.setPaletteColour(2 ^ i, term.nativePaletteColour(2 ^ i)) end
  m.p.setBackgroundColour(colors.black); m.p.clear()
end
term.clear(); term.setCursorPos(1, 1); print("Storage manager stopped.")
