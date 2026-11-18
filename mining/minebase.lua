-- ============================================================
--  MINE BASE  -  runs in its own tab next to the mine storage.
--  Hands out turns at the drop-off / fuel chests, tells the turtles
--  which junk blocks storage still wants (keeps 1,000 of each),
--  shows what every turtle is doing, and R / G recalls / sends them.
--  Also keeps the quarry plan: which 3-block layers of each chunk are
--  done or being mined, and hands the next one (top first) to whichever
--  turtle asks, so 3 turtles can share a chunk without overlapping.
-- ============================================================
local PROTO = "minenet"
local CFG = { keep = 1000, junk = {}, exclude = {}, inputs = {} }
if fs.exists("storage_config.txt") then
  local f = fs.open("storage_config.txt", "r")
  local ok, c = pcall(textutils.unserialize, f.readAll()); f.close()
  if ok and type(c) == "table" then for k, v in pairs(c) do CFG[k] = v end end
end
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then rednet.open(name) end
end
if not rednet.isOpen() then print("No wireless/ender modem on this computer - the turtles can't reach me."); end

local turtles, locks = {}, {}
local counts, fuelCoal, lastCount = {}, nil, -100
for _, id in ipairs({ "minecraft:stone", "minecraft:cobblestone", "minecraft:deepslate", "minecraft:cobbled_deepslate", "minecraft:dirt", "minecraft:netherrack", "minecraft:end_stone" }) do        -- every layer of the mining dimension
  local have = false
  for _, j in ipairs(CFG.junk) do if j == id then have = true end end
  if not have then CFG.junk[#CFG.junk + 1] = id end
end
local isJunk, skip = {}, {}
for _, id in ipairs(CFG.junk) do isJunk[id] = true end
for _, n in ipairs(CFG.inputs) do skip[n] = true end
local fuelNames = {}
for _, n in ipairs(CFG.exclude) do skip[n] = true; fuelNames[n] = true end
local found = {}
if fs.exists("mine_ores.txt") then
  local f = fs.open("mine_ores.txt", "r")
  for l in (f.readAll() or ""):gmatch("[^\n]+") do found[#found + 1] = l end
  f.close()
end

-- the layers of a chunk, top first. MUST match CONF.bands in miner.lua.
local BANDS = { { top = 128, bottom = 65 }, { top = 252, bottom = 129 }, { top = 64, bottom = -63 } }
local LAYERS = {}
for _, b in ipairs(BANDS) do
  local y = b.top - 1
  local first = #LAYERS + 1
  while y - 1 >= b.bottom do LAYERS[#LAYERS + 1] = y; y = y - 3 end
  if LAYERS[#LAYERS] - 1 > b.bottom then LAYERS[#LAYERS + 1] = b.bottom + 1 end
end
table.sort(LAYERS, function(a, b) return a > b end)
local PLAN = {}                                   -- [chunk] = { done = { [y] = true }, claim = { [y] = { n =, at = } } }
if fs.exists("mine_plan.txt") then
  local f = fs.open("mine_plan.txt", "r")
  local ok, t = pcall(textutils.unserialize, f.readAll()); f.close()
  if ok and type(t) == "table" then PLAN = t end
end
local function savePlan() local f = fs.open("mine_plan.txt", "w"); f.write(textutils.serialize(PLAN)); f.close() end
local function chunkPlan(c)
  local p = PLAN[c] or {}
  p.done, p.claim = p.done or {}, p.claim or {}
  PLAN[c] = p
  return p
end
local STARTED = os.clock()
local function claimLayer(n, m)
  local c = tonumber(m.chunk)
  if not c then return nil end
  local p = chunkPlan(c)
  if type(m.mig) == "table" and type(m.mig.done) == "table" then          -- old turtle: what it already did
    for _, y in ipairs(m.mig.done) do p.done[y] = true; p.claim[y] = nil end
  end
  if m.fin then p.done[m.fin] = true; p.claim[m.fin] = nil end
  for cc, pp in pairs(PLAN) do                                            -- a turtle works one layer at a time
    for y, cl in pairs(pp.claim or {}) do
      if cl.n == n and not (cc == c and y == m.have) then pp.claim[y] = nil end
    end
  end
  local now = os.epoch("utc")
  local function free(y)
    if p.done[y] then return false end
    local cl = p.claim[y]
    -- a turtle that's been silent for 30 min (and we've been up a while to hear it) gives its layer up
    return not cl or cl.n == n or (now - (cl.at or 0) > 30 * 60 * 1000 and os.clock() - STARTED > 120)
  end
  local give, gc, wait
  local kk = tonumber(m.k) or 0
  if m.have and free(m.have) then give, gc = m.have, c
  else
    -- 2x2 by 2x2: first our own chunk, then help the chunk of the same 2x2 with the most left,
    -- and only when the whole 2x2 is handed out move on to our chunk in the next 2x2
    local list = type(m.chunks) == "table" and m.chunks or { c }
    local last = tonumber(m.last) or list[#list]
    local function freeCount(cc)
      p = chunkPlan(cc)
      local f = 0
      for _, y in ipairs(LAYERS) do if free(y) then f = f + 1 end end
      return f
    end
    local order, seenC = {}, {}
    for _, own in ipairs(list) do
      own = tonumber(own)
      if own and not seenC[own] then
        seenC[own] = true; order[#order + 1] = own
        local base, others = math.floor((own - 1) / 4) * 4, {}
        for i = 1, 4 do
          local o = base + i
          if o ~= own and o <= last and not seenC[o] then others[#others + 1] = { c = o, f = freeCount(o) } end
        end
        table.sort(others, function(a, b) return a.f > b.f end)
        for _, o in ipairs(others) do seenC[o.c] = true; order[#order + 1] = o.c end
      end
    end
    for _, cc in ipairs(order) do
      p = chunkPlan(cc)
      for _, y in ipairs(LAYERS) do
        if free(y) then give, gc = y, cc; break end
        if not p.done[y] then wait = true end                            -- someone else is still on it
      end
      if give then break end
    end
    if give then                                                         -- a corner nobody else in that chunk uses
      local used = {}
      for y, cl in pairs(chunkPlan(gc).claim) do if cl.n ~= n and cl.k then used[cl.k] = true end end
      if used[kk] then for k = 0, 3 do if not used[k] then kk = k; break end end end
    end
  end
  if give then chunkPlan(gc).claim[give] = { n = n, at = now, k = kk } end
  savePlan()
  return give, gc, wait, kk
end
local function progress(c)                         -- layers done, being mined, total
  local p = PLAN[c]
  if not p then return 0, 0, #LAYERS end
  local d, w = 0, 0
  for _ in pairs(p.done or {}) do d = d + 1 end
  for _ in pairs(p.claim or {}) do w = w + 1 end
  return d, w, #LAYERS
end

local function recount()
  if os.clock() - lastCount < 20 then return end
  lastCount = os.clock()
  local c, fc = {}, nil
  for _, name in ipairs(peripheral.getNames()) do
    local isInv = peripheral.hasType and peripheral.hasType(name, "inventory")
    if isInv and (not skip[name] or fuelNames[name]) and not name:find("barrel", 1, true) then
      local ok, l = pcall(peripheral.call, name, "list")
      if ok and type(l) == "table" then
        if fuelNames[name] then fc = fc or 0 end            -- connected, even if it's empty right now
        for _, it in pairs(l) do
          if fuelNames[name] then
            if it.name:find("coal", 1, true) and not it.name:find("ore", 1, true) then fc = (fc or 0) + it.count end
          elseif isJunk[it.name] then c[it.name] = (c[it.name] or 0) + it.count end
        end
      end
    end
  end
  counts, fuelCoal = c, fc
end

-- things in the wrong kind of chest (ores in copper, junk in iron) get moved over, a few stacks at a time
local chestCount = { copper = 0, iron = 0 }
local lastFix, moved = -100, 0
local function resort()
  if os.clock() - lastFix < 15 then return end
  lastFix = os.clock()
  local junkTo, otherTo = CFG.junkTo or "copper", CFG.otherTo or "iron"
  local KIND = { copper = { [45] = true, [90] = true }, iron = { [54] = true, [108] = true }, gold = { [81] = true, [162] = true } }
  local cu, fe = {}, {}
  for _, name in ipairs(peripheral.getNames()) do
    if not skip[name] and peripheral.hasType(name, "inventory") and not name:find("barrel", 1, true) then
      local ok, size = pcall(peripheral.call, name, "size")
      size = ok and size or 0
      if name:find(junkTo, 1, true) or (KIND[junkTo] or {})[size] then cu[#cu + 1] = name
      elseif name:find(otherTo, 1, true) or (KIND[otherTo] or {})[size] then fe[#fe + 1] = name end
    end
  end
  chestCount.copper, chestCount.iron = #cu, #fe
  local cap, used = 0, 0                                -- how full the junk chests are (auto-trash at 3/4)
  for _, name in ipairs(cu) do
    local okS, size = pcall(peripheral.call, name, "size")
    local okL, lim = pcall(peripheral.call, name, "getItemLimit", 1)
    local okI, l = pcall(peripheral.call, name, "list")
    if okS and type(size) == "number" then
      cap = cap + size * ((okL and type(lim) == "number" and lim > 0) and lim or 64)
      if okI and type(l) == "table" then for _, it in pairs(l) do used = used + it.count end end
    end
  end
  chestCount.fill = cap > 0 and used / cap or nil
  if #cu == 0 or #fe == 0 then return end
  local budget = 8
  local function moveOut(from, to, wrong)
    for _, src in ipairs(from) do
      local ok, l = pcall(peripheral.call, src, "list")
      if ok and type(l) == "table" then
        for slot, it in pairs(l) do
          if budget <= 0 then return end
          if wrong(it.name) then
            for _, dst in ipairs(to) do
              local ok2, n = pcall(peripheral.call, src, "pushItems", dst, slot)
              if ok2 and type(n) == "number" and n > 0 then moved = moved + n; budget = budget - 1; break end
            end
          end
        end
      end
    end
  end
  for fname in pairs(fuelNames) do                      -- things dropped in the fuel chest by mistake go to storage
    moveOut({ fname }, fe, function(id) return not isJunk[id] and not (id:find("coal", 1, true) and not id:find("ore", 1, true)) end)
    moveOut({ fname }, cu, function(id) return isJunk[id] end)
  end
  moveOut(cu, fe, function(id) return not isJunk[id] end)
  moveOut(fe, cu, function(id) return isJunk[id] end)
end

local function reply(to, msg, id) msg.re = id; rednet.send(to, msg, PROTO) end
local function handle(from, m)
  if type(m) ~= "table" then return end
  local n = tonumber(m.n)
  if m.t == "status" and n then
    turtles[n] = m; m.at = os.clock(); m.from = from
    for _, l in pairs(locks) do if l.n == n then l.at = os.clock() end end   -- still alive: keep its turn
    local p = tonumber(m.chunk) and PLAN[tonumber(m.chunk)]                  -- still alive: keep its layer
    local cl = p and p.claim and m.layer and p.claim[m.layer]
    if cl and cl.n == n then cl.at = os.epoch("utc") end
  elseif m.t == "check" and n then                                          -- is this layer still this turtle's?
    local p = PLAN[tonumber(m.chunk)]
    local cl = p and p.claim and p.claim[m.y]
    reply(from, { t = "check", gone = (p and p.done and p.done[m.y]) or (cl ~= nil and cl.n ~= n) or false }, m.id)
  elseif m.t == "claim" and n then
    local y, gc, wait, k = claimLayer(n, m)
    reply(from, { t = "claim", y = y, chunk = gc, k = y and k or nil, wait = (not y and wait) or nil }, m.id)
  elseif m.t == "lock" and n then
    local l = locks[m.dock]
    if not l or l.n == n or os.clock() - l.at > 90 then                      -- (a turtle silent for 90s loses its turn)
      locks[m.dock] = { n = n, at = os.clock() }
      reply(from, { t = "lock", ok = true }, m.id)
    else
      reply(from, { t = "lock", ok = false, by = l.n }, m.id)
    end
  elseif m.t == "unlock" and n then
    if locks[m.dock] and locks[m.dock].n == n then locks[m.dock] = nil end
  elseif m.t == "needs" then
    lastCount = -100; recount()
    local needs = {}
    for _, id in ipairs(CFG.junk) do needs[id] = 1e9 end              -- no cap: bring all of it home
    reply(from, { t = "needs", needs = needs, junk = CFG.junk, fuelLow = false }, m.id)
  elseif m.t == "found" and m.name then
    local line = m.name .. " at " .. m.x .. " " .. m.y .. " " .. m.z .. " (turtle " .. tostring(n) .. ")"
    for _, l in ipairs(found) do if l == line then return end end
    found[#found + 1] = line
    local f = fs.open("mine_ores.txt", "a"); f.writeLine(line); f.close()
  end
end

local recalled = false
local askRedo, lastMsg = false, nil                           -- N pressed: waiting for Y to confirm
-- re-mine every finished layer between y 64 and 1 (the netherrack) in every chunk
local function redoNether()
  local n = 0
  for _, p in pairs(PLAN) do
    for y in pairs(p.done or {}) do
      if y <= 64 and y >= 1 then p.done[y] = nil; n = n + 1 end
    end
  end
  savePlan()
  return n
end
local view = nil                                -- a turtle number: showing what it carries
local typed = ""                                -- digits typed so far
local function pretty(id)
  local n = (id:match(":(.+)$") or id):gsub("_", " ")
  return (n:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end
local function drawInv(n)
  term.setBackgroundColour(colors.black); term.clear(); term.setCursorPos(1, 1)
  local t = turtles[n]
  term.setTextColour(colors.yellow); print("TURTLE " .. n .. " CARRYING")
  if not t then term.setTextColour(colors.gray); print("not heard from yet")
  elseif type(t.inv) ~= "table" then
    term.setTextColour(colors.orange)
    print("This turtle runs older code - it shows its")
    print("items after its next restart (or press U).")
  elseif #t.inv == 0 then term.setTextColour(colors.lightGray); print("(empty)")
  else
    local w = term.getSize()
    local half = math.floor(w / 2)
    table.sort(t.inv, function(a, b) return a.c > b.c end)
    for i, it in ipairs(t.inv) do
      local col = (i - 1) % 2
      local row = math.floor((i - 1) / 2) + 3
      local name = pretty(tostring(it.id))
      local num = tostring(it.c)
      name = name:sub(1, half - #num - 3)
      term.setCursorPos(col * half + 1, row)
      term.setTextColour(colors.white); write(name)
      term.setCursorPos(col * half + half - #num - 1, row)
      term.setTextColour(colors.lime); write(num)
    end
    term.setCursorPos(1, math.floor((#t.inv + 1) / 2) + 4)
  end
  if t then
    term.setTextColour(colors.lightGray)
    print(tostring(t.state):sub(1, 50))
    print("free slots " .. tostring(t.free) .. "  fuel " .. tostring(t.fuel) .. "  y " .. tostring(t.y))
  end
  term.setTextColour(colors.gray); print("Any other key = back")
end
local function draw()
  if view then return drawInv(view) end
  term.setBackgroundColour(colors.black); term.clear(); term.setCursorPos(1, 1)
  term.setTextColour(colors.yellow); print("MINE TURTLES" .. (recalled and "   (RECALLED)" or ""))
  term.setTextColour(colors.white)
  local ns = {}
  for n in pairs(turtles) do ns[#ns + 1] = n end
  table.sort(ns)
  local w = term.getSize()
  local two = #ns <= 5                                -- a few turtles: two lines each; lots: one line each
  if #ns == 0 then term.setTextColour(colors.gray); print("no turtles heard from yet") end
  for _, n in ipairs(ns) do
    local t = turtles[n]
    local age = os.clock() - t.at
    local tag = (n < 10 and " " or "") .. n .. " "
    term.setTextColour(age > 60 and colors.red or colors.lime)
    if two then
      print(tag .. tostring(t.state):sub(1, w - #tag))
      term.setTextColour(colors.lightGray)
      print("     y " .. tostring(t.y) .. "  fuel " .. tostring(t.fuel) .. "  free slots " .. tostring(t.free) ..
        (age > 60 and ("  (silent " .. math.floor(age) .. "s)") or ""))
    else
      local tail = " y" .. tostring(t.y) .. " f" .. tostring(t.fuel)
      write(tag .. tostring(t.state):sub(1, w - #tag - #tail - 1))
      term.setTextColour(colors.lightGray)
      local _, cy = term.getCursorPos()
      term.setCursorPos(w - #tail + 1, cy); print(tail)
    end
  end
  local silent = {}                                  -- turtles with a layer in the plan that we haven't heard from
  local seen = {}
  for _, p in pairs(PLAN) do for _, cl in pairs(p.claim or {}) do
    if not turtles[cl.n] and not seen[cl.n] then seen[cl.n] = true; silent[#silent + 1] = cl.n end
  end end
  if #silent > 0 then
    table.sort(silent)
    term.setTextColour(colors.red)
    print("Not heard from: " .. table.concat(silent, " ") .. " (out of fuel? stuck?)")
  end
  term.setTextColour(colors.cyan)
  local cs = {}
  for c in pairs(PLAN) do cs[#cs + 1] = c end
  table.sort(cs)
  local line = ""
  for _, c in ipairs(cs) do
    local d, _, tot = progress(c)
    line = line .. " " .. c .. ":" .. math.floor(d * 100 / tot)
  end
  if line ~= "" then print("Done%" .. line) end
  term.setTextColour(colors.white)
  local busy = {}
  for d, l in pairs(locks) do busy[#busy + 1] = d .. "=" .. l.n end
  print("Turns: " .. (#busy > 0 and table.concat(busy, " ") or "free") .. "  Fuel: " ..
    (fuelCoal and (fuelCoal .. (fuelCoal < 64 and " (LOW)" or "")) or ("not found (" .. (CFG.exclude[1] or "none set") .. ")")))
  term.setTextColour(colors.white)
  write("Chests: " .. chestCount.iron .. " iron, " .. chestCount.copper .. " copper")
  if chestCount.fill then
    term.setTextColour(chestCount.fill >= 0.75 and colors.orange or colors.white)
    write("  junk " .. math.floor(chestCount.fill * 100) .. "% full")
  end
  print("")
  if chestCount.iron == 0 then term.setTextColour(colors.red); print("No iron chests found - right-click their modems?") end
  if lastMsg then term.setTextColour(colors.lime); print(lastMsg)
  elseif #found > 0 then term.setTextColour(colors.orange); print("Too hard to mine: " .. #found .. " spots (mine_ores.txt)") end
  term.setTextColour(colors.lightGray)
  if askRedo then
    term.setTextColour(colors.orange)
    print("Re-mine the netherrack (y 64-1) everywhere? Y = yes")
  else
    print("R recall G go U update N redo nether #+Enter" .. (typed ~= "" and (" [" .. typed .. "]") or ""))
  end
end

local function net()
  while true do
    local from, m = rednet.receive(PROTO)
    handle(from, m)
  end
end
local function screen()
  while true do
    recount(); pcall(resort); draw()
    local t = os.startTimer(1)
    repeat
      local ev, p = os.pullEvent()
      if (ev == "char" or ev == "key") and view then view = nil; typed = ""; draw()
      elseif ev == "char" and p:match("^%d$") then typed = (typed .. p):sub(-2); draw()
      elseif ev == "key" and p == keys.enter and typed ~= "" then view = tonumber(typed); typed = ""; draw()
      elseif ev == "key" and p == keys.backspace then typed = typed:sub(1, -2); draw()
      elseif ev == "char" and askRedo then
        askRedo = false
        if p == "y" or p == "Y" then
          local n = redoNether()
          lastMsg = "Re-mining " .. n .. " netherrack layers"
        end
        draw()
      elseif ev == "char" and (p == "n" or p == "N") then askRedo = true; draw()
      elseif ev == "char" and (p == "r" or p == "R") then
        recalled = true; rednet.broadcast({ t = "cmd", cmd = "recall" }, PROTO)
      elseif ev == "char" and (p == "u" or p == "U") then
        rednet.broadcast({ t = "cmd", cmd = "reboot" }, PROTO)        -- they restart, grab the newest code and carry on
      elseif ev == "char" and (p == "g" or p == "G") then
        recalled = false; rednet.broadcast({ t = "cmd", cmd = "go" }, PROTO)
      end
    until ev == "timer" and p == t
  end
end
if _G.__MINEBASE_TEST then return { handle = handle, PLAN = function() return PLAN end, draw = draw, turtles = turtles, redo = redoNether } end
parallel.waitForAny(net, screen)
