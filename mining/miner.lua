-- ============================================================
--  MINER  -  CC: Tweaked mining turtle (Mining Ender Turtle)
--  Quarries its own chunk of a 2x2-chunk area in the mining dimension.
--  Turtles 1-4 each get one chunk. They travel at their own height
--  ("lane") so they never bump into each other, take turns at the
--  drop-off and fuel chests (the mine computer hands out the turns),
--  split every coal they find 50/50 between the fuel chest and storage,
--  keep 1,000 of each junk block and leave the rest behind.
-- ============================================================

local CONF = {
  fuelChest = { x = -95, y = 253, z = -2245 },                        -- the chest blocks themselves;
  drops = { { x = -91, y = 253, z = -2247 }, { x = -91, y = 253, z = -2249 } },  -- turtles sit on top
  quarry = { x = -80, z = -2240 },          -- north-west corner of the 2x2 chunks (chunks -5..-4, -140..-139)
  top = 128, bottom = 65,                   -- phase 1: the best ore band
  laneUp = 6,                               -- turtle n travels at (chest top + laneUp + n)
  protect = { x1 = -107, x2 = -83, z1 = -2257, z2 = -2233, y1 = 240 },  -- the base: never break blocks here
  fuelTarget = 2000,                        -- fill up to this at the fuel chest
  junk = {
    "minecraft:stone", "minecraft:cobblestone", "minecraft:deepslate", "minecraft:cobbled_deepslate",
    "minecraft:tuff", "minecraft:granite", "minecraft:diorite", "minecraft:andesite", "minecraft:calcite",
    "minecraft:dirt", "minecraft:gravel", "minecraft:sand", "minecraft:netherrack", "minecraft:blackstone",
    "minecraft:basalt", "minecraft:smooth_basalt", "minecraft:dripstone_block",
  },
}
local PROTO = "minenet"
local POSFILE, JOBFILE = "miner_pos.txt", "miner_job.txt"
local COAL = { ["minecraft:coal"] = true, ["minecraft:charcoal"] = true }
local DX, DZ = { 0, 1, 0, -1 }, { -1, 0, 1, 0 }                   -- facing 0=N 1=E 2=S 3=W

-- ---------------------------------------------------------- saved state
local function readT(f)
  if not fs.exists(f) then return nil end
  local h = fs.open(f, "r"); local ok, t = pcall(textutils.unserialize, h.readAll()); h.close()
  return ok and type(t) == "table" and t or nil
end
local function writeT(f, t) local h = fs.open(f, "w"); h.write(textutils.serialize(t)); h.close() end

local P = readT(POSFILE)                       -- where we are: x y z and facing
if P and P.pend then                           -- the server stopped in the middle of a move
  if turtle.getFuelLevel() < P.pend.fuel then P.x, P.y, P.z = P.pend.x, P.pend.y, P.pend.z end
  P.pend = nil
end
local JOB = readT(JOBFILE)                     -- which turtle we are and how far along
local CMD = nil                                -- "recall" from the mine computer
local JUNK, ALLOW, FUEL_LOW = {}, {}, false
for _, id in ipairs(CONF.junk) do JUNK[id] = true; ALLOW[id] = 64 end
local noted = {}

local function savePos() writeT(POSFILE, P) end
local function saveJob() writeT(JOBFILE, JOB) end

-- ---------------------------------------------------------- talking to the mine computer
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if modem then rednet.open(peripheral.getName(modem)) end
local lastPing, STATE = -100, "starting"
local function info() return JOB and JOB.n end
local function ping(state, force)
  if state then STATE = state end
  if not modem or (not force and os.clock() - lastPing < 4) then return end
  lastPing = os.clock()
  local free = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then free = free + 1 end end
  pcall(rednet.broadcast, { t = "status", n = info(), state = STATE, x = P and P.x, y = P and P.y, z = P and P.z,
    fuel = turtle.getFuelLevel(), slice = JOB and JOB.slice, cell = JOB and JOB.cell, free = free,
    label = os.getComputerLabel() }, PROTO)
