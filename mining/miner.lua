-- ============================================================
--  MINER  -  CC: Tweaked mining turtle (Mining Ender Turtle)
--  Turtles work in groups: turtle n is in group (n-1)%4+1, so 1/5/9 share
--  chunk 1, 2/6/10 chunk 2 and so on. The mine computer hands out one
--  3-block-thick layer at a time (top to bottom), so the turtles of a
--  chunk never dig the same layer. When a chunk is all handed out the
--  group moves on to its chunk in the next 2x2 south (chunk + 4).
--  Each turtle uses its own corner of the chunk to go up and down,
--  travels at its own height ("lane"), takes turns at the chests and
--  refuels from the fuel chest (charcoal) and sends every coal it mines to storage.
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
-- keep this turtle's startup.lua (the launcher) up to date: it fetches the newest version straight away
local LOADER = [==[
-- MINER launcher: grabs the newest miner.lua from GitHub, then runs it (install as "startup.lua").
-- It asks GitHub for the newest version's id first, so a fresh push is picked up right away
-- (the plain link can be up to 5 minutes behind). Falls back to the plain link if that fails.
local REPO = "TensorialRhyme5/Minecraft-CC-Projects"
local function newest()
  if fs.exists("update_sha.txt") then                        -- handed to us by the mine computer (U key)
    local f = fs.open("update_sha.txt", "r"); local sha = f.readAll() or ""; f.close()
    fs.delete("update_sha.txt")
    sha = sha:match("^%x+")
    if sha and #sha == 40 then return sha end
  end
  local h = http.get("https://api.github.com/repos/" .. REPO .. "/commits/main", { Accept = "application/vnd.github.sha" })
  if h then
    local sha = (h.readAll() or ""):match("^%x+"); h.close()
    if sha and #sha == 40 then return sha end
  end
  return "main"
end
local ref = newest()
local h = http.get("https://raw.githubusercontent.com/" .. REPO .. "/" .. ref .. "/mining/miner.lua" ..
  (ref == "main" and ("?t=" .. os.epoch("utc")) or ""))
if h then
  local code = h.readAll(); h.close()
  if code and #code > 1000 and load(code, "miner") then
    local f = fs.open("miner.lua", "w"); f.write(code); f.close()
  end
end
while true do
  if fs.exists("miner.lua") and shell.run("miner.lua") then break end
  print("Miner stopped. Restarting in 5s (Ctrl+T to stop)...")
  sleep(5)
end
]==]
do
  local cur = ""
  if fs.exists("startup.lua") then local f = fs.open("startup.lua", "r"); cur = f.readAll() or ""; f.close() end
  if cur ~= LOADER and cur:find("miner.lua", 1, true) then                -- (only replace our own launcher)
    local f = fs.open("startup.lua", "w"); f.write(LOADER); f.close()
  end
