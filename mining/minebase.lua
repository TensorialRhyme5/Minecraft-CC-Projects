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
    for _, id in ipairs(CFG.junk) do needs[id] = math.max(0, CFG.keep - (counts[id] or 0)) end
    reply(from, { t = "needs", needs = needs, junk = CFG.junk, fuelLow = false }, m.id)   -- always split coal 50/50
  elseif m.t == "found" and m.name then
    local line = m.name .. " at " .. m.x .. " " .. m.y .. " " .. m.z .. " (turtle " .. tostring(n) .. ")"
    for _, l in ipairs(found) do if l == line then return end end
    found[#found + 1] = line
    local f = fs.open("mine_ores.txt", "a"); f.writeLine(line); f.close()
  end
end

local recalled = false
local function draw()
  term.setBackgroundColour(colors.black); term.clear(); term.setCursorPos(1, 1)
  term.setTextColour(colors.yellow); print("MINE TURTLES" .. (recalled and "   (RECALLED)" or ""))
  term.setTextColour(colors.white)
  for n = 1, 4 do
    local t = turtles[n]
    if not t then
      term.setTextColour(colors.gray); print(n .. ": not heard from yet")
    else
      local age = os.clock() - t.at
      term.setTextColour(age > 60 and colors.red or colors.lime)
      print(n .. ": " .. tostring(t.state):sub(1, 40))
      term.setTextColour(colors.lightGray)
      print("   y " .. tostring(t.y) .. "  fuel " .. tostring(t.fuel) .. "  free slots " .. tostring(t.free) ..
        (age > 60 and ("  (silent " .. math.floor(age) .. "s)") or ""))
    end
  end
  term.setTextColour(colors.white)
  local busy = {}
  for d, l in pairs(locks) do busy[#busy + 1] = d .. "=" .. l.n end
  print("Chest turns: " .. (#busy > 0 and table.concat(busy, " ") or "free"))
  print("Fuel chest: " .. (fuelCoal and (fuelCoal .. " coal" .. (fuelCoal < 64 and "  (low)" or "")) or
    ("not found (" .. (CFG.exclude[1] or "none set") .. ")")))
  if #found > 0 then term.setTextColour(colors.orange); print("Too hard to mine: " .. #found .. " spots (mine_ores.txt)") end
  term.setTextColour(colors.lightGray)
  print("R = recall all  G = back to work  U = update turtles")
end

local function net()
  while true do
    local from, m = rednet.receive(PROTO)
    handle(from, m)
  end
end
local function screen()
  while true do
    recount(); draw()
    local t = os.startTimer(1)
    repeat
      local ev, p = os.pullEvent()
      if ev == "char" and (p == "r" or p == "R") then
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
