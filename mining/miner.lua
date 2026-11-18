-- ============================================================
--  MINER  -  CC: Tweaked mining turtle (Mining Ender Turtle)
--  Turtles work in groups: turtle n is in group (n-1)%4+1, so 1/5/9 share
--  chunk 1, 2/6/10 chunk 2 and so on. The mine computer hands out one
--  3-block-thick layer at a time (top to bottom), so the turtles of a
--  chunk never dig the same layer. When a chunk is all handed out the
--  group moves on to its chunk in the next 2x2 south (chunk + 4).
--  Each turtle uses its own corner of the chunk to go up and down,
--  travels at its own height ("lane"), takes turns at the chests and
--  splits every coal 50/50 between the fuel chest and storage.
-- ============================================================

local CONF = {
  fuelChest = { x = -95, y = 253, z = -2245 },                        -- the chest blocks themselves;
  drops = { { x = -91, y = 253, z = -2247 }, { x = -91, y = 253, z = -2249 } },  -- turtles sit on top
  quarry = { x = -96, z = -2240 },          -- north-west corner of the 2x2 chunks south of the base (chunks -6..-5, -140..-139)
  -- the mining dimension is flat layers: grass 252, dirt 248-251, stone 129-247, deepslate 65-128,
  -- netherrack 1-64, end stone -63..0, bedrock -64. Each band is mined top-down, one after the other.
  bands = { { top = 128, bottom = 65 }, { top = 252, bottom = 129 }, { top = 64, bottom = -63 } },
  lastChunk = 8,                            -- chunks 1-4: the first 2x2, 5-8: the 2x2 south of it
  laneUp = 6,                               -- turtle n travels at (chest top + laneUp + n)
  protect = { x1 = -96, x2 = -81, z1 = -2256, z2 = -2241, y1 = 240 },   -- the base chunk: never break blocks here
  fuelTarget = 3000,                        -- fill up to this at the fuel chest (the bottom is a long way down)
  junk = {
    "minecraft:stone", "minecraft:cobblestone", "minecraft:deepslate", "minecraft:cobbled_deepslate",
    "minecraft:tuff", "minecraft:granite", "minecraft:diorite", "minecraft:andesite", "minecraft:calcite",
    "minecraft:dirt", "minecraft:gravel", "minecraft:sand", "minecraft:netherrack", "minecraft:blackstone",
    "minecraft:basalt", "minecraft:smooth_basalt", "minecraft:dripstone_block", "minecraft:end_stone",
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
local CH, K = 1, 0                             -- our chunk, and which corner of it is ours (0-3)
local JUNK, ALLOW, FUEL_LOW = {}, {}, false
for _, id in ipairs(CONF.junk) do JUNK[id] = true; ALLOW[id] = 1e9 end   -- (no junk cap: keep everything)
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
  local free, inv, at = 0, {}, {}
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if not d then free = free + 1
    elseif at[d.name] then inv[at[d.name]].c = inv[at[d.name]].c + d.count
    else inv[#inv + 1] = { id = d.name, c = d.count }; at[d.name] = #inv end
  end
  pcall(rednet.broadcast, { t = "status", n = info(), state = STATE, x = P and P.x, y = P and P.y, z = P and P.z,
    fuel = turtle.getFuelLevel(), slice = JOB and JOB.slice, cell = JOB and JOB.cell, free = free, inv = inv,
    layer = JOB and JOB.layer, chunk = CH, k = K,
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
local HARD = false                             -- did the last trip run into a block we can't break?
local function note(name)
  HARD = true
  local k = P.x .. "," .. P.y .. "," .. P.z
  if noted[k] then return end
  noted[k] = true
  if modem then pcall(rednet.broadcast, { t = "found", n = info(), name = name, x = P.x, y = P.y, z = P.z }, PROTO) end
end

-- ---------------------------------------------------------- moving (every step is saved)
local Q                                        -- our chunk's north-west corner (set once we know our number)
local function inQ(x, z) return Q and x >= Q.x and x <= Q.x + 15 and z >= Q.z and z <= Q.z + 15 end
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
      local inside = inQ(P.x, P.z)
      for k = 0, 3 do
        local f = (P.f + k) % 4
        local nx, nz = P.x + DX[f + 1], P.z + DZ[f + 1]
        if (not inside or inQ(nx, nz)) and not protected(nx, P.y, nz) then   -- never step out of our chunk
          face(f); if step("fwd", noDig) then moved = true; break end
        end
      end
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
  HARD = false
  for _ = 1, 4 do
    local ok = true
    if yFirst then ok, why = vert(y, noDig) end
    if ok then ok, why = horiz("x", x, noDig) end
    if ok then ok, why = horiz("z", z, noDig) end
    if ok then ok, why = vert(y, noDig) end
    if P.x == x and P.y == y and P.z == z then return true end
    if not ok and why ~= "unbreakable" then return false, why end
  end
  return false, HARD and "unbreakable" or why
end

-- ---------------------------------------------------------- where things are
local DOCKY = CONF.fuelChest.y + 1
local function lane() return DOCKY + CONF.laneUp + (JOB and JOB.n or 1) end
-- turtle number -> group (its first chunk) and corner: 1-4 corner 0, 5-8 corner 1, 9-12 corner 2, 13-16 corner 3
local function groupOf(n) return (n - 1) % 4 + 1, math.floor((n - 1) / 4) % 4 end
local function oldChunkOf(n)                   -- how the older code numbered things (for moving old progress over)
  local g, r = math.floor((n - 1) / 8), (n - 1) % 8
  return g * 4 + (r % 4) + 1, r >= 4
end
local function corner(c)                       -- chunks run 2 wide, going south
  return { x = CONF.quarry.x + ((c - 1) % 2) * 16, z = CONF.quarry.z + math.floor((c - 1) / 2) * 16 }
end
local S                                        -- the column we go up and down in (our own corner)
local EAST, SOUTH = false, false               -- which side of the chunk our corner is on
local function slicesOf(b)                     -- slice heights: each one clears y-1, y, y+1
  local list, y = {}, b.top - 1
  while y - 1 >= b.bottom do list[#list + 1] = y; y = y - 3 end
  if list[#list] - 1 > b.bottom then list[#list + 1] = b.bottom + 1 end
  return list
end
-- every layer of the quarry, top first. A layer is mined at height y and clears y-1, y and y+1.
local LAYERS, LAYER = {}, {}
for _, b in ipairs(CONF.bands) do
  for _, y in ipairs(slicesOf(b)) do LAYERS[#LAYERS + 1] = { y = y, top = b.top, bottom = b.bottom }; LAYER[y] = LAYERS[#LAYERS] end
end
table.sort(LAYERS, function(a, b) return a.y > b.y end)
local B = LAYERS[1]                            -- the layer being mined now (top / bottom limits)
local function cellXZ(k)                       -- back-and-forth rows over the chunk, starting at our corner
  local r, c = math.floor(k / 16), k % 16
  if r % 2 == 1 then c = 15 - c end
  return EAST and Q.x + 15 - c or Q.x + c, SOUTH and Q.z + 15 - r or Q.z + r
end
local function dropNo() return ((CH - 1) % 4 < 2) and 1 or 2 end
local function dropDock() return CONF.drops[dropNo()] end

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
  local across = inQ(P.x, P.z) and (math.abs(P.x - S.x) + math.abs(P.z - S.z)) or 0
  return across + up + math.abs(S.x - d.x) + math.abs(S.z - d.z) + (lane() - DOCKY) + 150
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
  -- fuel chest empty and we can't make it out and back: sit right here until coal shows up
  local need = costHome() + 2 * (lane() - CONF.bands[#CONF.bands].bottom) + 300
  while turtle.getFuelLevel() < need do
    ping("waiting for coal in the fuel chest", true)
    ask({ t = "lock", dock = "fuel" })                                -- keep our turn while we wait
    sleep(20)
    for k = 1, 16 do if turtle.getItemCount(k) == 0 then turtle.select(k); break end end
    if turtle.suckDown(64) then burnCarried(CONF.fuelTarget) end
  end
  for s = 1, 16 do                                                     -- anything not burned goes back
    local d = turtle.getItemDetail(s)
    if d and COAL[d.name] then turtle.select(s); turtle.dropDown() end
  end
  for k = 1, 16 do if turtle.getItemCount(k) == 0 then turtle.select(k); break end end
  local back = math.floor(c / 2)                                       -- your half, always
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
  if inQ(P.x, P.z) then tidy(); horiz("z", S.z); horiz("x", S.x) end    -- back along rows already dug
  vert(lane())
  useDock("drop" .. dropNo(), dropDock(), dropAll)
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
    print("Chunk 1: 1 5 9   chunk 2: 2 6 10")
    print("chunk 3: 3 7 11  chunk 4: 4 8 12")
    write("Turtle number (1-16)? ")
    n = tonumber(read())
  until n and n >= 1 and n <= 16 and n == math.floor(n)
  if not (JOB and JOB.n == n) then JOB = { n = n, chunk = (groupOf(n)), cell = 0 } end   -- re-placed: keep its progress
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
  -- (we take a turn at drop-off chest 1 like a normal trip, so we never sit on top of a turtle using it)
  for guess = 0, 3 do
    P = { x = F.x, y = F.y + 1, z = F.z, f = guess }
    local L = DOCKY + CONF.laneUp + n
    local ok = vert(L, true) and goTo(D.x, L, D.z, false, true)
    if ok then
      lock("drop1")
      ok = vert(D.y + 1, true)
    end
    local okI, d = turtle.inspectDown()
    if ok and okI and type(d) == "table" and d.name and d.name:find("chest", 1, true) then found = guess; vert(L, true); unlock("drop1"); break end
    vert(L, true); unlock("drop1"); goTo(F.x, L, F.z, false, true)
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
  if not inQ(P.x, P.z) then vert(lane()); goTo(S.x, lane(), S.z) end
  if P.y ~= y then goTo(S.x, P.y, S.z); vert(y) end
  local x, z = cellXZ(k)
  return goTo(x, y, z)
end
local function clearUpDown(y)
  if y + 1 <= B.top then
    for _ = 1, 20 do                                                       -- gravel/sand keep falling
      if not turtle.detectUp() then break end
      local ok, d = turtle.inspectUp()
      if not ok or type(d) ~= "table" or tostring(d.name):find("turtle", 1, true) then break end
      if not turtle.digUp() then note(d.name); break end
    end
  end
  if y - 1 >= B.bottom and turtle.detectDown() then
    local ok, d = turtle.inspectDown()
    if ok and type(d) == "table" and not tostring(d.name):find("turtle", 1, true) and not turtle.digDown() then note(d.name) end
  end
end
-- ask the mine computer for a layer of our chunk (it remembers which are done / taken).
-- "fin" = the layer we just finished. It looks through our group's chunks (ours, then +4, +8...) and
-- returns the y of our layer, or nil plus "wait" when the rest is still being mined by others.
local place
local function claim(fin)
  local tries = 0
  local chunks = {}
  for c = groupOf(JOB.n), CONF.lastChunk, 4 do chunks[#chunks + 1] = c end
  while true do
    local r = ask({ t = "claim", chunk = CH, chunks = chunks, have = JOB.layer, fin = fin, mig = JOB.mig }, 4)
    if r and r.t == "claim" then
      JOB.mig = nil
      if r.y and r.chunk and r.chunk ~= CH then JOB.chunk = r.chunk; place() end
      if r.y ~= JOB.layer then JOB.layer, JOB.cell = r.y, 0 end
      saveJob()
      return r.y, r.wait
    end
    tries = tries + 1
    ping("waiting for the mine computer to give me a layer", true)
    sleep(math.min(30, 3 + tries))
  end
end
function place()
  CH, K = JOB.chunk, select(2, groupOf(JOB.n))
  Q = corner(CH)
  EAST, SOUTH = (K == 1 or K == 2), (K == 1 or K == 3)
  S = { x = EAST and Q.x + 15 or Q.x, z = SOUTH and Q.z + 15 or Q.z }
end
local function mine()
  if not modem then
    print("I need an ender modem to talk to the mine computer."); error("", 0)
  end
  local fin
  while true do
    local y, wait = claim(fin); fin = nil
    if not y then                                                      -- every layer of our chunks is done or taken
      if not wait then break end
      if not JOB.waiting then dockRun("waiting - the others are finishing the last layers"); JOB.waiting = true end
      park()
      ping("waiting - the others are finishing the last layers", true)
      sleep(60)                                                        -- (a layer frees up if its turtle goes quiet)
    else
      JOB.waiting = nil
      B = LAYER[y] or { y = y, top = y + 1, bottom = y - 1 }
      while JOB.cell <= 255 do
        if CMD == "recall" then dockRun("recalled"); park() end
        if turtle.getFuelLevel() < costHome() then burnCarried(costHome() + 600) end
        if turtle.getFuelLevel() < costHome() then dockRun("low on fuel") end
        local okR, whyR = reach(JOB.cell, y)
        if not okR and (whyR == "unbreakable" or whyR == "turtle") and inQ(P.x, P.z) then   -- (a turtle that won't move: a broken one)
          JOB.cell = JOB.cell + 1; saveJob()                           -- a block we can't break: skip that spot
        elseif not okR or not inQ(P.x, P.z) or P.y ~= y then
          ping("can't get to my chunk (" .. tostring(whyR or "?") .. ") - is something in the way?", true)
          sleep(15)
        else
          clearUpDown(y)
          if freeSlots() <= 2 then tidy() end
          if freeSlots() <= 1 then dockRun("inventory full") end
          JOB.cell = JOB.cell + 1; saveJob()
          ping("chunk " .. CH .. ", y " .. y .. " - layer " .. math.floor(JOB.cell * 100 / 256) .. "% done")
        end
      end
      fin = y
      if inQ(P.x, P.z) then horiz("z", S.z); horiz("x", S.x) end         -- back to our corner along the dug rows
    end
  end
  dockRun("finished")
  park("DONE - all my group's chunks are handed out (last: chunk " .. CH .. ")")
end

-- ---------------------------------------------------------- start
local function listen()
  while true do
    local _, m = rednet.receive(PROTO)
    if type(m) == "table" and m.t == "cmd" and (m.n == nil or m.n == info()) then
      if m.cmd == "reboot" then os.reboot() end                        -- U on the mine computer: update
      CMD = m.cmd
    end
  end
end
math.randomseed(os.epoch("utc") + os.getComputerID())
-- older code: one turtle per chunk going band by band. Work out which layers it already finished.
if JOB and JOB.chunk == nil then
  local oc, helper = oldChunkOf(JOB.n)
  local band, slice = JOB.band or 1, JOB.slice or 1
  local done, cur = {}, nil
  for _, bi in ipairs(helper and { 3 } or { 1, 2, 3 }) do
    for i, y in ipairs(slicesOf(CONF.bands[bi])) do
      if bi < band or (bi == band and i < slice) then done[#done + 1] = y
      elseif bi == band and i == slice then cur = y end
    end
  end
  JOB = { n = JOB.n, chunk = oc, layer = cur, cell = cur and JOB.cell or 0, carry = JOB.carry, mig = { done = done } }
  saveJob()
end
if JOB then place() end
if not JOB or not P then setup(); place() end
print("Miner " .. JOB.n .. ": chunk " .. CH .. " at " .. Q.x .. " " .. Q.z .. ", corner " .. K)
print("Hold Ctrl+T to stop.")
updateNeeds()
if modem then parallel.waitForAny(mine, listen) else mine() end
