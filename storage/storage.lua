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
local data = { alerts = {}, names = {}, sort = "count", remotes = {}, smeltRule = {}, dbl = {}, woodOf = {},
  smeltStop = false, smeltHeld = {} }
if fs.exists(SAVE) then
  local f = fs.open(SAVE, "r")
  local ok, d = pcall(textutils.unserialize, f.readAll())
  f.close()
  if ok and type(d) == "table" then
    data.alerts = type(d.alerts) == "table" and d.alerts or {}
    data.remotes = type(d.remotes) == "table" and d.remotes or {}
    data.names = type(d.names) == "table" and d.names or {}
    data.sort = d.sort == "name" and "name" or "count"
    data.smeltRule = type(d.smeltRule) == "table" and d.smeltRule or {}
    data.dbl = type(d.dbl) == "table" and d.dbl or {}
    data.woodOf = type(d.woodOf) == "table" and d.woodOf or {}
    for k, v in pairs(data.woodOf) do if v == false then data.woodOf[k] = nil end end   -- unfinished lookups: try again
    data.smeltStop = d.smeltStop == true
    data.smeltHeld = type(d.smeltHeld) == "table" and d.smeltHeld or {}
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
-- crafting / smelting results also go on this computer's own screen and into craft_log.txt (last 40),
-- so a message that flashed past on the monitor can still be read afterwards
local function logResult(msg)
  if not (msg:find("^Crafted") or msg:find("^Made ") or msg:find("^Couldn't") or msg:find("^Smelted")) then return end
  local line = "[day " .. os.day() .. " " .. textutils.formatTime(os.time(), false) .. "] " .. msg
  local old = {}
  if fs.exists("craft_log.txt") then
    local f = fs.open("craft_log.txt", "r"); local all = f.readAll() or ""; f.close()
    for l in all:gmatch("[^\n]+") do old[#old + 1] = l end
  end
  old[#old + 1] = line
  while #old > 40 do table.remove(old, 1) end
  local f = fs.open("craft_log.txt", "w"); f.write(table.concat(old, "\n") .. "\n"); f.close()
  if term.isColour() then term.setTextColour(msg:find("^Couldn't") and colors.red or (msg:find("^Made ") and colors.yellow or colors.lime)) end
  print(line)
  term.setTextColour(colors.white)
end
local function setStatus(msg, col) status.msg, status.col, status.at = msg, col or LGRAY, now(); pcall(logResult, msg) end

-- ---------------------------------------------------------- history: a snapshot every 10 min + items put away per day
local HIST
do
  local FILE, KEEP, EVERY = "storage_history.txt", 1008, 600     -- one week of 10-minute snapshots
  HIST = { samples = {}, day = "", today = 0, yesterday = 0, last = 0, dirty = false }
  if fs.exists(FILE) then
    local f = fs.open(FILE, "r"); local ok, d = pcall(textutils.unserialize, f.readAll()); f.close()
    if ok and type(d) == "table" then
      HIST.samples = type(d.samples) == "table" and d.samples or {}
      HIST.day, HIST.today, HIST.yesterday = tostring(d.day or ""), tonumber(d.today) or 0, tonumber(d.yesterday) or 0
      local n = #HIST.samples
      HIST.last = n > 0 and HIST.samples[n].t or 0
    end
  end
  -- today's date in Mountain Time (US daylight-saving rules)
  local function civil(z)
    z = z + 719468
    local era = math.floor(z / 146097); local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
  end
  local function sundayOnOrAfter(y, m, d)                 -- day number of the first Sunday on/after y-m-d
    local yy = m <= 2 and y - 1 or y
    local era = math.floor(yy / 400); local yoe = yy - era * 400
    local mp = m > 2 and m - 3 or m + 9
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local days = era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
    return days + (7 - (days + 4) % 7) % 7
  end
  function HIST.date()
    local utc = math.floor(os.epoch("utc") / 1000)
    local y = civil(math.floor(utc / 86400))
    local dst = utc >= sundayOnOrAfter(y, 3, 8) * 86400 + 9 * 3600 and utc < sundayOnOrAfter(y, 11, 1) * 86400 + 8 * 3600
    local yy, mm, dd = civil(math.floor((utc + (dst and -6 or -7) * 3600) / 86400))
    return string.format("%04d-%02d-%02d", yy, mm, dd)
  end
  local function roll()
    local d = HIST.date()
    if d ~= HIST.day then
      HIST.yesterday = (HIST.day ~= "") and HIST.today or 0
      HIST.day, HIST.today, HIST.dirty = d, 0, true
    end
  end
  function HIST.add(n)                                     -- items put into storage
    if (n or 0) <= 0 then return end
    roll(); HIST.today = HIST.today + n; HIST.dirty = true
  end
  function HIST.tick(st)                                   -- called every few seconds
    roll()
    local t = math.floor(os.epoch("utc") / 1000)
    if st.scanned and st.scanned > 0 and t - HIST.last >= EVERY then
      HIST.last = t
      HIST.samples[#HIST.samples + 1] = { t = t, n = st.total, u = st.used }
      while #HIST.samples > KEEP do table.remove(HIST.samples, 1) end
      HIST.dirty = true
    end
    if HIST.dirty then
      HIST.dirty = false
      local f = fs.open(FILE, "w")
      f.write(textutils.serialize({ samples = HIST.samples, day = HIST.day, today = HIST.today, yesterday = HIST.yesterday }))
      f.close()
    end
  end
  function HIST.graph()                                    -- item totals, one per hour, last 24 hours (oldest first)
    local out, n = {}, #HIST.samples
    local cutoff = math.floor(os.epoch("utc") / 1000) - 24 * 3600
    local i = n
    while i >= 1 and #out < 24 and HIST.samples[i].t >= cutoff do
      table.insert(out, 1, HIST.samples[i].n); i = i - 6
    end
    return out
  end
end

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
  if name:find("furnace") or name:find("smoker") then return false end     -- furnaces belong to the smelter
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
  local cook = {}
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
    elseif kind == "S" then
      local out, n, k, g = line:match("^S\t(%d+)\t(%d+)\t(%a)\t(%d+)$")
      if out then cook[#cook + 1] = { out = tonumber(out), n = tonumber(n), k = k, g = tonumber(g) } end
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
  R.cook, R.cookSig = cook, os.epoch("utc")
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

-- ---------------------------------------------------------- smelter: furnaces + blast furnaces on the network
-- Items that can be smelted wait in the input chest until you choose on the screen (or have an
-- ALWAYS / NEVER rule). Smelting jobs pull from storage into the furnaces, keep them fuelled and
-- put the results back. Crafting chains use it too (e.g. sand -> glass -> glass panes).
local SM
do
  SM = { furnaces = {}, jobs = {}, asks = {}, once = {}, built = nil, noFuel = false }
  local FUELS = { "minecraft:charcoal", "minecraft:coal" }        -- the only fuels the smelter will use
  -- ticks per item (a vanilla furnace is 200 = 10 s). Iron Furnaces tiers use the mod's default speeds.
  local TICKS = { iron = 160, gold = 120, diamond = 80, emerald = 40, obsidian = 20, crystal = 40, netherite = 5,
    copper = 180, silver = 140, rainbow = 20, allthemodium = 5, vibranium = 3, unobtainium = 1 }
  function SM.find()
    local list, nb = {}, 0
    for _, n in ipairs(peripheral.getNames()) do
      local tier = n:match("^ironfurnaces:([%a]+)_furnace")
      if n:find("^minecraft:blast_furnace") then list[#list + 1] = { name = n, blast = true, ips = 20 / 100 }
      elseif n:find("^minecraft:furnace") then list[#list + 1] = { name = n, blast = false, ips = 20 / 200 }
      elseif tier and TICKS[tier] then
        -- an Iron Furnace: a Blasting augment makes it a blast furnace, a Smoking augment means food only (skipped)
        local ok, aug = pcall(peripheral.call, n, "getItemDetail", 4)
        local a = ok and type(aug) == "table" and aug.name or ""
        if not a:find("smoking") then
          list[#list + 1] = { name = n, blast = a:find("blasting") ~= nil, ips = 20 / TICKS[tier], tier = tier }
        end
      end
    end
    for _, f in ipairs(list) do if f.blast then nb = nb + 1 end end
    table.sort(list, function(a, b) return a.name < b.name end)
    for _, f in ipairs(list) do for _, old in ipairs(SM.furnaces) do if old.name == f.name then f.cur = old.cur end end end
    SM.furnaces, SM.nBlast, SM.nFurn = list, nb, #list - nb
  end
  function SM.active() return #SM.furnaces > 0 and R.state == "ready" end
  -- lookups built from the recipe book: what each item smelts into, and how to make an item by smelting
  local function build()
    if SM.built == R.cookSig then return end
    SM.out, SM.inp = {}, {}
    local merged = {}
    for _, c in ipairs(R.cook or {}) do
      local key = c.out .. ":" .. c.g
      local rc = merged[key]
      if not rc then
        rc = { smelt = true, n = c.n, g = tostring(c.g), k = "c", out = c.out }
        merged[key] = rc
        SM.out[c.out] = SM.out[c.out] or {}
        table.insert(SM.out[c.out], rc)
      end
      if c.k == "b" then rc.b = true else rc.f = true end
    end
    for _, l in pairs(SM.out) do
      for _, rc in ipairs(l) do
        for _, it in ipairs(groupItems(tonumber(rc.g))) do
          local id = R.id[it]
          if id and not SM.inp[id] then SM.inp[id] = rc end
        end
      end
    end
    SM.built = R.cookSig
  end
  function SM.recs(it) if not SM.active() then return nil end build(); return SM.out[it] end
  function SM.info(id) if R.state ~= "ready" then return nil end build(); return SM.inp[id] end
  local function nameOf(id) return data.names[id] or (R.byId[id] and R.name[R.byId[id]]) or prettyId(id) end
  SM.nameOf = nameOf
  -- "double" versions (id@double) are the same item id with a hidden marker: the turtle crafts the real id
  function SM.realId(id) return ((id or ""):gsub("@[%w_]+$", "")) end
  -- Sophisticated chests/barrels: same item id for every wood type. The wood is read once from the item's
  -- name ("Spruce Iron Chest") and remembered, so each wood gets its own count (id@spruce) for crafting.
  local WOOD_NAMES = { { "Dark Oak", "dark_oak" }, { "Oak", "oak" }, { "Spruce", "spruce" }, { "Birch", "birch" },
    { "Jungle", "jungle" }, { "Acacia", "acacia" }, { "Mangrove", "mangrove" }, { "Cherry", "cherry" },
    { "Bamboo", "bamboo" }, { "Crimson", "crimson" }, { "Warped", "warped" } }
  local function isWoodItem(n)
    return n:find("^sophisticatedstorage:") and (n:find("chest$") or n:find("barrel$") or n:find("barrel_%d$")) and not n:find("shulker")
  end
  local function woodCacheKey(it) return it.name .. "#" .. (it.nbt or "") end
  -- which group an item counts under: a learned double, its wood version, or just its id
  function SM.groupKey(it)
    if it.nbt and data.dbl[it.name .. "#" .. it.nbt] then return data.dbl[it.name .. "#" .. it.nbt] end
    local w = isWoodItem(it.name) and data.woodOf[woodCacheKey(it)]
    if w and w ~= "" then return it.name .. "@" .. w end
    return it.name
  end
  -- look up the wood of any chest/barrel we haven't seen before (one detail call each, then cached)
  function SM.learnWoods(lists, invs)
    local jobs = {}
    for i, name in ipairs(invs) do
      for slot, it in pairs(lists[i] or {}) do
        local key = woodCacheKey(it)
        if isWoodItem(it.name) and data.woodOf[key] == nil then
          data.woodOf[key] = false                                   -- (being looked up)
          jobs[#jobs + 1] = function()
            local ok, d = pcall(peripheral.call, name, "getItemDetail", slot)
            local w = ""
            if ok and type(d) == "table" and type(d.displayName) == "string" then
              for _, wn in ipairs(WOOD_NAMES) do
                if d.displayName:sub(1, #wn[1] + 1) == wn[1] .. " " then w = wn[2]; break end
              end
              if it.nbt then data.names[it.name .. "#" .. it.nbt] = d.displayName end
            end
            data.woodOf[key] = w
            dirty = true
          end
        end
      end
    end
    for i = 1, #jobs, 16 do
      local batch = {}
      for k = i, math.min(#jobs, i + 15) do batch[#batch + 1] = jobs[k] end
      parallel.waitForAll(table.unpack(batch))
    end
  end
  -- detail-page button: tell the storage this Sophisticated chest is a double (CC can't see the marker itself)
  function SM.doubleButton(key, x1, y, x2)
    local real = key:match("^(sophisticatedstorage:[%w_]*chest)#.+$")
    if not real then return end
    local marked = data.dbl[key] ~= nil
    button("mkdbl", x1, y, x2, y, marked and "IT'S A DOUBLE  (tap to undo)" or "MARK AS DOUBLE CHEST", BLACK, marked and ORANGE or CYAN, function()
      if marked then data.dbl[key] = nil; data.names[key] = nil
      else
        local pi = R.byId[real .. "@double"]
        data.dbl[key] = real .. "@double"
        data.names[key] = (pi and R.name[pi]) or ("Double " .. ((R.byId[real] and R.name[R.byId[real]]) or prettyId(real)))
      end
      dirty = true
      if SM.rescan then SM.rescan() end
    end)
  end
  -- after crafting a double, remember its marker so the storage files it as the double from now on
  function SM.learnDouble(pseudo, pk)
    if not (pseudo and pseudo:find("@double$") and pk) then return end
    local real = SM.realId(pseudo)
    local ok, l = pcall(peripheral.call, pk, "list")
    if not ok or type(l) ~= "table" then return end
    for _, it in pairs(l) do
      if it.name == real and it.nbt then
        local key = real .. "#" .. it.nbt
        if data.dbl[key] ~= pseudo then
          data.dbl[key] = pseudo
          data.names[key] = (R.byId[pseudo] and R.name[R.byId[pseudo]]) or ("Double " .. nameOf(real))
          dirty = true
        end
      end
    end
  end

  -- what to do with an item that just landed in the input chest: "store", "smelt" or "ask"
  function SM.decide(id, count)
    if not SM.active() then return "store" end
    local rc = SM.info(id)
    if not rc then return "store" end
    local rule = data.smeltRule[id]
    if rule == "always" then return "smelt" elseif rule == "never" then return "store" end
    if SM.once[id] then return SM.once[id] end
    SM.asks[id] = (SM.asks[id] or 0) + count
    return "ask"
  end
  local function hold(id, n)
    if n <= 0 then return end
    for _, h in ipairs(data.smeltHeld) do if h.id == id then h.n = h.n + n; dirty = true; return end end
    data.smeltHeld[#data.smeltHeld + 1] = { id = id, n = n }
    dirty = true
  end
  function SM.heldCount() local n = 0; for _, h in ipairs(data.smeltHeld) do n = n + h.n end return n end
  function SM.add(id, n, rc)
    rc = rc or SM.info(id)
    if not rc or n <= 0 then return nil end
    if data.smeltStop then hold(id, n); return nil end
    local j = { id = id, left = n, total = n, outId = R.id[rc.out], b = rc.b, f = rc.f }
    setStatus("Smelting " .. commas(n) .. " " .. nameOf(id) .. "...", ORANGE)
    SM.jobs[#SM.jobs + 1] = j
    os.queueEvent("smelt_tick")
    return j
  end

  -- move a furnace slot into storage (chests that already hold the item first)
  local function storeFrom(src, slot, itemId, count)
    local order, tried = {}, {}
    local e = byName[itemId]
    if e then for _, loc in ipairs(e.locs) do if not tried[loc.inv] then tried[loc.inv] = true; order[#order + 1] = loc.inv end end end
    for _, nm in ipairs(storages) do if not tried[nm] then order[#order + 1] = nm end end
    local left = count
    for _, target in ipairs(order) do
      if left <= 0 then break end
      local ok, n = pcall(peripheral.call, src, "pushItems", target, slot)
      if ok and type(n) == "number" then left = left - n end
    end
    return count - left
  end
  -- move up to `want` of an item from storage into a furnace slot
  local function pullInto(furnace, slot, itemId, want)
    local e = byName[itemId]
    if not e then return 0 end
    local got = 0
    for _, loc in ipairs(e.locs) do
      if got >= want then break end
      if loc.count > 0 then
        local ok, n = pcall(peripheral.call, loc.inv, "pushItems", furnace, loc.slot, math.min(want - got, loc.count), slot)
        if ok and type(n) == "number" and n > 0 then got = got + n; loc.count = loc.count - n; e.count = e.count - n end
      end
    end
    return got
  end
  local function pickFuel(avoid)
    for _, id in ipairs(FUELS) do
      local e = byName[id]
      if e and e.count > 0 and id ~= avoid then return id end
    end
  end
  local function fits(f, j) return (f.blast and j.b) or ((not f.blast) and j.f) end
  function SM.tick()
    if #SM.furnaces == 0 then return end
    SM.noFuel = false
    for _, f in ipairs(SM.furnaces) do
      local ok, l = pcall(peripheral.call, f.name, "list")
      if ok and type(l) == "table" then
        if l[3] and storeFrom(f.name, 3, l[3].name, l[3].count) > 0 then SM.progressAt = now() end   -- finished items back to storage
        if data.smeltStop then
          -- stopped: anything still sitting in an input slot goes back to storage and is held
          if l[1] then hold(l[1].name, storeFrom(f.name, 1, l[1].name, l[1].count)) end
          f.cur, f.n = nil, 0
        else
          SM.fill(f, l)
        end
      end
    end
    SM.finish()
  end
  -- normal running: top up one furnace's input and fuel
  function SM.fill(f, l)
        local inp = l[1]
        f.cur, f.n = inp and inp.name or nil, inp and inp.count or 0
        local job
        for _, j in ipairs(SM.jobs) do
          if j.left > 0 and ((inp and j.id == inp.name) or (not inp and fits(f, j))) then job = j; break end
        end
        if not job and not inp and not f.blast then                       -- a regular furnace can help with blast-only? no: only what it can do
          job = nil
        end
        if job then
          local room = 64 - (inp and inp.count or 0)
          local capR = 0
          for _, f2 in ipairs(SM.furnaces) do if fits(f2, job) then capR = capR + (f2.ips or 0.1) end end
          -- split the batch over the furnaces; faster ones get a bigger share
          local share = math.max(1, math.ceil(job.total * (f.ips or 0.1) / math.max(0.001, capR)))
          local want = math.min(room, job.left, math.max(0, share - (inp and inp.count or 0)))
          local n = want > 0 and pullInto(f.name, 1, job.id, want) or 0
          job.left = job.left - n
          if n > 0 then f.cur = job.id; f.n = (f.n or 0) + n
          elseif not inp and (not byName[job.id] or byName[job.id].count <= 0) then job.left, job.short = 0, true end
        end
        if f.cur then                                                     -- keep it fuelled while it has work
          local fu = l[2]
          if not fu or fu.count < 8 then
            local fid
            if not fu then fid = pickFuel(f.cur)
            elseif fu.name == "minecraft:coal" or fu.name == "minecraft:charcoal" then fid = fu.name end   -- anything else there is left alone
            if fid then pullInto(f.name, 2, fid, 16 - (fu and fu.count or 0)) elseif not fu then SM.noFuel = true end
          end
        end
  end
  -- EMERGENCY STOP / RESTORE (done by the smelter loop so it never clashes with a tick)
  function SM.request(what) SM.req = what; os.queueEvent("smelt_tick") end
  function SM.doRequest()
    local what = SM.req
    SM.req = nil
    if what == "stop" and not data.smeltStop then
      data.smeltStop = true
      for _, j in ipairs(SM.jobs) do hold(j.id, math.max(0, j.left)) end
      SM.jobs = {}
      SM.tick()                                            -- empties every furnace into storage
      dirty = true
      setStatus("Smelter STOPPED - " .. commas(SM.heldCount()) .. " items held. Tap RESTORE to carry on.", RED)
    elseif what == "resume" and data.smeltStop then
      data.smeltStop = false
      if SM.rescan then SM.rescan() end                    -- the held items are back in storage now
      local held = data.smeltHeld
      data.smeltHeld = {}
      for _, h in ipairs(held) do SM.add(h.id, h.n) end
      dirty = true
      setStatus("Smelter restored - " .. #held .. " item type" .. (#held == 1 and "" or "s") .. " back in the furnaces", LIME)
    end
  end
  -- jobs with nothing left to put in and nothing still cooking are done
  function SM.finish()
    for i = #SM.jobs, 1, -1 do
      local j = SM.jobs[i]
      if j.left <= 0 then
        local still = false
        for _, f in ipairs(SM.furnaces) do if f.cur == j.id then still = true end end
        if not still then
          j.done = true; table.remove(SM.jobs, i)
          local made = j.total - math.max(0, j.left)
          if not j.quiet then setStatus("Smelted " .. commas(made) .. " " .. nameOf(j.id) .. (j.outId and (" into " .. nameOf(j.outId)) or ""), LIME) end
        end
      end
    end
  end
  -- time estimates: a furnace smelts one item every 10 s, a blast furnace every 5 s
  local function rate(rc)
    local r = 0
    for _, f in ipairs(SM.furnaces) do
      if (f.blast and rc.b) or ((not f.blast) and rc.f) then r = r + (f.ips or 0.1) end
    end
    return r
  end
  local function fmtTime(sec)
    sec = math.ceil(sec)
    if sec < 60 then return sec .. "s" end
    if sec < 3600 then local m = math.floor(sec / 60); local r = sec % 60; return m .. "m" .. (r > 0 and (" " .. r .. "s") or "") end
    local h = math.floor(sec / 3600); return h .. "h " .. math.floor((sec % 3600) / 60) .. "m"
  end
  SM.fmtTime = fmtTime
  function SM.eta(count, rc)                         -- seconds for `count` items, or nil if nothing can smelt it
    local r = rc and rate(rc) or 0
    if r <= 0 then return nil end
    return count / r
  end
  function SM.etaLeft()                              -- seconds until everything queued is done
    -- jobs run side by side, so: all the work shared over every furnace that can help,
    -- but never less than the slowest single job on the furnaces that can do it
    local items, slowest, any = 0, 0, { b = false, f = false }
    for _, j in ipairs(SM.jobs) do
      local n = math.max(0, j.left)
      for _, f in ipairs(SM.furnaces) do if f.cur == j.id then n = n + (f.n or 0) end end
      items = items + n
      local t = SM.eta(n, j)
      if t and t > slowest then slowest = t end
      any.b, any.f = any.b or j.b, any.f or j.f
    end
    local shared = SM.eta(items, any) or 0
    return math.max(shared, slowest)
  end
  function SM.status()
    if #SM.furnaces == 0 then return nil end
    if data.smeltStop then return "Smelter STOPPED - " .. commas(SM.heldCount()) .. " items held" end
    local busyN, left = 0, 0
    for _, f in ipairs(SM.furnaces) do if f.cur then busyN = busyN + 1 end end
    for _, j in ipairs(SM.jobs) do left = left + j.left end
    if busyN == 0 and #SM.jobs == 0 then return nil end
    local j = SM.jobs[1]
    local eta = SM.etaLeft()
    return "Smelting" .. (j and (" " .. nameOf(j.id)) or "") .. " - " .. busyN .. "/" .. #SM.furnaces .. " furnaces" ..
      (eta > 0 and (", ~" .. fmtTime(eta) .. " left") or "") .. (SM.noFuel and "  (NO FUEL!)" or "")
  end
  -- a crafting-chain step that needs smelting: send what the recipe needs, wait for it
  function SM.run(st, show)
    if #SM.furnaces == 0 then return 0, "no furnaces connected" end
    if data.smeltStop then return 0, "the smelter is stopped (RESTORE it on the SMELTER panel)" end
    if SM.rescan then SM.rescan() end                     -- see what earlier steps just made
    local plan = craftPlan(st.rc, st.crafts)
    if plan.short > 0 then return 0, "not enough to smelt" end
    local mine, total = {}, 0
    for _, x in ipairs(plan.take) do
      local j = SM.add(R.id[x.it], x.n, st.rc)
      if j then mine[#mine + 1] = j; total = total + x.n end
    end
    local can = 0
    for _, f in ipairs(SM.furnaces) do if fits(f, { b = st.rc.b, f = st.rc.f }) then can = can + 1 end end
    if can == 0 then return 0, (st.rc.b and not st.rc.f) and "needs a blast furnace" or "needs a regular furnace" end
    SM.progressAt = now()
    while true do
      local done, left = true, 0
      for _, j in ipairs(mine) do if not j.done then done = false end; left = left + math.max(0, j.left) end
      if done then break end
      if show then show("Smelting " .. commas(total) .. " for " .. nameOf(R.id[st.rc.out]) .. "  ~" .. fmtTime(SM.etaLeft()) .. " left") end
      if data.smeltStop then return 0, "the smelter was stopped" end
      if now() - (SM.progressAt or now()) > 90 then                          -- nothing came out for 90 s
        return 0, SM.noFuel and "furnaces ran out of fuel (put coal or charcoal in storage)" or "furnaces stopped working (full output? no fuel?)"
      end
      sleep(1)
    end
    sleep(1.5); SM.tick()                                                 -- collect the last ones
    return total
  end

  -- input chest: store / smelt / leave for the question
  function SM.sortInput()
    if not peripheral.isPresent(CFG.input) then return 0, 0 end
    local ok, l = pcall(peripheral.call, CFG.input, "list")
    if not ok or type(l) ~= "table" then return 0, 0 end
    local moved, stuck = 0, 0
    SM.asks = {}
    local smeltN = {}
    for slot, it in pairs(l) do
      local dec = SM.decide(it.name, it.count)
      if dec ~= "ask" then
        local left = it.count
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
        if dec == "smelt" then smeltN[it.name] = (smeltN[it.name] or 0) + (it.count - left) end
      end
    end
    for id in pairs(SM.once) do if not SM.asks[id] then SM.once[id] = nil end end
    SM.once = {}
    if next(smeltN) and SM.rescan then SM.rescan() end
    for id, n in pairs(smeltN) do SM.add(id, n) end
    if next(SM.asks) and UI.panel ~= "smelt" and not SM.shown then
      SM.shown = true; UI.panel = "smelt"
      if speaker then pcall(speaker.playNote, "pling", 1, 12) end
    end
    if not next(SM.asks) then SM.shown = nil end
    HIST.add(moved)
    return moved, stuck
  end

  -- the question on the storage screen
  function SM.drawPanel()
    text(RX1, 6, "SMELT THESE?", YELLOW)
    text(RX1, 7, fit(#SM.furnaces .. " furnaces (" .. (SM.nBlast or 0) .. " blast)", RX2 - RX1 - 17), GRAY)
    if data.smeltStop then
      button("smstop", RX2 - 15, 6, RX2, 7, "RESTORE", BLACK, LIME, function() SM.request("resume") end)
      text(RX1, 8, fit("STOPPED - " .. commas(SM.heldCount()) .. " items held", RX2 - RX1 - 16), RED)
    else
      button("smstop", RX2 - 15, 6, RX2, 7, "EMERGENCY STOP", WHITE, RED, function() SM.request("stop") end)
    end
    local ids = {}
    for id in pairs(SM.asks) do ids[#ids + 1] = id end
    table.sort(ids)
    local y = 9
    if #ids == 0 then text(RX1, y, "nothing waiting", LGRAY); y = y + 2 end
    local bw = math.floor((RX2 - RX1 + 1 - 3) / 4)
    for _, id in ipairs(ids) do
      if y > H - 12 then text(RX1, y, "+ more waiting...", GRAY); y = y + 1; break end
      local rc = SM.info(id)
      text(RX1, y, fit(commas(SM.asks[id]) .. "x " .. nameOf(id), RX2 - RX1 + 1), WHITE)
      local outName = rc and R.name[rc.out] or "?"
      local how = (rc and rc.b) and (rc.f and "furnace or blast" or "blast furnace") or "furnace"
      local eta = rc and SM.eta(SM.asks[id], rc)
      local ts = eta and ("~" .. fmtTime(eta)) or "no furnace for it"
      text(RX1 + 1, y + 1, fit("\26 " .. outName .. "  (" .. how .. ")", RX2 - RX1 - #ts - 1), LGRAY)
      text(RX2 - #ts + 1, y + 1, ts, eta and CYAN or RED)
      local bx = RX1
      local function b(label, bg, fg, fn) button("sm" .. label .. id, bx, y + 2, bx + bw - 1, y + 2, label, fg, bg, fn); bx = bx + bw + 1 end
      b("SMELT", LIME, BLACK, function() SM.once[id] = "smelt"; os.queueEvent("storage_task") end)
      b("STORE", GRAY, WHITE, function() SM.once[id] = "store"; os.queueEvent("storage_task") end)
      b("ALWAYS", CYAN, BLACK, function() data.smeltRule[id] = "always"; dirty = true; os.queueEvent("storage_task") end)
      b("NEVER", RED, WHITE, function() data.smeltRule[id] = "never"; dirty = true; os.queueEvent("storage_task") end)
      y = y + 4
    end
    if #ids > 1 then
      button("small", RX1, y, RX1 + bw * 2, y, "SMELT ALL", BLACK, LIME, function()
        for id in pairs(SM.asks) do SM.once[id] = "smelt" end; os.queueEvent("storage_task") end)
      button("stall", RX1 + bw * 2 + 2, y, RX2, y, "STORE ALL", WHITE, GRAY, function()
        for id in pairs(SM.asks) do SM.once[id] = "store" end; os.queueEvent("storage_task") end)
      y = y + 2
    end
    -- remembered choices
    local rules = {}
    for id, r in pairs(data.smeltRule) do rules[#rules + 1] = { id = id, r = r } end
    table.sort(rules, function(a, b) return a.id < b.id end)
    local ry = math.max(y + 1, H - 9)
    text(RX1, ry, "REMEMBERED (tap X to forget)", YELLOW)
    ry = ry + 1
    if #rules == 0 then text(RX1, ry, "none", GRAY) end
    for _, e in ipairs(rules) do
      if ry > H - 4 then break end
      text(RX1, ry, e.r == "always" and "ALWAYS" or "NEVER", e.r == "always" and CYAN or RED)
      text(RX1 + 7, ry, fit(nameOf(e.id), RX2 - RX1 - 10), WHITE)
      button("smx" .. e.id, RX2 - 2, ry, RX2, ry, "X", WHITE, RED, function() data.smeltRule[e.id] = nil; dirty = true end)
      ry = ry + 1
    end
    button("smback", RX1, H - 3, RX2, H - 1, string.char(17) .. " BACK", BLACK, YELLOW, function() UI.panel = nil end)
  end
end

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
  SM.learnWoods(lists, storages)
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
      local b = newByName[SM.groupKey(it)]
      if not b then
        b = { id = SM.groupKey(it), name = SM.groupKey(it), count = 0, locs = {} }; newByName[b.id] = b
      end
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
SM.rescan = scan

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
      need[SM.realId(R.id[it])] = (need[SM.realId(R.id[it])] or 0) + n
      if got < n then return made, "pickup is full" end
    end
    if not arrangePickup(pk, need) then return made, "pickup is too full to sort" end
    jobCounter = jobCounter + 1
    local cells = {}
    for cell, it in pairs(assign) do
      local r, c = math.floor((cell - 1) / 3), (cell - 1) % 3
      cells[r * 4 + c + 1] = SM.realId(R.id[it])
    end
    local nslots = 0
    for _ in pairs(cells) do nslots = nslots + 1 end
    local job = { type = "craft", job = jobCounter, cells = cells, k = k, out = SM.realId(R.id[t.out]), slots = nslots, n = t.rc.n }
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
  for _, rc in ipairs(R.byOut[it] or {}) do l[#l + 1] = rc end
  for _, rc in ipairs(SM.recs(it) or {}) do l[#l + 1] = rc end
  table.sort(l, function(a, b) return directShort(a) < directShort(b) end)
  return l
end
local function craftCandidates(g, chain)
  local list, score = {}, {}
  for _, it in ipairs(groupItems(g)) do
    if (R.byOut[it] or SM.recs(it)) and not chain[it] then
      list[#list + 1] = it
      local best = math.huge
      for _, rc in ipairs(R.byOut[it] or {}) do best = math.min(best, directShort(rc)) end
      for _, rc in ipairs(SM.recs(it) or {}) do best = math.min(best, directShort(rc)) end
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
    local made, err
    if st.rc.smelt then
      made, err = SM.run(st, function(m) busy = "Step " .. i .. "/" .. total .. ": " .. m end)
      scan()
    else
      made, err = autoCraft({ rc = st.rc, out = st.out, crafts = st.crafts, name = name,
        step = "Step " .. i .. "/" .. total .. ": " })
    end
    if err then return 0, "while making " .. name .. ": " .. err end
    SM.learnDouble(R.id[st.out], currentPickup())
    pickupToStorage(SM.realId(R.id[st.out]))
  end
  t.step = "Step " .. total .. "/" .. total .. ": "
  local made, err = autoCraft(t)
  return made, err, #steps
end

-- ---------------------------------------------------------- SHA-256 (signs pocket remote requests)
local band, bor, bxor, bnot, rrot, rshift = bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.rrotate, bit32.rshift
local SHA_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local function sha256(msg)
  msg = tostring(msg)
  local len = #msg
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
  local bits = len * 8
  local hi = math.floor(bits / 4294967296)
  msg = msg .. string.char(
    band(rshift(hi, 24), 255), band(rshift(hi, 16), 255), band(rshift(hi, 8), 255), band(hi, 255),
    band(rshift(bits, 24), 255), band(rshift(bits, 16), 255), band(rshift(bits, 8), 255), band(bits, 255))
  local h0, h1, h2, h3, h4, h5, h6, h7 =
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = bor(a * 16777216, b * 65536, c * 256, d)
    end
    for i = 16, 63 do
      local s0 = bxor(rrot(w[i - 15], 7), rrot(w[i - 15], 18), rshift(w[i - 15], 3))
      local s1 = bxor(rrot(w[i - 2], 17), rrot(w[i - 2], 19), rshift(w[i - 2], 10))
      w[i] = band(w[i - 16] + s0 + w[i - 7] + s1, 0xffffffff)
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 0, 63 do
      local S1 = bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = band(h + S1 + ch + SHA_K[i + 1] + w[i], 0xffffffff)
      local S0 = bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = band(S0 + maj, 0xffffffff)
      h, g, f, e, d, c, b, a = g, f, e, band(d + t1, 0xffffffff), c, b, a, band(t1 + t2, 0xffffffff)
    end
    h0, h1, h2, h3 = band(h0 + a, 0xffffffff), band(h1 + b, 0xffffffff), band(h2 + c, 0xffffffff), band(h3 + d, 0xffffffff)
    h4, h5, h6, h7 = band(h4 + e, 0xffffffff), band(h5 + f, 0xffffffff), band(h6 + g, 0xffffffff), band(h7 + h, 0xffffffff)
  end
  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

-- ---------------------------------------------------------- straight to / from you (Advanced Peripherals Inventory Manager)
-- AP 0.8 (1.21): importItem(chestName, filter) moves chest -> you, exportItem(chestName, filter) moves you -> chest.
-- The chest is any inventory this computer can see on the network; slots are numbered from 1.
-- Your inventory as the manager sees it: 1-9 hotbar, 10-36 main, 37-40 armor, 41 offhand.
local IMS = {}                 -- every Inventory Manager: { name, owner }
-- who each manager belongs to, by its number (inventory_manager_0 = 0). Used when the
-- game hands back an account ID (98d1e7ad-...) instead of the player's name.
local IM_NAMES = { [0] = "TEN", [2] = "Haydog098" }
local function isUUID(s) return type(s) == "string" and s:match("^%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil end
local function findIM()
  local list = {}
  for _, n in ipairs(peripheral.getNames()) do
    local t = (peripheral.getType(n) or ""):lower()
    if t:find("inventory") and t:find("manager") then
      local ok, o = pcall(peripheral.call, n, "getOwner")
      local owner = (ok and type(o) == "string") and o or nil
      local num = tonumber(n:match("(%d+)$"))
      local nice = num and IM_NAMES[num]
      if owner and nice then
        -- pocket remotes paired under the ID or the full name: move them to the short name
        for _, r in pairs(data.remotes) do if r.player == owner and owner ~= nice then r.player = nice; dirty = true end end
        owner = nice
      end
      list[#list + 1] = { name = n, owner = owner }
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  IMS = list
  return #IMS > 0
end
local function owners()
  local t = {}
  for _, m in ipairs(IMS) do if m.owner then t[#t + 1] = m.owner end end
  return t
end
-- the manager holding this player's card (or the first one)
local function imFor(player)
  for _, m in ipairs(IMS) do if m.owner and m.owner == player then return m end end
  if player then return nil end
  return IMS[1]
end
local function imMove(im, method, chest, filter)
  local ok, n, err = pcall(peripheral.call, im.name, method, chest, filter)
  if not ok then return 0, tostring(n):gsub("^.-:%d+: ", "") end
  if type(n) ~= "number" then return 0, tostring(err or "nothing moved") end
  return n
end

local function sendToPlayer(key, want, player)
  if #IMS == 0 and not findIM() then return 0, "no Inventory Manager on the network" end
  local im = imFor(player)
  if not im then return 0, "no Inventory Manager has " .. tostring(player) .. "'s Memory Card" end
  local e = key:find("#", 1, true) and index[key] or byName[key]
  if not e or e.count == 0 then return 0, "none in storage" end
  local total, left = 0, math.min(want, e.count)
  for _, loc in ipairs(e.locs) do                 -- straight from each chest slot into your inventory
    if left <= 0 then break end
    local n, err = imMove(im, "importItem", loc.inv, { name = e.name, fromSlot = loc.slot, count = math.min(left, loc.count) })
    if n == 0 and err then
      if total > 0 then return total, "your inventory is full" end
      return 0, (err:find("memory card") and "put a Memory Card bound to you in the Inventory Manager") or err
    end
    if n == 0 then return total, total > 0 and "your inventory is full" or "couldn't move it (inventory full?)" end
    total, left = total + n, left - n
  end
  return total
end

-- where to put an item: chests that already hold it first, then any storage chest
local function homesFor(name)
  local order, seen = {}, {}
  local e = byName[name]
  if e then for _, loc in ipairs(e.locs) do if not seen[loc.inv] then seen[loc.inv] = true; order[#order + 1] = loc.inv end end end
  for _, n in ipairs(storages) do if not seen[n] then order[#order + 1] = n end end
  return order
end

-- empty your main inventory (slots 10-36) straight into storage; hotbar, armor and offhand stay
local function dumpPlayer(player)
  if #IMS == 0 and not findIM() then return 0, "no Inventory Manager on the network" end
  local im = imFor(player)
  if not im then return 0, "no Inventory Manager has " .. tostring(player) .. "'s Memory Card" end
  local ok, list = pcall(peripheral.call, im.name, "list")
  if not ok or type(list) ~= "table" then
    return 0, tostring(list):find("memory card") and "put a Memory Card bound to you in the Inventory Manager" or "couldn't read your inventory"
  end
  local moved, lastErr = 0, nil
  for slot, it in pairs(list) do
    slot = tonumber(slot)
    if slot and slot >= 10 and slot <= 36 and it.name then
      local left = it.count
      for _, chest in ipairs(homesFor(it.name)) do
        if left <= 0 then break end
        local n, err = imMove(im, "exportItem", chest, { name = it.name, fromSlot = slot, count = left })
        if err then lastErr = err end
        left, moved = left - n, moved + n
      end
    end
  end
  if moved == 0 and lastErr then return 0, lastErr end
  HIST.add(moved)
  return moved
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

local function sortInput() return SM.sortInput() end

-- ---------------------------------------------------------- drawing
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
  local who = owners()
  if UI.sendTo ~= "pickup" then
    local okWho = false
    for _, w in ipairs(who) do if w == UI.sendTo then okWho = true end end
    if not okWho then UI.sendTo = who[1] or "pickup" end
  end
  local toMe = UI.sendTo ~= "pickup"
  if #who > 0 then
    text(RX1, 19, "TO", YELLOW, PANEL)
    local slots = math.min(3, #who) + 1
    local bw = math.floor((RX2 - RX1 - 3 - (slots - 1)) / slots)
    for i = 1, math.min(3, #who) do
      local x = RX1 + 3 + (i - 1) * (bw + 1)
      local on = UI.sendTo == who[i]
      button("to" .. i, x, 19, x + bw - 1, 19, fit(who[i], bw), on and BLACK or WHITE, on and CYAN or GRAY, function() UI.sendTo = who[i] end)
    end
    local x = RX1 + 3 + math.min(3, #who) * (bw + 1)
    button("toPick", x, 19, RX2, 19, fit(kind or "PICKUP", RX2 - x + 1), toMe and WHITE or BLACK, toMe and GRAY or LIME, function() UI.sendTo = "pickup" end)
  else
    text(RX1, 19, "SEND TO PICKUP", YELLOW, PANEL)
    text(RX1 + 15, 19, kind and (string.char(16) .. " " .. kind) or "(none connected!)", kind == "BACKPACK" and CYAN or (kind and LIME or RED), PANEL)
  end
  local amounts = { { "1", 1 }, { "16", 16 }, { "64", 64 }, { "ALL", math.huge } }
  for i, a in ipairs(amounts) do
    local x = RX1 + (i - 1) * 10
    button("get" .. a[1], x, 21, x + 8, 23, a[1], BLACK, toMe and CYAN or LIME, function()
      if toMe then
        queue({ kind = "tome", id = id, n = a[2], name = name, player = UI.sendTo })
        setStatus("Sending " .. a[1] .. " " .. name .. " to " .. UI.sendTo .. "...", CYAN)
      else
        queue({ kind = "retrieve", id = id, n = a[2] })
        setStatus("Sending " .. a[1] .. " " .. name .. "...", LIME)
      end
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

local drawRemotes
-- names for the paired pocket remotes (by pocket computer ID)
local REMOTE_NAMES = { [5] = "TensorialRhyme5", [6] = "Haydog098" }
-- whose inventory each pocket sends to (must match the names in IM_NAMES)
local REMOTE_PLAYER = { [5] = "TEN", [6] = "Haydog098" }
local function remoteName(id)
  local n = REMOTE_NAMES[tonumber(id)]
  return n and (n .. " (#" .. id .. ")") or ("#" .. id)
end
-- paired pocket remotes + pairing a new one
local PAIR = { code = nil, until_ = 0, player = nil }
local CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   -- no 0/O or 1/I mix-ups
local function newPairCode(player)
  local c = ""
  for i = 1, 8 do local k = math.random(1, #CODE_CHARS); c = c .. CODE_CHARS:sub(k, k) end
  PAIR.code, PAIR.until_, PAIR.player = c, now() + 120, player
end
drawRemotes = function()
  text(RX1, 6, "POCKET REMOTES", YELLOW)
  text(RX1, 7, "only paired remotes can use the storage", GRAY)
  local y = 9
  local ids = {}
  for id in pairs(data.remotes) do ids[#ids + 1] = id end
  table.sort(ids)
  if #ids == 0 then text(RX1, y, "none paired yet", LGRAY); y = y + 1 end
  for _, id in ipairs(ids) do
    if y > 17 then break end
    local r = data.remotes[id]
    local nm = REMOTE_NAMES[tonumber(id)]
    text(RX1, y, fit(nm or ("#" .. id), 16), CYAN)
    text(RX1 + 17, y, "#" .. id, GRAY)
    text(RX1 + 1, y + 1, fit("for " .. (r.player or "anyone"), 26), LGRAY)
    button("rm" .. id, RX2 - 9, y, RX2, y, "REMOVE", WHITE, RED, function()
      data.remotes[id] = nil; save(); setStatus("Removed pocket remote " .. remoteName(id), YELLOW)
    end)
    y = y + 2
  end
  text(RX1, 20, "PAIR A NEW REMOTE FOR:", YELLOW)
  local who = owners()
  if #who == 0 then who = { "anyone" } end
  for i = 1, math.min(3, #who) do
    local x = RX1 + (i - 1) * 13
    button("pairfor" .. i, x, 22, x + 11, 24, fit(who[i], 11), BLACK, CYAN, function()
      newPairCode(who[i] ~= "anyone" and who[i] or nil)
    end)
  end
  if PAIR.code and now() < PAIR.until_ then
    fill(RX1, 26, RX2, 30, HILITE)
    text(RX1 + 1, 26, "Type this on the pocket:", LGRAY, HILITE)
    local shown = PAIR.code:sub(1, 4) .. "-" .. PAIR.code:sub(5)
    text(RX1 + math.floor((RX2 - RX1 + 1 - #shown * 2) / 2), 28, (shown:gsub(".", "%0 ")), YELLOW, HILITE)
    text(RX1 + 1, 30, "for " .. (PAIR.player or "anyone") .. "  -  " .. math.ceil(PAIR.until_ - now()) .. "s left", LGRAY, HILITE)
  elseif PAIR.code then PAIR.code = nil end
  button("rback", RX1, H - 3, RX2, H - 1, string.char(17) .. " BACK", BLACK, YELLOW, function() UI.panel = nil; PAIR.code = nil end)
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
    if UI.panel == "remotes" then drawRemotes()
    elseif UI.panel == "smelt" then SM.drawPanel()
    else
      local y = drawKeyboard(6)
      drawAlerts(y + 1)
      local who = owners()
      local by = H - 3
      if #who == 1 then
        button("dump", RX1, by, RX2 - 13, H - 1, "PUT AWAY MY INVENTORY", BLACK, CYAN, function()
          queue({ kind = "dump", player = who[1] }); setStatus("Emptying " .. who[1] .. "'s inventory into storage...", CYAN)
        end)
      elseif #who >= 2 then
        text(RX1, by - 1, "PUT AWAY INVENTORY:", YELLOW)
        local n = math.min(3, #who)
        local bw = math.floor((RX2 - 13 - RX1 + 1 - (n - 1)) / n)
        for i = 1, n do
          local x = RX1 + (i - 1) * (bw + 1)
          button("dump" .. i, x, by, x + bw - 1, H - 1, fit(who[i], bw), BLACK, CYAN, function()
            queue({ kind = "dump", player = who[i] }); setStatus("Emptying " .. who[i] .. "'s inventory into storage...", CYAN)
          end)
        end
      end
      button("remotes", RX2 - 11, by, RX2, H - 1, "REMOTES", WHITE, PURPLE, function() UI.panel = "remotes" end)
      if #SM.furnaces > 0 then
        local waiting = 0
        for _ in pairs(SM.asks) do waiting = waiting + 1 end
        button("smelter", RX2 - 11, by - 2, RX2, by - 2, data.smeltStop and "STOPPED" or (waiting > 0 and ("SMELT? " .. waiting) or "SMELTER"),
          data.smeltStop and WHITE or BLACK, data.smeltStop and RED or (waiting > 0 and YELLOW or ORANGE), function() UI.panel = "smelt" end)
        local st = SM.status()
        if st then text(RX1, by - 2, fit(st, RX2 - RX1 - 12), ORANGE) end
      end
    end
  end
  present()
end

-- ---------------------------------------------------------- pocket remote server
local NET_PROTO = "storagenet"
local function searchFor(q, offset, limit)
  q = (q or ""):lower()
  local out = {}
  for id, e in pairs(index) do
    local name = data.names[id] or prettyId(e.name or id)
    if q == "" or name:lower():find(q, 1, true) or id:lower():find(q, 1, true) then
      out[#out + 1] = { id = id, name = name, count = e.count }
    end
  end
  local qw = queryWords(q)
  if #out < 10 and #q >= 3 and #qw > 0 then              -- typo-friendly, like the monitor
    local have = {}
    for _, it in ipairs(out) do have[it.id] = true end
    for id, e in pairs(index) do
      if not have[id] then
        local name = data.names[id] or prettyId(e.name or id)
        if fuzzyScore(qw, name:lower()) then out[#out + 1] = { id = id, name = name, count = e.count, close = true } end
      end
    end
  end
  table.sort(out, function(a, b)
    if (a.close or false) ~= (b.close or false) then return not a.close end
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  local total = #out
  local page = {}
  for i = (offset or 0) + 1, math.min(total, (offset or 0) + (limit or 60)) do page[#page + 1] = out[i] end
  return page, total
end
local function netInfo(player)
  local who = owners()
  return { type = "info", status = status.msg, busy = busy, im = #who > 0, owner = player or who[1], owners = who,
    used = stats.used, slots = stats.slots, total = stats.total, types = stats.types }
end
-- every request must be signed with the key made at pairing (the code itself is never sent)
local function canon(msg)
  return table.concat({ tostring(msg.type), tostring(msg.q or ""), tostring(msg.id or ""), tostring(msg.n or ""), tostring(msg.to or ""),
    tostring(msg.off or ""), tostring(msg.lim or "") }, "|")
end
local function verify(msg)
  local dev = tonumber(msg.dev)
  local r = dev and data.remotes[dev]
  if not r then return nil, "not paired" end
  if REMOTE_PLAYER[dev] and r.player ~= REMOTE_PLAYER[dev] then r.player = REMOTE_PLAYER[dev]; dirty = true end
  local ctr = tonumber(msg.ctr)
  if not ctr or ctr <= (r.ctr or 0) then return nil, "old or replayed request" end
  if msg.mac ~= sha256(r.key .. "|" .. ctr .. "|" .. canon(msg)) then return nil, "bad signature" end
  r.ctr = ctr; dirty = true
  return r
end
local function netServer()
  openNet()
  pcall(rednet.host, NET_PROTO, "storage_" .. os.getComputerID())
  while true do
    local from, msg = rednet.receive(NET_PROTO)
    if type(msg) == "table" then
      if msg.type == "pair" then
        local dev = tonumber(msg.dev)
        if PAIR.code and now() < PAIR.until_ and dev and msg.nonce
           and msg.proof == sha256(PAIR.code .. "|pair|" .. dev .. "|" .. tostring(msg.nonce)) then
          data.remotes[dev] = { key = sha256(PAIR.code .. "|key|" .. dev), player = PAIR.player, ctr = 0 }
          save()
          setStatus("Paired pocket remote " .. remoteName(dev) .. (PAIR.player and (" for " .. PAIR.player) or ""), LIME)
          PAIR.code = nil
          rednet.send(from, { type = "paired", ok = true, player = data.remotes[dev].player, dev = dev }, NET_PROTO)
        else
          rednet.send(from, { type = "paired", ok = false, dev = dev, why = PAIR.code and "wrong code" or "no pairing code is showing" }, NET_PROTO)
        end
      else
        local r, why = verify(msg)
        if not r then
          rednet.send(from, { type = "denied", why = why, dev = msg.dev }, NET_PROTO)
        elseif msg.type == "search" then
          local off = math.max(0, math.floor(tonumber(msg.off) or 0))
          local lim = math.max(1, math.min(60, math.floor(tonumber(msg.lim) or 60)))
          local res, total = searchFor(msg.q, off, lim)
          local info = netInfo(r.player)
          info.type, info.q, info.items, info.found, info.off = "results", msg.q, res, total, off
          rednet.send(from, info, NET_PROTO)
        elseif msg.type == "send" and type(msg.id) == "string" then
          local n = tonumber(msg.n) or 1
          local name = data.names[msg.id] or prettyId(msg.id)
          if msg.to == "pickup" then queue({ kind = "retrieve", id = msg.id, n = n })
          else queue({ kind = "tome", id = msg.id, n = n, name = name, player = r.player }) end
          setStatus("Pocket: sending " .. (n == math.huge and "all" or n) .. " " .. name, CYAN)
          rednet.send(from, netInfo(r.player), NET_PROTO)
        elseif msg.type == "dump" then
          queue({ kind = "dump", player = r.player })
          setStatus("Pocket: emptying " .. (r.player or "your") .. " inventory into storage...", CYAN)
          rednet.send(from, netInfo(r.player), NET_PROTO)
        elseif msg.type == "info" then
          rednet.send(from, netInfo(r.player), NET_PROTO)
        end
      end
    end
  end
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
        SM.learnDouble(R.id[t.out], currentPickup())
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
      elseif t.kind == "tome" then
        busy = "Sending " .. t.name .. " to " .. (t.player or "you") .. "..."
        local n, err = sendToPlayer(t.id, t.n, t.player)
        busy = nil
        local who = t.player or "you"
        if err then setStatus((n > 0 and ("Gave " .. who .. " " .. commas(n) .. " " .. t.name .. ", then: ") or "Couldn't send: ") .. err, n > 0 and YELLOW or RED)
        else setStatus("Gave " .. who .. " " .. commas(n) .. " " .. t.name, LIME); if speaker then pcall(speaker.playNote, "pling", 0.8, 18) end end
        scan()
      elseif t.kind == "dump" then
        busy = "Emptying your inventory into storage..."
        local n, err = dumpPlayer(t.player)
        busy = nil
        if err then setStatus("Couldn't empty your inventory: " .. err, RED)
        else setStatus("Put away " .. commas(n) .. " items from " .. (t.player and (t.player .. "'s") or "your") .. " inventory", LIME) end
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
      findIM()                                         -- picks up new managers / memory cards
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
    busy = function() return busy end, SM = SM, queue = queue, byName = function() return byName end, groupItems = groupItems, R = R, pair = function() return PAIR end, sha256 = sha256, R = R, rebuild = function() rebuildList() end, chainPlan = chainPlan, BASEchild = function() return nil end, rankRecipes = rankRecipes, craftPlan = craftPlan }
end

math.randomseed(os.epoch("utc") + os.getComputerID() * 7919)
findIM()
-- read-only status for the jukebox CONTROL panel (no items can be moved with this)
local function statusLoop()
  local lastCrafterCheck = now()
  while true do
    sleep(5)
    HIST.tick(stats)
    if openNet() then
      if now() - lastCrafterCheck > 60 then lastCrafterCheck = now(); findCrafter(true) end
      local low = {}
      for id, limit in pairs(data.alerts) do
        local have = index[id] and index[id].count or 0
        if have < limit then low[#low + 1] = { name = data.names[id] or prettyId(id), have = have, limit = limit } end
      end
      table.sort(low, function(x, y) return x.have / x.limit < y.have / y.limit end)
      while #low > 6 do table.remove(low) end
      pcall(rednet.broadcast, { type = "status", used = stats.used, slots = stats.slots, total = stats.total,
        types = stats.types, msg = status.msg, busy = busy, low = low, crafter = CRAFTER.id ~= nil,
        owners = owners(), at = os.epoch("utc"), smelt = SM.status(), today = HIST.today, yesterday = HIST.yesterday, graph = HIST.graph() }, "storagestat")
    end
  end
end
local function smeltLoop()
  SM.find()
  local lastFind = now()
  while true do
    local id = os.startTimer(2)
    repeat local ev, p = os.pullEvent() until (ev == "timer" and p == id) or ev == "smelt_tick"
    if now() - lastFind > 30 then lastFind = now(); SM.find() end
    if SM.req then SM.doRequest() end
    SM.tick()
  end
end
parallel.waitForAny(ui, worker, netServer, smeltLoop, function()
  loadRecipes(); rebuildList()
  findCrafter(true)
  statusLoop()
end)
for _, m in ipairs(mons) do
  for i = 0, 15 do m.p.setPaletteColour(2 ^ i, term.nativePaletteColour(2 ^ i)) end
  m.p.setBackgroundColour(colors.black); m.p.clear()
end
term.clear(); term.setCursorPos(1, 1); print("Storage manager stopped.")
