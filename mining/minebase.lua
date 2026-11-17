-- ============================================================
--  MINE BASE  -  runs in its own tab next to the mine storage.
--  Hands out turns at the drop-off / fuel chests, tells the turtles
--  which junk blocks storage still wants (keeps 1,000 of each),
--  shows what every turtle is doing, and R / G recalls / sends them.
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
            if it.name == "minecraft:coal" or it.name == "minecraft:charcoal" then fc = (fc or 0) + it.count end
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
  moveOut(cu, fe, function(id) return not isJunk[id] end)
  moveOut(fe, cu, function(id) return isJunk[id] end)
end

local function reply(to, msg, id) msg.re = id; rednet.send(to, msg, PROTO) end
local function handle(from, m)
  if type(m) ~= "table" then return end
  local n = tonumber(m.n)
  if m.t == "status" and n then
    turtles[n] = m; m.at = os.clock(); m.from = from
  elseif m.t == "lock" and n then
    local l = locks[m.dock]
    if not l or l.n == n or os.clock() - l.at > 180 then
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
    -- which chunks have a helper turtle, and who is mining each chunk's bottom (heard from in the last 10 min)
    local helpers, bottom = {}, {}
    for tn, t in pairs(turtles) do
      if os.clock() - t.at < 600 and tonumber(t.chunk) then
        if t.helper then helpers[t.chunk] = true end
        if t.band == 3 and (not bottom[t.chunk] or tn < bottom[t.chunk]) then bottom[t.chunk] = tn end
      end
    end
    reply(from, { t = "needs", needs = needs, junk = CFG.junk, fuelLow = false, helpers = helpers, bottom = bottom }, m.id)
  elseif m.t == "found" and m.name then
    local line = m.name .. " at " .. m.x .. " " .. m.y .. " " .. m.z .. " (turtle " .. tostring(n) .. ")"
    for _, l in ipairs(found) do if l == line then return end end
    found[#found + 1] = line
    local f = fs.open("mine_ores.txt", "a"); f.writeLine(line); f.close()
  end
end

local recalled = false
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
    local tag = (n < 10 and " " or "") .. n .. (t.helper and "b" or " ") .. " "
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
  term.setTextColour(colors.white)
  local busy = {}
  for d, l in pairs(locks) do busy[#busy + 1] = d .. "=" .. l.n end
  print("Chest turns: " .. (#busy > 0 and table.concat(busy, " ") or "free"))
  print("Fuel chest: " .. (fuelCoal and (fuelCoal .. " coal" .. (fuelCoal < 64 and "  (low)" or "")) or
    ("not found (" .. (CFG.exclude[1] or "none set") .. ")")))
  term.setTextColour(colors.white)
  print("Chests: " .. chestCount.iron .. " iron (ores), " .. chestCount.copper .. " copper (junk)" ..
    (moved > 0 and ("  moved " .. moved .. " to the right kind") or ""))
  if chestCount.iron == 0 then term.setTextColour(colors.red); print("No iron chests found - right-click their modems?") end
  if #found > 0 then term.setTextColour(colors.orange); print("Too hard to mine: " .. #found .. " spots (mine_ores.txt)") end
  term.setTextColour(colors.lightGray)
  print("R recall G work U update  #+Enter items" .. (typed ~= "" and ("  [" .. typed .. "]") or ""))
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
parallel.waitForAny(net, screen)