end
local PROTO = "minenet"
local POSFILE, JOBFILE = "miner_pos.txt", "miner_job.txt"
-- coal, charcoal and their blocks (any mod's) - but not coal ORE
local COAL = setmetatable({}, { __index = function(_, n)
  n = tostring(n); return n:find("coal", 1, true) ~= nil and not n:find("ore", 1, true) end })
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
local LASTFAIL                                  -- what stopped our last move, and where
local BUSY, REBOOT = false, false               -- moving/turning right now / restart as soon as that's done
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
local STEP_PAT                                  -- (how long to wait for a turtle in the way, when not given)
local function step(dir, noDig, patience)
  patience = patience or STEP_PAT
  local tx, ty, tz = ahead(dir)
  local tries = 0
  while true do
    -- the fuel level tells us after a server restart whether this move happened
    P.pend = { x = tx, y = ty, z = tz, fuel = turtle.getFuelLevel() }; savePos()
    BUSY = true
    local moved = MOVE[dir]()
    P.pend = nil
    if moved then P.x, P.y, P.z = tx, ty, tz end
    savePos()
    BUSY = false
    if REBOOT then os.reboot() end
    if moved then ping(); return true end
    tries = tries + 1
    local ok, d = INS[dir]()
    if ok and type(d) == "table" and type(d.name) == "string" and d.name:find("turtle", 1, true) then
      if tries > (patience or 400) then LASTFAIL = "turtle at " .. tx .. " " .. ty .. " " .. tz; return false, "turtle" end
      ping("waiting for another turtle"); sleep(0.4 + math.random())
    elseif ok then
      if noDig or protected(tx, ty, tz) then LASTFAIL = tostring(d and d.name):gsub("^minecraft:", "") .. " at " .. tx .. " " .. ty .. " " .. tz; return false, "blocked" end
      if not DIG[dir]() then
        if INS[dir]() then return false, "unbreakable", d.name end  -- too hard for a diamond pickaxe
      end
    else
      if turtle.getFuelLevel() == 0 then LASTFAIL = "no fuel"; return false, "fuel" end
      ATK[dir]()                                                     -- a mob, or a block still falling
      if tries > 40 then LASTFAIL = "mob/player? at " .. tx .. " " .. ty .. " " .. tz; return false, "stuck" end
      sleep(0.2)
    end
  end
end
local function face(f)
  while P.f ~= f do
    BUSY = true                                        -- (a restart now would lose which way we face)
    if (f - P.f) % 4 == 3 then
      if turtle.turnLeft() then P.f = (P.f + 3) % 4 end
    else
      if turtle.turnRight() then P.f = (P.f + 1) % 4 end
    end
    savePos()
    BUSY = false
    if REBOOT then os.reboot() end
  end
end
-- Two turtles meeting in one column: the one going UP always has right of way, the one going
-- down backs up a block and waits, so they can never block each other for good.
local BLOCKER                                  -- where a turtle that won't move is sitting
local function vert(ty, noDig, maxBack)
  local guard, backoffs = 0, 0
  while P.y ~= ty do
    guard = guard + 1
    if guard > 3000 then return false, "lost" end
    local down = ty < P.y
    local ok, why, what = step(down and "down" or "up", noDig, down and 4 or nil)
    if not ok and why == "turtle" and down then
      backoffs = backoffs + 1
      if backoffs > (maxBack or 60) then                              -- (a turtle that never moves: out of fuel / broken)
        BLOCKER = "turtle at " .. P.x .. " " .. (P.y - 1) .. " " .. P.z
        return false, "turtle"
      end
      if turtle.getFuelLevel() > 200 then step("up", noDig, 4) end
      ping("letting another turtle past", true)
      sleep(2 + math.random() * 4)
    elseif not ok then
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
      if why == "turtle" and P.y > CONF.fuelChest.y + 2 then          -- up in the air: fly over it
        if not step("up", noDig, 30) then return false, why end
      else
      if why ~= "unbreakable" then return false, why end
      note(what)
      if not step("up", noDig) and not step("down", noDig) then return false, why end   -- hop over it
      end
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
    ping("waiting for the " .. name .. " chest" .. (r and "" or " (mine computer not answering)"), true)
    sleep(2)
  end
end
local function unlock(name) if modem then pcall(rednet.broadcast, { t = "unlock", n = info(), dock = name }, PROTO) end end
local function lost(name)                                -- our map is wrong: stop before we do damage
  unlock(name)
  if fs.exists(POSFILE) then fs.delete(POSFILE) end
  JOB.verified = nil; saveJob()
  vert(lane(), true)                                       -- straight up out of the way (up is always open sky)
  print("I'M LOST - I thought I was at the " .. name .. " chest.")
  print("Pick me up, put me on top of the fuel chest, reboot.")
  while true do ping("LOST - pick me up, put me on the fuel chest and reboot", true); sleep(10) end
end
-- never wait for a turn inside a chest's column (the turtle whose turn it is would land on us)
local function inAColumn()
  for _, c in ipairs({ CONF.fuelChest, CONF.drops[1], CONF.drops[2] }) do
    if P.x == c.x and P.z == c.z then return true end
  end
  return false
end
local function offColumns()
  for _ = 1, 20 do
    if not inAColumn() then return true end
    for f = 0, 3 do                                    -- one block sideways, any free way that isn't another column
      local nx, nz = P.x + DX[f + 1], P.z + DZ[f + 1]
      local bad = false
      for _, c in ipairs({ CONF.fuelChest, CONF.drops[1], CONF.drops[2] }) do if nx == c.x and nz == c.z then bad = true end end
      if not bad then face(f); if step("fwd", true, 3) then break end end
    end
    if inAColumn() then sleep(2); step("up", true, 3) end
  end
  return not inAColumn()
end
local function outOfFuel()                             -- too little to keep trying: stay put and ask for help
  while turtle.getFuelLevel() < 100 do
    burnCarried(500)
    if turtle.getFuelLevel() >= 100 then break end
    ping("OUT OF FUEL - put coal in me", true); sleep(15)
  end
end
-- quick: give up (return false) as soon as a stuck turtle blocks this chest, so we can use another one
local function useDock(name, chest, fn, quick)
  local L = lane()
  for _ = 1, 1000 do
    if not vert(L) then return false end
    outOfFuel()
    STEP_PAT = 30
    goTo(chest.x + 3, L, chest.z)                                         -- wait beside the column (or near it,
    STEP_PAT = nil                                                        --  if a stuck turtle is in that spot)
    offColumns()
    lock(name)
    BLOCKER, LASTFAIL = nil, nil
    STEP_PAT = 15
    local okH = goTo(chest.x, L, chest.z)
    STEP_PAT = nil
    if not okH and P.x ~= chest.x then                                    -- a turtle that won't move, right in our way
      BLOCKER = "turtle at " .. (P.x + DX[P.f + 1]) .. " " .. P.y .. " " .. (P.z + DZ[P.f + 1])
    end
    if okH and vert(chest.y + 2, true, 10) or (okH and P.x == chest.x and P.z == chest.z) then
      -- feel for the chest: our height can be a block or two off, the chest tells us where we really are
      for _ = 1, 5 do
        local okI, d = turtle.inspectDown()
        if okI and type(d) == "table" and d.name == "minecraft:chest" then
          if P.y ~= chest.y + 1 then P.y = chest.y + 1; savePos() end
          break
        end
        if okI then break end                                           -- something else below: not our chest
        if not step("down", true, 4) then break end
      end
    end
    if not (P.x == chest.x and P.z == chest.z and P.y == chest.y + 1) and LASTFAIL then BLOCKER = BLOCKER or LASTFAIL end
    local there = P.x == chest.x and P.z == chest.z and P.y == chest.y + 1
    local okI, d = turtle.inspectDown()
    local below = okI and type(d) == "table" and tostring(d.name) or nil
    if there and below ~= "minecraft:chest" then lost(name) end          -- not where we think we are
    if not there and P.x == chest.x and P.z == chest.z and below and below ~= "minecraft:chest"
      and not below:find("turtle", 1, true) and P.y > chest.y + 1 then lost(name) end   -- landed on something else
    if there then fn() end
    vert(L, true)
    unlock(name)
    if there then return true end
    STEP_PAT = 30; goTo(chest.x + 3, L, chest.z); STEP_PAT = nil       -- something was in the way: try again
    offColumns()
    if BLOCKER and quick then
      ping(name .. " blocked: " .. BLOCKER, true)
      return false, "blocked"
    elseif BLOCKER then
      ping(name .. " blocked: " .. BLOCKER, true)
      sleep(30 + math.random() * 30)                                     -- let the others have a go meanwhile
    else
      ping("couldn't get onto " .. name .. " (" .. tostring(LASTFAIL or "?") .. ")", true)
      sleep(5 + math.random() * 10)
    end
  end
  return false
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
-- the fuel chest (charcoal) is only for burning: we take what we need into one empty slot, burn it,
-- and put back what's left. Coal we mine is NOT burned here - it all goes to storage.
local function fuelStop()
  local k
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then k = s; break end end
  if not k then burnCarried(CONF.fuelTarget) end                       -- no room: burn our own coal to make some
  for s = 1, 16 do if not k and turtle.getItemCount(s) == 0 then k = s end end
  if not k then return end
  turtle.select(k)
  local function burnK()
    while turtle.getFuelLevel() < CONF.fuelTarget and turtle.getItemCount(k) > 0 do
      if not turtle.refuel(1) then break end
    end
  end
  local junkTries = 0
  for _ = 1, 40 do                                                     -- top up from the chest
    local needItems = math.ceil((CONF.fuelTarget - turtle.getFuelLevel()) / 80)
    if needItems <= 0 then break end
    turtle.select(k)
    if not turtle.suckDown(math.min(64, needItems)) then break end
    if not turtle.refuel(0) then                                       -- not fuel (dropped in by mistake):
      junkTries = junkTries + 1                                        -- keep it for storage, try the next stack
      k = nil
      for s = 1, 16 do if turtle.getItemCount(s) == 0 then k = s; break end end
      if not k or junkTries > 6 then break end
    else
      burnK()
      if turtle.getItemCount(k) > 0 then break end                     -- (topped up)
    end
  end
  if not k then for s = 1, 16 do if turtle.getItemCount(s) == 0 then k = s; break end end end
  if not k then k = 16 end
  -- fuel chest empty and we can't make it out and back: sit right here until fuel shows up
  local need = costHome() + 2 * (lane() - CONF.bands[#CONF.bands].bottom) + 300
  while turtle.getFuelLevel() < need do
    if coalCount() > 0 then burnCarried(need) end                      -- last resort: coal we're carrying
    if turtle.getFuelLevel() >= need then break end
    ping("waiting for charcoal in the fuel chest", true)
    ask({ t = "lock", dock = "fuel" })                                -- keep our turn while we wait
    sleep(20)
    turtle.select(k)
    if turtle.suckDown(64) then burnK() end
  end
  turtle.select(k)
  if turtle.getItemCount(k) > 0 and turtle.refuel(0) then turtle.dropDown() end   -- unburned fuel goes back
  JOB.carry = nil; saveJob()
  turtle.select(1)
end
local function dropAll()                                               -- everything goes to storage, coal too
  for s = 1, 16 do
    turtle.select(s)
    while turtle.getItemCount(s) > 0 do
      if not turtle.dropDown() then ping("drop-off chest is full - waiting", true); sleep(5) end
    end
  end
  turtle.select(1)
end
local function dockRun(why)
  ping(why or "heading home", true)
  if inQ(P.x, P.z) then tidy(); horiz("z", S.z); horiz("x", S.x) end    -- back along rows already dug
  vert(lane())
  local function refuel()
    while not useDock("fuel", CONF.fuelChest, fuelStop, true) do
      -- fuel chest blocked by a stuck turtle: carry on if we have plenty, otherwise wait for it to be removed
      if turtle.getFuelLevel() > costHome() + 2 * (lane() - CONF.bands[#CONF.bands].bottom) + 300 then break end
      ping("the fuel chest is blocked by a stuck turtle - remove it (" .. tostring(BLOCKER) .. ")", true)
      sleep(60)
    end
  end
  if turtle.getFuelLevel() < 300 then refuel() end                     -- almost empty: fuel first
  local a = dropNo()
  while not (useDock("drop" .. a, CONF.drops[a], dropAll, true) or
             useDock("drop" .. (3 - a), CONF.drops[3 - a], dropAll, true)) do   -- blocked: use the other one
    ping("both drop-off chests are blocked by stuck turtles - remove them", true)
    sleep(60)
  end
  updateNeeds()
  refuel()                                                            -- (pockets empty now: room for charcoal)
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
  -- make sure we really are on the fuel chest (a turtle rebooted halfway through setup is somewhere else)
  local okB, below = turtle.inspectDown()
  local onChest = okB and type(below) == "table" and tostring(below.name):find("chest", 1, true)
  if onChest and peripheral.getType and peripheral.getType("bottom") then
    local okL, l = pcall(peripheral.call, "bottom", "list")
    if okL and type(l) == "table" then
      local fuelish = 0
      for _, it in pairs(l) do if COAL[it.name] then fuelish = fuelish + 1 end end
      if fuelish == 0 and next(l) then onChest = false end              -- (a few stray items in it are fine)
    end
  end
  if not onChest then
    print("")
    print("I'm not sitting on the fuel chest!")
    print("Pick me up, put me on top of the fuel chest")
    print("(" .. CONF.fuelChest.x .. " " .. CONF.fuelChest.y .. " " .. CONF.fuelChest.z .. ") and reboot.")
    if fs.exists(POSFILE) then fs.delete(POSFILE) end
    error("", 0)
  end
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
  if turtle.getFuelLevel() < 1000 then
    print("I need more fuel first: put at least 16 coal")
    print("in me and reboot. (I have " .. turtle.getFuelLevel() .. ", I need 1000.)")
    error("", 0)
  end
  -- find out which way we face. We leave the fuel chest ONCE (on our turn), then from up high try each
  -- guess: fly to where drop-off chest 1 would be and look down. A wrong guess just means we were
  -- somewhere else, so we re-work our position for the next guess instead of flying back.
  local F, D = CONF.fuelChest, CONF.drops[1]
  local L = DOCKY + CONF.laneUp + n
  print("Waiting for my turn at the fuel chest...")
  lock("fuel")
  P = { x = F.x, y = F.y + 1, z = F.z, f = 0 }
  while not vert(L, true) do                                   -- a turtle above us: it'll move
    ping("waiting to get off the fuel chest", true); sleep(5)
    lock("fuel")
  end
  unlock("fuel")
  print("Working out which way I'm facing...")
  local found, g = nil, 0
  local function regard(newG)                                  -- where we really are if we started facing newG
    local dx, dz = P.x - F.x, P.z - F.z
    for _ = 1, (newG - g) % 4 do dx, dz = -dz, dx end
    P.x, P.z, P.f = F.x + dx, F.z + dz, (P.f + newG - g) % 4
    g = newG
  end
  for guess = 0, 3 do
    regard(guess)
    if goTo(D.x, L, D.z, false, true) then
      lock("drop1")
      local ok = vert(D.y + 1, true)
      local okI, d = turtle.inspectDown()
      if ok and okI and type(d) == "table" and d.name == "minecraft:chest" then found = guess end
      vert(L, true)
      unlock("drop1")
      if found then                                            -- double-check with drop-off chest 2
        local D2 = CONF.drops[2]
        found = nil
        if goTo(D2.x, L, D2.z, false, true) then
          lock("drop2")
          local ok2 = vert(D2.y + 1, true)
          local okJ, d2 = turtle.inspectDown()
          if ok2 and okJ and type(d2) == "table" and d2.name == "minecraft:chest" then found = guess end
          vert(L, true)
          unlock("drop2")
        end
      end
      if found then break end
    else
      vert(L, true)
    end
  end
  if not found then
    print("I couldn't find drop-off chest 1 from up high.")
    print("The space above the chests must be open to the sky.")
    print("Pick me up, put me back on the fuel chest, reboot.")
    if fs.exists(POSFILE) then fs.delete(POSFILE) end
    error("", 0)
  end
  JOB.verified = true                                          -- (both drop-off chests were where they should be)
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
  if fin then JOB.layer, JOB.cell = nil, 0 end                         -- (the next layer always starts fresh)
  while true do
    local r = ask({ t = "claim", chunk = CH, chunks = chunks, last = CONF.lastChunk, have = JOB.layer, fin = fin,
      mig = JOB.mig, k = JOB.layer and K or select(2, groupOf(JOB.n)) }, 4)
    if r and r.t == "claim" then
      JOB.mig = nil
      if r.y and ((r.chunk and r.chunk ~= CH) or (r.k and r.k ~= K)) then
        if inQ(P.x, P.z) and P.y < lane() then                         -- leave this chunk/corner the way we came in
          horiz("z", S.z); horiz("x", S.x)
        end
        JOB.chunk = r.chunk or CH; JOB.k = r.k or JOB.k; place()
      end
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
  CH, K = JOB.chunk, JOB.k or select(2, groupOf(JOB.n))
  Q = corner(CH)
  EAST, SOUTH = (K == 1 or K == 2), (K == 1 or K == 3)
  S = { x = EAST and Q.x + 15 or Q.x, z = SOUTH and Q.z + 15 or Q.z }
end
local function mine()
  if not modem then
    print("I need an ender modem to talk to the mine computer."); error("", 0)
  end
  if not JOB.verified then                                             -- once: fly home and make sure our map is right
    dockRun("checking I know where I am")
    JOB.verified = true; saveJob()
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
        -- enough to get down to the layer (if we're not there yet), work a while and come all the way back
        local need = costHome() + 2 * math.abs(P.y - y) + 100
        if turtle.getFuelLevel() < need then burnCarried(need + 600) end
        if turtle.getFuelLevel() < need then dockRun("low on fuel") end
        local okR, whyR = reach(JOB.cell, y)
        if not okR and whyR == "turtle" and inQ(P.x, P.z) and (JOB.blocked or 0) < 6 then
          JOB.blocked = (JOB.blocked or 0) + 1                         -- another turtle in the way: wait, don't skip
          ping("another turtle is in my way - waiting", true)
          sleep(10 + math.random() * 10)
        elseif not okR and (whyR == "unbreakable" or whyR == "turtle") and inQ(P.x, P.z) then   -- (a turtle that never moves: broken)
          JOB.cell = JOB.cell + 1; JOB.blocked = nil; saveJob()        -- a block we can't break: skip that spot
        elseif not okR or not inQ(P.x, P.z) or P.y ~= y then
          ping("can't get to my chunk (" .. tostring(whyR or "?") .. ") - is something in the way?", true)
          sleep(15)
        else
          JOB.blocked = nil
          clearUpDown(y)
          if freeSlots() <= 2 then tidy() end
          if freeSlots() <= 1 then dockRun("inventory full") end
          JOB.cell = JOB.cell + 1; saveJob()
          if JOB.cell % 32 == 0 then                                   -- someone already did this layer? (old turtles report late)
            local r = ask({ t = "check", chunk = CH, y = y }, 2)
            if r and r.gone then JOB.layer, JOB.cell = nil, 0; saveJob(); break end
          end
          ping("chunk " .. CH .. ", y " .. y .. " - layer " .. math.floor(JOB.cell * 100 / 256) .. "% done")
        end
      end
      if JOB.layer == y then fin = y end
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
      if m.cmd == "reboot" then                                        -- U on the mine computer: update
        if type(m.sha) == "string" and #m.sha == 40 then                -- the exact newest version to load
          local f = fs.open("update_sha.txt", "w"); f.write(m.sha); f.close()
        end
        if BUSY then REBOOT = true else os.reboot() end                -- (never in the middle of a move or turn)
      end
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
-- sitting on a wooden chest but our saved position isn't on top of any of our chests: that position is
-- wrong (we were picked up and put back on the fuel chest). Forget it and set up again.
if P then
  local okB, below = turtle.inspectDown()
  if okB and type(below) == "table" and below.name == "minecraft:chest" then
    local onOurs = false
    for _, c in ipairs({ CONF.fuelChest, CONF.drops[1], CONF.drops[2] }) do
      if P.x == c.x and P.y == c.y + 1 and P.z == c.z then onOurs = true end
    end
    if not onOurs then P = nil; if fs.exists(POSFILE) then fs.delete(POSFILE) end end
  end
end
if JOB then place() end
if not JOB or not P then setup(); place() end
print("Miner " .. JOB.n .. ": chunk " .. CH .. " at " .. Q.x .. " " .. Q.z .. ", corner " .. K)
print("Hold Ctrl+T to stop.")
updateNeeds()
if modem then parallel.waitForAny(mine, listen) else mine() end
