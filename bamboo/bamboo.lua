-- ============================================================
--  BAMBOO FARM  -  Advanced Crafty Mining Turtle (pickaxe/axe + crafting table)
--  3 turtles share one field, each takes a strip (west / middle / east).
--  A turtle flies at its own height over its strip, goes down each bamboo
--  stalk cutting from the top, and always leaves the bottom piece so it
--  grows back. Every 9 bamboo become a Bamboo Block (crafted on board) and
--  go into bamboo chest 1 (chest 2 once 1 is full). Fuel comes from the
--  fuel chest. Bamboo leftovers under 9 are burned as fuel.
--  Setup: put the turtle on TOP of the fuel chest, turn it on, type its
--  number. It checks which way it faces by looking for the bamboo chests
--  (at known spots 2 blocks away) and, on its first lap, maps where the
--  bamboo is.
-- ============================================================

local CONF = {
  ground = 66,                                   -- y of the chests and of the bottom bamboo piece
  fuel = { x = 1320, z = -22299 },               -- the fuel chest (exact: Bryan stood on each chest)
  bamboo = { { x = 1318, z = -22300 }, { x = 1318, z = -22298 } },   -- bamboo chests 1 and 2 (exact)
  field = { x1 = 1313, x2 = 1326, z1 = -22336, z2 = -22295 },        -- corners (from Bryan, Nov 2026)
  margin = 0,                                    -- extra blocks to check around the field (0: corners are measured;
                                                 -- going past them can leave the force-loaded chunks)
  laneUp = 18,                                   -- turtle n flies at ground + laneUp + 2*(n-1) (bamboo tops out at +15)
  carry = 560,                                   -- go and drop off at this much bamboo (a full craft is 576)
  fuelLow = 1500, fuelTarget = 6000,
  pause = 0,                                     -- seconds to wait between laps (0 = start the next lap straight away)
  remap = 20,                                    -- every this many laps, re-check spots marked "no bamboo" (replanted?)
}

local POSFILE, JOBFILE = "bamboo_pos.txt", "bamboo_job.txt"
local DX, DZ = { 0, 1, 0, -1 }, { -1, 0, 1, 0 }              -- facing 0=N 1=E 2=S 3=W
local G = CONF.ground
local GRID = { [1] = true, [2] = true, [3] = true, [5] = true, [6] = true, [7] = true, [9] = true, [10] = true, [11] = true }

local function readT(f)
  if not fs.exists(f) then return nil end
  local h = fs.open(f, "r"); local ok, t = pcall(textutils.unserialize, h.readAll()); h.close()
  return ok and type(t) == "table" and t or nil
end
local function writeT(f, t) local h = fs.open(f, "w"); h.write(textutils.serialize(t)); h.close() end

local P = readT(POSFILE)                                       -- x y z and facing
if P and P.pend then                                           -- the server stopped in the middle of a move
  if turtle.getFuelLevel() < P.pend.fuel then P.x, P.y, P.z = P.pend.x, P.pend.y, P.pend.z end
  P.pend = nil
end
local J = readT(JOBFILE)                                       -- turtle number, chests, lap, map
local function savePos() writeT(POSFILE, P) end
local function saveJob() writeT(JOBFILE, J) end

local isTurtle = function(n) return tostring(n):find("computercraft:turtle", 1, true) ~= nil end
local isBamboo = function(n) return n == "minecraft:bamboo" or n == "minecraft:bamboo_sapling" end
local isChest = function(n) n = tostring(n); return n:find("chest", 1, true) ~= nil or n:find("barrel", 1, true) ~= nil end
local isFuelItem = function(n) n = tostring(n); return n:find("coal", 1, true) ~= nil and not n:find("ore", 1, true) end