end
local function ask(msg, timeout)
  if not modem then return nil end
  msg.n = info(); msg.id = math.random(1, 2 ^ 30)
  pcall(rednet.broadcast, msg, PROTO)
  local deadline = os.clock() + (timeout or 3)
  while os.clock() < deadline do
    local _, r = rednet.receive(PROTO, math.max(0.05, deadline - os.clock()))
    if type(r) == "table" and r.re == msg.id then return r end
  end
end
local function note(name)
  local k = P.x .. "," .. P.y .. "," .. P.z
  if noted[k] then return end
  noted[k] = true
  if modem then pcall(rednet.broadcast, { t = "found", n = info(), name = name, x = P.x, y = P.y, z = P.z }, PROTO) end
end

-- ---------------------------------------------------------- moving (every step is saved)
local function protected(x, y, z)
  local b = CONF.protect
  return x >= b.x1 and x <= b.x2 and z >= b.z1 and z <= b.z2 and y >= b.y1
end
local MOVE = { fwd = turtle.forward, up = turtle.up, down = turtle.down }
local DIG = { fwd = turtle.dig, up = turtle.digUp, down = turtle.digDown }
local INS = { fwd = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }
local ATK = { fwd = turtle.attack, up = turtle.attackUp, down = turtle.attackDown }
local function ahead(dir)
  if dir == "up" then return P.x, P.y + 1, P.z elseif dir == "down" then return P.x, P.y - 1, P.z end
  return P.x + DX[P.f + 1], P.y, P.z + DZ[P.f + 1]
end
-- one block in a direction. Breaks what's in the way (never inside the base, never another turtle).
local function step(dir, noDig)
  local tx, ty, tz = ahead(dir)
  local tries = 0
  while true do
    -- the fuel level tells us after a server restart whether this move happened
    P.pend = { x = tx, y = ty, z = tz, fuel = turtle.getFuelLevel() }; savePos()
    local moved = MOVE[dir]()
    P.pend = nil
    if moved then P.x, P.y, P.z = tx, ty, tz; savePos(); ping(); return true end
    savePos()
    tries = tries + 1
    local ok, d = INS[dir]()
    if ok and type(d) == "table" and type(d.name) == "string" and d.name:find("turtle", 1, true) then
      if tries > 400 then return false, "turtle" end                 -- another turtle: wait for it to pass
      ping("waiting for another turtle"); sleep(0.4 + math.random())
    elseif ok then
      if noDig or protected(tx, ty, tz) then return false, "blocked" end
      if not DIG[dir]() then
        if INS[dir]() then return false, "unbreakable", d.name end  -- too hard for a diamond pickaxe
      end
    else
      if turtle.getFuelLevel() == 0 then return false, "fuel" end
      ATK[dir]()                                                     -- a mob, or a block still falling
      if tries > 40 then return false, "stuck" end
      sleep(0.2)
    end
  end
end
local function face(f)
  while P.f ~= f do
    if (f - P.f) % 4 == 3 then turtle.turnLeft(); P.f = (P.f + 3) % 4 else turtle.turnRight(); P.f = (P.f + 1) % 4 end
    savePos()
  end
end
local function vert(ty, noDig)
  local guard = 0
  while P.y ~= ty do
    guard = guard + 1
    if guard > 2000 then return false, "lost" end
    local ok, why, what = step(ty > P.y and "up" or "down", noDig)
    if not ok then
      if why ~= "unbreakable" then return false, why end
      note(what)
      local moved = false                                            -- hard block: step around it
      for k = 0, 3 do face((P.f + k) % 4); if step("fwd", noDig) then moved = true; break end end
      if not moved then return false, why end
    end
  end
  return true
end
local function horiz(axis, t, noDig)
  local guard = 0
  while P[axis] ~= t do
    guard = guard + 1
    if guard > 2000 then return false, "lost" end
    if axis == "x" then face(t > P.x and 1 or 3) else face(t > P.z and 2 or 0) end
    local ok, why, what = step("fwd", noDig)
    if not ok then
      if why ~= "unbreakable" then return false, why end
      note(what)
      if not step("up", noDig) and not step("down", noDig) then return false, why end   -- hop over it
    end
  end
  return true
