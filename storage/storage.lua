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
  [colors.orange] = 0xff9a3a, [colors.red] = 0xff4a4a, [colors.purple] = 0x9b5cff,
}
for _, m in ipairs(mons) do for c, v in pairs(PAL) do m.p.setPaletteColour(c, v) end end
local WHITE, ORANGE, YELLOW, LIME, GRAY, LGRAY = "0", "1", "4", "5", "7", "8"
local CYAN, PURPLE, HILITE, PANEL, RED, BLACK = "9", "a", "b", "c", "e", "f"

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
local index = {}             -- id -> { id, count, locs = { {inv, slot, count} } }
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

local UI = { search = "", page = 1, selected = nil, perPage = 0, lowAlerted = {} }

local function rebuildList()
  items = {}
  local q = UI.search:lower()
  for id, it in pairs(index) do
    local name = data.names[id] or prettyId(id)
    if q == "" or name:lower():find(q, 1, true) or id:lower():find(q, 1, true) then
      items[#items + 1] = { id = id, name = name, count = it.count }
    end
  end
  if data.sort == "name" then
    table.sort(items, function(a, b) return a.name:lower() < b.name:lower() end)
  else
    table.sort(items, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.name < b.name end)
  end
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
  local newIndex = {}
  local slots, used, total = 0, 0, 0
  for i, name in ipairs(storages) do
    slots = slots + (sizes[i] or 0)
    for slot, it in pairs(lists[i] or {}) do
      used = used + 1
      total = total + it.count
      local e = newIndex[it.name]
      if not e then e = { id = it.name, count = 0, locs = {} }; newIndex[it.name] = e end
      e.count = e.count + it.count
      e.locs[#e.locs + 1] = { inv = name, slot = slot, count = it.count }
    end
  end
  index = newIndex
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
        data.names[id] = clean(d.displayName); dirty = true
      else
        data.names[id] = prettyId(id); dirty = true
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
local function queue(t) tasks[#tasks + 1] = t; os.queueEvent("storage_task") end

local function retrieve(id, want)
  local e = index[id]
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

-- ORGANIZE: gather each item into one "home" chest (the one already holding the most of it),
-- then merge its partial stacks there so they take as few slots as possible.
local busy = nil              -- progress text while organizing
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
    local e = index[it.name]
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

local function drawSearchBar()
  fill(LX1, 5, LX2, 5, PANEL)
  local q = UI.search == "" and "tap letters or type to search" or UI.search
  text(LX1 + 1, 5, "Search:", YELLOW, PANEL)
  text(LX1 + 9, 5, fit(q, LX2 - LX1 - 46) .. (UI.search ~= "" and "_" or ""), UI.search == "" and GRAY or WHITE, PANEL)
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

local function drawList()
  local top, bottom = 7, H - 4
  local rows = bottom - top + 1
  local colW = math.floor((LX2 - LX1 - 1) / 2)
  UI.perPage = rows * 2
  local pages = math.max(1, math.ceil(#items / UI.perPage))
  if UI.page > pages then UI.page = pages end
  local first = (UI.page - 1) * UI.perPage
  if #items == 0 then
    text(LX1 + 2, top + 1, stats.scanned == 0 and "Scanning chests..." or "Nothing found", GRAY)
  end
  for i = 1, UI.perPage do
    local it = items[first + i]
    if not it then break end
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
  -- paging
  local py = H - 2
  button("prev", LX1, py, LX1 + 9, H, string.char(17) .. " PREV", YELLOW, UI.page > 1 and GRAY or PANEL,
    function() if UI.page > 1 then UI.page = UI.page - 1 end end)
  button("next", LX2 - 9, py, LX2, H, "NEXT " .. string.char(16), YELLOW, UI.page < pages and GRAY or PANEL,
    function() if UI.page < pages then UI.page = UI.page + 1 end end)
  local pg = "page " .. UI.page .. "/" .. pages .. "   " .. #items .. " shown"
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
      button("key" .. ch, x, y, x + 2, y + 2, ch, WHITE, GRAY, function() UI.search = UI.search .. ch:lower(); UI.page = 1; rebuildList() end)
    end
    y = y + 4
  end
  button("space", RX1, y, RX1 + 14, y + 2, "SPACE", WHITE, GRAY, function() UI.search = UI.search .. " "; rebuildList() end)
  button("del", RX1 + 16, y, RX1 + 26, y + 2, "DEL", WHITE, GRAY, function() UI.search = UI.search:sub(1, -2); UI.page = 1; rebuildList() end)
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
  text(RX1, 7, fit(id, 38), GRAY, PANEL)
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
  button("close", RX1, H - 3, RX2, H - 1, "CLOSE", WHITE, RED, function() UI.selected = nil end)
end

local function draw()
  clear(); hits = {}
  layout()
  drawHeader()
  drawSearchBar()
  drawList()
  for y = 5, H do setCell(RX1 - 2, y, "\149", YELLOW, BLACK) end
  if UI.selected then drawDetail()
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
      draw(); timer = os.startTimer(0.25)
    elseif ev == "monitor_touch" and monNames[a] then
      for i = #hits, 1, -1 do
        local h = hits[i]
        if b >= h.x1 and b <= h.x2 and c >= h.y1 and c <= h.y2 then flash[h.id] = now(); h.fn(b, c); break end
      end
      draw()
    elseif ev == "char" then
      UI.search = UI.search .. a; UI.page = 1; rebuildList(); draw()
    elseif ev == "key" then
      if a == keys.backspace then UI.search = UI.search:sub(1, -2); UI.page = 1; rebuildList(); draw()
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
    busy = function() return busy end }
end

parallel.waitForAny(ui, worker)
for _, m in ipairs(mons) do
  for i = 0, 15 do m.p.setPaletteColour(2 ^ i, term.nativePaletteColour(2 ^ i)) end
  m.p.setBackgroundColour(colors.black); m.p.clear()
end
term.clear(); term.setCursorPos(1, 1); print("Storage manager stopped.")