-- ---------------------------------------------------------- screen
local STATUS, LAST = "starting", ""
local BLOCKED = nil
local function show()
  term.clear(); term.setCursorPos(1, 1)
  print("BAMBOO FARM  turtle " .. tostring(J and J.n or "?"))
  if J and J.cols then
    print("Lap " .. (J.lap or 1) .. "   column " .. math.min(J.idx or 1, #J.cols) .. "/" .. #J.cols)
  end
  print("Fuel " .. turtle.getFuelLevel())
  print("Blocks made " .. tostring(J and J.made or 0))
  if P then print("I think I'm at " .. P.x .. " " .. P.y .. " " .. P.z .. " facing " .. ({ "N", "E", "S", "W" })[(P.f or 0) % 4 + 1]) end
  print("")
  print(STATUS)
  if LAST ~= "" then print(LAST) end
end
local function status(s, last) STATUS = s; if last then LAST = last end; show() end
-- what we were doing, kept on disk: after a restart we can say what we were in the middle of
local LOGFILE = "bamboo_log.txt"
local function phase(p) local h = fs.open(LOGFILE, "w"); h.write("phase " .. p); h.close() end
local function lastStop()
  if not fs.exists(LOGFILE) then return nil end
  local h = fs.open(LOGFILE, "r"); local t = h.readAll() or ""; h.close()
  if t:find("^error ") then return "Last stop: " .. t:sub(7) end
  if t:find("^phase ") then return "Last stop: restarted while " .. t:sub(7) .. " (no error: server restart or chunk unloaded?)" end
  return nil
end
local LASTSTOP = lastStop()

-- ---------------------------------------------------------- fuel chest (we're sitting on it)
local function onFuelChest()
  local ok, b = turtle.inspectDown()
  if not (ok and isChest(b.name)) then return false end
  local okL, l = pcall(peripheral.call, "bottom", "list")
  if not (okL and type(l) == "table") then return false end
  for _, it in pairs(l) do if isFuelItem(it.name) then return true end end
  return false
end
local function fillUp()
  for _ = 1, 40 do
    if turtle.getFuelLevel() >= CONF.fuelTarget then break end
    local s
    for i = 1, 16 do if turtle.getItemCount(i) == 0 then s = i; break end end
    if not s then break end
    turtle.select(s)
    if not turtle.suckDown() then break end
    while turtle.getFuelLevel() < CONF.fuelTarget and turtle.refuel(1) do end
    if turtle.getItemCount(s) > 0 then turtle.dropDown() end
  end
  turtle.select(1)
end

-- ---------------------------------------------------------- moving
local function lane() return G + CONF.laneUp + 2 * ((J and J.n or 1) - 1) end

-- one step forward/up/down. Bamboo in the way is cut (and kept); another turtle or a mob is waited for.
-- Returns false (and what is in the way) for anything else, or if we waited longer than `patience` tries.
local function step(kind, patience)
  patience = patience or 60
  local mv, ins, dig = turtle.forward, turtle.inspect, turtle.dig
  local nx, ny, nz = P.x + DX[P.f + 1], P.y, P.z + DZ[P.f + 1]
  if kind == "u" then mv, ins, dig, nx, ny, nz = turtle.up, turtle.inspectUp, turtle.digUp, P.x, P.y + 1, P.z
  elseif kind == "d" then mv, ins, dig, nx, ny, nz = turtle.down, turtle.inspectDown, turtle.digDown, P.x, P.y - 1, P.z end
  local waited = 0
  while true do
    if turtle.getFuelLevel() == 0 then
      if onFuelChest() then fillUp()
      else
        status("OUT OF FUEL - put coal or charcoal in me"); sleep(10)
        for s = 1, 16 do turtle.select(s); turtle.refuel() end
      end
    else
      P.pend = { x = nx, y = ny, z = nz, fuel = turtle.getFuelLevel() }; savePos()
      if mv() then
        P.x, P.y, P.z, P.pend = nx, ny, nz, nil; savePos()
        return true
      end
      P.pend = nil; savePos()
      local ok, b = ins()
      if ok and isBamboo(b.name) then
        dig()
      elseif ok and not isTurtle(b.name) then
        BLOCKED = tostring(b.name):gsub("^minecraft:", "") .. " at " .. nx .. " " .. ny .. " " .. nz
        return false, b.name
      else                                                     -- a turtle, or a mob / player / item
        waited = waited + 1
        if waited > patience then return false, ok and "turtle" or "something" end
        sleep(0.5 + math.random() * 1.5)
      end
    end
  end
end
local function turnTo(f)
  f = f % 4
  if (f - P.f) % 4 == 3 then turtle.turnLeft(); P.f = (P.f + 3) % 4; savePos() end
  while P.f ~= f do turtle.turnRight(); P.f = (P.f + 1) % 4; savePos() end
end
local function vert(y, patience)
  while P.y < y do if not step("u", patience) then return false end end
  while P.y > y do if not step("d", patience) then return false end end
  return true
end
-- something solid in the way (a cliff, a tree)? go up over it, up to 30 blocks above our height
local function forward(patience)
  while true do
    local ok, why = step("f", patience)
    if ok then return true end
    if why == "turtle" or why == "something" then return false end
    if P.y >= lane() + 30 or not step("u", patience) then return false end
  end
end
local function goXZ(x, z, patience)
  if P.x ~= x then
    turnTo(x > P.x and 1 or 3)
    while P.x ~= x do if not forward(patience) then return false end end
  end
  if P.z ~= z then
    turnTo(z > P.z and 2 or 0)
    while P.z ~= z do if not forward(patience) then return false end end
  end
  return true
end
-- up to our own height, across, then down
local function goTo(x, y, z, patience)
  local L = lane()
  if P.y ~= L or P.x ~= x or P.z ~= z then
    vert(L, patience)                                          -- (may stop short, e.g. still above something we climbed)
    if not goXZ(x, z, patience) then return false end
  end
  return vert(y, patience)
end

-- ---------------------------------------------------------- inventory
local function count(name)
  local n = 0
  for s = 1, 16 do local d = turtle.getItemDetail(s); if d and d.name == name then n = n + d.count end end
  return n
end
local function emptySlot() for s = 1, 16 do if turtle.getItemCount(s) == 0 then return s end end end

-- lay the bamboo out 3x3 (k in each grid slot, nothing anywhere else) and craft k Bamboo Blocks
local function craftBlocks()
  local B = count("minecraft:bamboo")
  local k = math.min(64, math.floor(B / 9))
  local r = B - 9 * k
  if r > 0 then                                                -- the odd ones out: burn them (they're fuel)
    for s = 1, 16 do
      local d = turtle.getItemDetail(s)
      if r > 0 and d and d.name == "minecraft:bamboo" then
        local m = math.min(r, d.count)
        turtle.select(s)
        if not turtle.refuel(m) then turtle.dropDown(m) end
        r = r - m
      end
    end
  end
  if k == 0 then return 0 end
  local function want(s) return GRID[s] and k or 0 end
  for _ = 1, 64 do
    local src, dst
    for s = 1, 16 do
      local c = turtle.getItemCount(s)
      if not src and c > want(s) then src = s end
      if not dst and c < want(s) then dst = s end
    end
    if not src or not dst then break end
    turtle.select(src)
    turtle.transferTo(dst, math.min(turtle.getItemCount(src) - want(src), want(dst) - turtle.getItemCount(dst)))
  end
  turtle.select(1)
  if not turtle.craft() then return 0 end
  return k
end

-- put everything we carry (except bamboo) into the chest below. false = chest full
local function dropAllBut(keep)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name ~= keep then
      turtle.select(s)
      if not turtle.dropDown() then turtle.select(1); return false end
    end
  end
  turtle.select(1)
  return true
end

-- ---------------------------------------------------------- the chests (sat on from above, one turtle at a time)
-- something is wrong that flying about won't fix: stay put and say so (also after a restart)
local function giveUp(msg)
  J.lost = msg; saveJob()
  local h = fs.open("bamboo_log.txt", "w"); h.write("error " .. msg); h.close()
  while true do
    status("STOPPED: " .. msg, "Put me back on the fuel chest to start over.")
    sleep(60)
  end
end

local function atChest(c, fn)
  status("Going to the " .. c.what)
  local tries = 0
  while not goTo(c.x, lane(), c.z) do
    tries = tries + 1
    if tries >= 5 then giveUp("I can't get to the " .. c.what .. ": blocked by " .. tostring(BLOCKED or "another turtle")) end
    sleep(10)
  end
  if not vert(G + 1, 2400) then vert(lane()); return false end   -- wait for a turtle that's using it
  local ok, b = turtle.inspectDown()
  local res = false
  if ok and isChest(b.name) then res = fn()
  else
    giveUp("I'm lost: no chest under me where the " .. c.what .. " should be (" .. c.x .. " " .. G .. " " .. c.z ..
      "). Under me: " .. (ok and tostring(b.name) or "air"))
  end
  -- off the chest: straight up, or step aside first if a turtle is waiting on top of us
  if not vert(lane(), 6) then
    for f = 0, 3 do
      turnTo(f)
      if not turtle.detect() and step("f", 2) then break end
    end
    vert(lane(), 600)
  end
  return res
end

local function refuel()
  atChest(J.chests.fuel, function()
    while true do
      for _ = 1, 20 do
        if turtle.getFuelLevel() >= CONF.fuelTarget then break end
        local s = emptySlot()
        if not s then break end
        turtle.select(s)
        if not turtle.suckDown() then break end
        while turtle.getFuelLevel() < CONF.fuelTarget and turtle.getItemCount(s) > 0 do
          if not turtle.refuel(1) then break end
        end
        if turtle.getItemCount(s) > 0 then turtle.dropDown() end
        if not isFuelItem((turtle.getItemDetail(s) or {}).name) and turtle.getItemCount(s) > 0 then break end
      end
      turtle.select(1)
      if turtle.getFuelLevel() >= CONF.fuelLow then return true end
      status("The fuel chest is empty!", "Put coal or charcoal in it. Waiting on it.")
      sleep(30)                                                -- wait right here: flying back and forth burns fuel
    end
  end)
end

local function dropOff()
  for tries = 1, 100000 do
    local done = false
    local c = J.chests.bamboo[J.active or 1]
    atChest(c, function()
      if tries > #J.chests.bamboo then                         -- both were full last time round: wait here
        status("Both bamboo chests are full!", "Empty one and I'll carry on.")
        for _ = 1, 30 do                                       -- 15 minutes here before trying the other one
          sleep(30)
          if dropAllBut("minecraft:bamboo") then break end
        end
      end
      if not dropAllBut("minecraft:bamboo") then return end    -- blocks still on board from last time
      while count("minecraft:bamboo") >= 9 do
        local k = craftBlocks()
        if k == 0 then LAST = "Crafting failed (crafting table on me?)"; break end
        J.made = (J.made or 0) + k; saveJob()
        if not dropAllBut("minecraft:bamboo") then return end
      end
      craftBlocks()                                            -- (burns the last few)
      done = dropAllBut(nil)
    end)
    if done then return true end
    J.active = (J.active or 1) % #J.chests.bamboo + 1; saveJob()
    if turtle.getFuelLevel() < CONF.fuelLow then refuel() end  -- never run dry while waiting
  end
end


local function dockTrip(why)
  LAST = why or ""
  dropOff()
  if turtle.getFuelLevel() < CONF.fuelTarget - 500 then refuel() end
end

-- ---------------------------------------------------------- the field
-- our strip: the field (plus margin) split into 3 by x; columns snake south -> north -> south
local function buildColumns(n)
  local F, m = CONF.field, CONF.margin
  local x1, x2 = math.min(F.x1, F.x2) - m, math.max(F.x1, F.x2) + m
  local z1, z2 = math.min(F.z1, F.z2) - m, math.max(F.z1, F.z2) + m
  local w = x2 - x1 + 1
  local base, extra = math.floor(w / 3), w % 3
  local from = x1
  for i = 1, n - 1 do from = from + base + (i <= extra and 1 or 0) end
  local to = from + base + (n <= extra and 1 or 0) - 1
  local cols, flip = {}, false
  for x = from, to do
    if flip then for z = z1, z2 do cols[#cols + 1] = { x, z } end
    else for z = z2, z1, -1 do cols[#cols + 1] = { x, z } end end
    flip = not flip
  end
  return cols
end

-- cut one stalk from the top down, leaving the bottom piece. Returns 1 = bamboo here, 0 = no bamboo here
local function harvest(x, z)
  if not goTo(x, lane(), z) then return nil end
  local found = 0
  while true do
    local ok, b = turtle.inspectDown()
    if ok and isBamboo(b.name) then
      found = 1
      if P.y - 1 <= G then break end                            -- that's the bottom piece: keep it
      turtle.digDown()
    elseif ok then
      break                                                    -- grass, water, a chest, a turtle...
    end
    if P.y - 1 <= G then break end                              -- nothing at the bottom
    if not step("d", 20) then break end
  end
  vert(lane(), 600)
  return found
end


local function work()
  while true do
    J.lap = J.lap or 1
    if J.lap > 1 and CONF.remap > 0 and J.idx == 1 and J.lap % CONF.remap == 0 then
      for i, v in pairs(J.map) do if v == 0 then J.map[i] = nil end end
    end
    for i = J.idx or 1, #J.cols do
      J.idx = i
      local c = J.cols[i]
      if J.map[i] ~= 0 then
        local home = J.chests.fuel
        local need = math.abs(P.x - home.x) + math.abs(P.z - home.z) + 4 * (lane() - G) + 200
        if count("minecraft:bamboo") >= CONF.carry then dockTrip("Dropping off")
        elseif turtle.getFuelLevel() < math.max(need, CONF.fuelLow) then
          dockTrip("Getting fuel")
          while turtle.getFuelLevel() < need do                -- couldn't get there: don't burn the rest flying about
            status("Can't get to the fuel chest!", "Fuel " .. turtle.getFuelLevel() .. ". Trying again in a minute.")
            sleep(60)
            dockTrip("Getting fuel")
          end
        end
        status("Cutting bamboo")
        BLOCKED = nil
        local r = harvest(c[1], c[2])
        if r then J.map[i] = r; J.fails = 0
        elseif BLOCKED then                                    -- a block (overhang, cliff) over this spot: skip it for good
          J.map[i] = 0; LAST = "Skipping " .. c[1] .. " " .. c[2] .. ": " .. BLOCKED
        else
          J.fails = (J.fails or 0) + 1
          if J.fails >= 8 then giveUp("I can't reach my columns: blocked by " .. tostring(BLOCKED or "another turtle")) end
        end
      end
      J.idx = i + 1; saveJob()
    end
    dockTrip("End of lap " .. J.lap)
    J.lap, J.idx = J.lap + 1, 1; saveJob()
    if CONF.pause > 0 then status("Lap done, waiting " .. CONF.pause .. "s"); sleep(CONF.pause) end
  end
end

-- ---------------------------------------------------------- first start
local function setup(keepN)
  term.clear(); term.setCursorPos(1, 1)
  print("BAMBOO FARM setup")
  if LASTSTOP then print(LASTSTOP); print("") end
  if not turtle.craft then error("I need a crafting table on one side (a CRAFTY turtle).", 0) end
  local okB, below = turtle.inspectDown()
  local onFuel = okB and isChest(below.name)
  if onFuel then
    local okL, l = pcall(peripheral.call, "bottom", "list")
    if okL and type(l) == "table" then
      local fuelish = false
      for _, it in pairs(l) do if isFuelItem(it.name) then fuelish = true end end
      if not fuelish then onFuel = false end
    end
  end
  if not onFuel then
    print("Put me on TOP of the fuel chest (with coal or")
    print("charcoal in it) and reboot.")
    print("")
    if not okB then print("Under me: nothing (air).")
    else
      print("Under me: " .. tostring(below.name))
      if not isChest(below.name) then print("That isn't a chest.")
      else
        local okL, l = pcall(peripheral.call, "bottom", "list")
        if not okL or type(l) ~= "table" then print("I can't look inside it: " .. tostring(l))
        else
          local names, n = {}, 0
          for _, it in pairs(l) do n = n + 1; if #names < 4 then names[#names + 1] = it.count .. "x " .. it.name end end
          print(n == 0 and "It's empty." or ("It has: " .. table.concat(names, ", ")))
          print("(It needs coal or charcoal in it.)")
        end
      end
    end
    -- (keep our saved position: if we stopped mid-setup, a reboot can still fly us home)
    error("", 0)
  end
  local n = keepN
  while not (n and n >= 1 and n <= 3 and n == math.floor(n)) do
    write("Turtle number (1 = west strip, 2 = middle, 3 = east)? ")
    n = tonumber(read())
  end
  print("Turtle " .. n)
  J = { n = n, lap = 1, idx = 1, map = {}, made = 0, active = 1, cols = buildColumns(n) }
  os.setComputerLabel("Bamboo " .. n)
  fillUp()
  print("Fuel: " .. turtle.getFuelLevel())
  if turtle.getFuelLevel() < 1000 then
    error("Not enough fuel: put at least 15 coal or charcoal in the fuel chest.", 0)
  end

  -- which way do we face? The chests are at known spots, so: hop over to where bamboo chest 1 and 2
  -- should be (2 blocks away) and look down. Try each direction; only one should have both chests.
  local F, B1, B2 = CONF.fuel, CONF.bamboo[1], CONF.bamboo[2]
  P = { x = F.x, y = G + 1, z = F.z, f = 0 }
  J.n = n
  saveJob(); savePos()                                         -- (if we stop mid-setup we fly back here and start over)
  phase("setting up (checking which way I face)")
  print("Checking which way I'm facing...")
  local H = G + 3                                              -- low hop height, just above the chests
  local function bambooChestBelow()
    local okI, b = turtle.inspectDown()
    if not (okI and isChest(b.name) and P.y == G + 1) then return false end
    local okL, l = pcall(peripheral.call, "bottom", "list")
    if not (okL and type(l) == "table") then return false end
    for _, it in pairs(l) do
      if it.name ~= "minecraft:bamboo" and it.name ~= "minecraft:bamboo_block" then return false end
    end
    return true
  end
  local function chestAt(c)
    vert(H, 60)
    if not goXZ(c.x, c.z, 20) then vert(H, 600); return false end
    vert(G + 1, 60)
    local yes = bambooChestBelow()
    vert(H, 600)
    return yes
  end
  local g = 0
  local function regard(newG)                                  -- where we really are if we started facing newG
    local dx, dz = P.x - F.x, P.z - F.z
    for _ = 1, (newG - g) % 4 do dx, dz = -dz, dx end
    P.x, P.z, P.f = F.x + dx, F.z + dz, (P.f + newG - g) % 4
    g = newG
  end
  vert(H, 60)
  local fits = {}
  for guess = 0, 3 do
    regard(guess)
    if chestAt(B1) and chestAt(B2) then fits[#fits + 1] = guess end
  end
  if #fits ~= 1 then
    print(#fits == 0 and "I couldn't find both bamboo chests." or "Bamboo chests fit more than one way round.")
    print("They should be at " .. B1.x .. " " .. G .. " " .. B1.z .. " and " .. B2.x .. " " .. G .. " " .. B2.z)
    print("and hold nothing but bamboo / bamboo blocks.")
    print("Put me back on the fuel chest to try again.")
    if fs.exists(POSFILE) then fs.delete(POSFILE) end
    error("", 0)
  end
  regard(fits[1])
  J.chests = { fuel = { x = F.x, z = F.z, what = "fuel chest" },
    bamboo = { { x = B1.x, z = B1.z, what = "bamboo chest 1" }, { x = B2.x, z = B2.z, what = "bamboo chest 2" } } }
  saveJob(); savePos()
  print("I started out facing " .. ({ "north", "east", "south", "west" })[fits[1] + 1] .. ". Off to work!")
  sleep(2)
end

-- keep this turtle's startup.lua up to date
local LOADER = [==[
-- BAMBOO launcher: grabs the newest bamboo.lua from GitHub, then runs it (install as "startup.lua").
local REPO = "TensorialRhyme5/Minecraft-CC-Projects"
local ref = "main"
local h0 = http.get("https://api.github.com/repos/" .. REPO .. "/commits/main", { Accept = "application/vnd.github.sha" })
if h0 then local sha = (h0.readAll() or ""):match("^%x+"); h0.close(); if sha and #sha == 40 then ref = sha end end
local h = http.get("https://raw.githubusercontent.com/" .. REPO .. "/" .. ref .. "/bamboo/bamboo.lua" ..
  (ref == "main" and ("?t=" .. os.epoch("utc")) or ""))
if h then
  local code = h.readAll(); h.close()
  if code and #code > 1000 and load(code, "bamboo") then
    local f = fs.open("bamboo.lua", "w"); f.write(code); f.close()
  end
end
while true do
  if fs.exists("bamboo.lua") and shell.run("bamboo.lua") then break end
  print("Bamboo farm stopped. Restarting in 5s (Ctrl+T to stop)...")
  sleep(5)
end
]==]

if _G.__BAMBOO_TEST then return { setup = setup, work = work, J = function() return J end, P = function() return P end } end

if shell and shell.getRunningProgram and fs.exists("startup.lua") then
  local h = fs.open("startup.lua", "r"); local cur = h.readAll(); h.close()
  if cur ~= LOADER and cur:find("BAMBOO launcher", 1, true) then
    local f = fs.open("startup.lua", "w"); f.write(LOADER); f.close()
  end
end

-- stopped in the middle of setup (server restart, chunk unloaded...)? fly back to the fuel chest. Our
-- position is always counted from the fuel chest, so we find it whichever way we turned out to face.
local keepN = J and J.n
if P and not (J and J.chests) and not onFuelChest() then
  print("I stopped in the middle of setting up.")
  print("Flying back to the fuel chest to start over...")
  J = J or { n = 1 }
  goTo(CONF.fuel.x, lane(), CONF.fuel.z, 600)
  vert(G + 1, 600)
  J = (keepN and { n = keepN }) or nil
end
-- started up sitting on the fuel chest (just placed, or picked up and put back)? fuel up and set up again
if onFuelChest() then
  print("I'm on the fuel chest: fuelling up and setting up.")
  fillUp()
  if fs.exists(POSFILE) then fs.delete(POSFILE) end
  if fs.exists(JOBFILE) then fs.delete(JOBFILE) end
  P, J = nil, nil
end
local okMain, errMain = pcall(function()
  if J and J.lost then
  while true do status("STOPPED: " .. J.lost, "Put me back on the fuel chest to start over."); sleep(60) end
end
if not (J and J.chests and P) then setup(keepN) end
  J.cols = buildColumns(J.n)
  phase("working")
  if LASTSTOP then LAST = LASTSTOP end
  show()
  work()
end)
if not okMain then
  local msg = tostring(errMain)
  if msg ~= "" and msg ~= "Terminated" then
    local h = fs.open(LOGFILE, "w"); h.write("error " .. msg); h.close()
  else
    phase("stopped")
  end
  error(errMain, 0)
end