end
local function goTo(x, y, z, yFirst, noDig)
  local why
  for _ = 1, 4 do
    local ok = true
    if yFirst then ok, why = vert(y, noDig) end
    if ok then ok, why = horiz("x", x, noDig) end
    if ok then ok, why = horiz("z", z, noDig) end
    if ok then ok, why = vert(y, noDig) end
    if P.x == x and P.y == y and P.z == z then return true end
    if not ok and why ~= "unbreakable" then return false, why end
  end
  return false, why
end

-- ---------------------------------------------------------- where things are
local DOCKY = CONF.fuelChest.y + 1
local function lane() return DOCKY + CONF.laneUp + (JOB and JOB.n or 1) end
local function corner(n)
  return { x = CONF.quarry.x + ((n - 1) % 2) * 16, z = CONF.quarry.z + math.floor((n - 1) / 2) * 16 }
end
local Q
local function inQ(x, z) return Q and x >= Q.x and x <= Q.x + 15 and z >= Q.z and z <= Q.z + 15 end
local SL = {}                                  -- slice heights: each one clears y-1, y, y+1
do
  local y = CONF.top - 1
  while y - 1 >= CONF.bottom do SL[#SL + 1] = y; y = y - 3 end
  if SL[#SL] - 1 > CONF.bottom then SL[#SL + 1] = CONF.bottom + 1 end
end
local function cellXZ(k)                       -- back-and-forth rows over the chunk
  local r, c = math.floor(k / 16), k % 16
  if r % 2 == 1 then c = 15 - c end
  return Q.x + c, Q.z + r
end
local function dropDock() return CONF.drops[(JOB.n <= 2) and 1 or 2] end

-- ---------------------------------------------------------- inventory + fuel
local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end
local function coalCount()
  local n = 0
  for s = 1, 16 do local d = turtle.getItemDetail(s); if d and COAL[d.name] then n = n + d.count end end
  return n
end
local function burnCarried(target)
  for s = 1, 16 do
    if turtle.getFuelLevel() >= target then break end
    local d = turtle.getItemDetail(s)
    if d and COAL[d.name] then
      turtle.select(s)
      while turtle.getFuelLevel() < target and turtle.getItemCount(s) > 0 do turtle.refuel(1) end
    end
  end
  turtle.select(1)
end
-- leave behind the junk storage already has 1,000 of
local function tidy()
  local have = {}
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and JUNK[d.name] then
      local keep = math.max(0, (ALLOW[d.name] or 0) - (have[d.name] or 0))
      if d.count > keep then turtle.select(s); turtle.dropDown(d.count - keep) end
      have[d.name] = (have[d.name] or 0) + math.min(d.count, keep)
    end
  end
  turtle.select(1)
end
local function costHome()                      -- fuel to get back to the chests from here, plus a margin
  local d = dropDock()
  local up = math.abs(lane() - P.y)
  local across = inQ(P.x, P.z) and (math.abs(P.x - Q.x) + math.abs(P.z - Q.z)) or 0
  return across + up + math.abs(Q.x - d.x) + math.abs(Q.z - d.z) + (lane() - DOCKY) + 150
end

-- ---------------------------------------------------------- the chests (one turtle at a time)
local function lock(name)
  local start = os.clock()
  while true do
    local r = ask({ t = "lock", dock = name })
    if r and r.ok then return true end
    if not r and os.clock() - start > 30 then return false end      -- mine computer not answering: go anyway
    ping("waiting for the " .. name .. " chest", true)
    sleep(2)
  end
end
local function unlock(name) if modem then pcall(rednet.broadcast, { t = "unlock", n = info(), dock = name }, PROTO) end end
local function useDock(name, chest, fn)
  local L = lane()
  if not vert(L) then return false end
  if not goTo(chest.x + 3, L, chest.z) then return false end             -- wait beside the column
  lock(name)
  local ok = goTo(chest.x, L, chest.z) and vert(chest.y + 1, true)
  if ok then fn() end
  vert(L, true)
  unlock(name)
  return ok
end
local function updateNeeds()
  local r = ask({ t = "needs" }, 4)
  if not r then return end
  if type(r.junk) == "table" then JUNK = {}; for _, id in ipairs(r.junk) do JUNK[id] = true end end
  if type(r.needs) == "table" then
    ALLOW = {}
    for id, need in pairs(r.needs) do ALLOW[id] = math.ceil(need / 4) end          -- split between 4 turtles
  end
  FUEL_LOW = r.fuelLow == true
end
local function fuelStop()
  -- every coal goes into the fuel chest, then we take back what we burn plus half of it for storage
  -- (that half rides along and goes into the drop-off chest next time)
  local c = coalCount()
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and COAL[d.name] then turtle.select(s); turtle.dropDown() end
  end
  turtle.select(1)
  for _ = 1, 40 do                                                     -- top up from the chest
    local needItems = math.ceil((CONF.fuelTarget - turtle.getFuelLevel()) / 80)
    if needItems <= 0 then break end
    for k = 1, 16 do if turtle.getItemCount(k) == 0 then turtle.select(k); break end end
    if not turtle.suckDown(math.min(64, needItems)) then break end
    burnCarried(CONF.fuelTarget)
  end
  for s = 1, 16 do                                                     -- anything not burned goes back
    local d = turtle.getItemDetail(s)
    if d and COAL[d.name] then turtle.select(s); turtle.dropDown() end
  end
  for k = 1, 16 do if turtle.getItemCount(k) == 0 then turtle.select(k); break end end
  local back = FUEL_LOW and 0 or math.floor(c / 2)                    -- your half (none while the chest is low)
  JOB.carry = 0
  while back > 0 do
    local before = coalCount()
    if not turtle.suckDown(math.min(64, back)) then break end
    local got = coalCount() - before
    back = back - got; JOB.carry = JOB.carry + got
  end
  saveJob()
  turtle.select(1)
end
local function dropAll()
  local carry = math.min(JOB.carry or 0, coalCount())                  -- last trip's storage half of the coal
  for s = 1, 16 do
    turtle.select(s)
    local d = turtle.getItemDetail(s)
    if d and COAL[d.name] then
      local n = math.min(carry, d.count)
      while n > 0 do
        local before = turtle.getItemCount(s)
        if not turtle.dropDown(n) then ping("drop-off chest is full - waiting", true); sleep(5) end
        local gone = before - turtle.getItemCount(s)
        n = n - gone; carry = carry - gone
      end
    else
      while turtle.getItemCount(s) > 0 do
        if not turtle.dropDown() then ping("drop-off chest is full - waiting", true); sleep(5) end
      end
    end
  end
  JOB.carry = 0; saveJob()
  turtle.select(1)
end
local function dockRun(why)
  ping(why or "heading home", true)
  if inQ(P.x, P.z) then tidy(); horiz("z", Q.z); horiz("x", Q.x) end    -- back along rows already dug
  vert(lane())
  useDock("drop" .. ((JOB.n <= 2) and 1 or 2), dropDock(), dropAll)
  updateNeeds()
  useDock("fuel", CONF.fuelChest, fuelStop)
end
local function park(final)
  local d = dropDock()
  vert(lane()); goTo(d.x + 3, lane(), d.z)
  while final or CMD == "recall" do
    ping(final or "parked - press G on the mine computer to send me back", true)
    sleep(3)
  end
end

-- ---------------------------------------------------------- first start: who am I, which way am I facing
local function setup()
  term.clear(); term.setCursorPos(1, 1)
  print("MINER setup")
  print("I must be sitting on TOP of the fuel chest")
  print("(" .. CONF.fuelChest.x .. " " .. CONF.fuelChest.y .. " " .. CONF.fuelChest.z .. ").")
  local n
  repeat
    write("Turtle number (1-4)? ")
    n = tonumber(read())
  until n and n >= 1 and n <= 4 and n == math.floor(n)
  JOB = { n = n, slice = 1, cell = 0 }
  os.setComputerLabel("Miner " .. n)
  burnCarried(100000)                                                      -- the starter coal
  if turtle.getFuelLevel() < 300 then
    print("I need fuel first: put some coal in me and reboot.")
    error("", 0)
  end
  -- find out which way we face: try each guess and look for drop-off chest 1 where it should be
  local F, D = CONF.fuelChest, CONF.drops[1]
  print("Working out which way I'm facing...")
  local found
  for guess = 0, 3 do
    P = { x = F.x, y = F.y + 1, z = F.z, f = guess }
    local L = DOCKY + CONF.laneUp + n
    local ok = vert(L, true) and goTo(D.x, L, D.z, false, true) and vert(D.y + 1, true)
    local okI, d = turtle.inspectDown()
    if ok and okI and type(d) == "table" and d.name and d.name:find("chest", 1, true) then found = guess; break end
    vert(L, true); goTo(F.x, L, F.z, false, true)
    if not vert(F.y + 1, true) then print("I got stuck on the way back. Put me back on the fuel chest and reboot."); error("", 0) end
    face(guess)                                                -- turn back the way we started
  end
  if not found then
    print("I couldn't find drop-off chest 1 from up high.")
    print("The space above the chests must be open to the sky.")
    local dirs = { n = 0, e = 1, s = 2, w = 3 }
    local f
    repeat write("Which way does my FRONT face (n/e/s/w)? "); f = dirs[(read() or ""):sub(1, 1):lower()] until f
    P = { x = F.x, y = F.y + 1, z = F.z, f = f }
  end
  savePos(); saveJob()
  print("Ready: turtle " .. n .. ", facing " .. ({ "north", "east", "south", "west" })[P.f + 1])
end

-- ---------------------------------------------------------- mining
local function reach(k, y)
  if not inQ(P.x, P.z) then vert(lane()); goTo(Q.x, lane(), Q.z) end
  if P.y ~= y then goTo(Q.x, P.y, Q.z); vert(y) end
  local x, z = cellXZ(k)
  return goTo(x, y, z)
end
local function clearUpDown(y)
  if y + 1 <= CONF.top then
    for _ = 1, 20 do                                                       -- gravel/sand keep falling
      if not turtle.detectUp() then break end
      local ok, d = turtle.inspectUp()
      if ok and d.name:find("turtle", 1, true) then break end
      if not turtle.digUp() then note(d.name); break end
    end
  end
  if y - 1 >= CONF.bottom and turtle.detectDown() then
    local ok, d = turtle.inspectDown()
    if not (ok and d.name:find("turtle", 1, true)) and not turtle.digDown() then note(d.name) end
  end
end
local function mine()
  Q = corner(JOB.n)
  while JOB.slice <= #SL do
    if CMD == "recall" then dockRun("recalled"); park() end
    local y = SL[JOB.slice]
    if turtle.getFuelLevel() < costHome() then burnCarried(costHome() + 600) end
    if turtle.getFuelLevel() < costHome() then dockRun("low on fuel") end
    if not reach(JOB.cell, y) or not inQ(P.x, P.z) or P.y ~= y then
      ping("can't get to my chunk - something is in the way (above the chests?)", true)
      sleep(15)
    else
    clearUpDown(y)
    if freeSlots() <= 2 then tidy() end
    if freeSlots() <= 1 then dockRun("inventory full") end
    JOB.cell = JOB.cell + 1
    if JOB.cell > 255 then JOB.cell = 0; JOB.slice = JOB.slice + 1 end
    saveJob()
    ping("mining " .. math.floor(((JOB.slice - 1) * 256 + JOB.cell) * 100 / (#SL * 256)) .. "%")
    end
  end
  dockRun("finished")
  park("DONE - this chunk is mined out")
end

-- ---------------------------------------------------------- start
local function listen()
  while true do
    local _, m = rednet.receive(PROTO)
    if type(m) == "table" and m.t == "cmd" and (m.n == nil or m.n == info()) then CMD = m.cmd end
  end
end
math.randomseed(os.epoch("utc") + os.getComputerID())
if not JOB or not P then setup() end
Q = corner(JOB.n)
print("Miner " .. JOB.n .. ": chunk at " .. Q.x .. " " .. Q.z .. ", " .. #SL .. " layers of 3 from y " .. CONF.top .. " to " .. CONF.bottom)
print("Hold Ctrl+T to stop.")
updateNeeds()
if modem then parallel.waitForAny(mine, listen) else mine() end
