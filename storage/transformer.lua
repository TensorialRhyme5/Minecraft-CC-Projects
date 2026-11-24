-- ============================================================
--  STORAGE TRANSFORMER  -  runs on any turtle (no crafting table needed)
--  Does AE2 "in-world transform" recipes: throw the ingredients into water and the result
--  pops out (Redstone Crystal = Redstone Block + Fluix Crystal + Glowstone Dust, Fluix Crystal,
--  Certus Quartz Crystal, budding quartz upgrades, Entro...).
--  Layout:  [full wired modem] [TURTLE] -> [pickup barrel]
--                                  |
--                             [WATER SOURCE]   <- one still water source right under the turtle,
--                                                 walled in on all 4 sides so nothing floats away
--  The storage computer puts the ingredients in the barrel and tells this turtle what to throw in.
--  The turtle drops them into the water, waits, picks everything back up and puts it in the barrel.
-- ============================================================

local PROTO = "storagetransform"
-- AE2 only transforms an item after it has been in the water for over 60 ticks (3 s at 20 TPS), and the
-- count restarts if the item is taken out. So never look before that: the first look is at 8 s (room for
-- sinking in and some server lag), and each retry waits longer in case the server is running slow.
local FIRST_WAIT = 8
local MORE_WAIT = 4         -- each retry waits this much longer than the one before
local MAX_WAIT = 75         -- give up on a batch after this long (the storage waits 90 s)

local function log(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
  print(table.concat(t, " "))
end

-- ---------------------------------------------------------- finding the barrel (same as the crafter)
-- The water is below, so the barrel has to be in front, on top, or beside/behind (the turtle turns to face it).
local PICK = { side = nil }
local function suck(n) if PICK.side == "top" then return turtle.suckUp(n) end return turtle.suck(n) end
local function drop(n) if PICK.side == "top" then return turtle.dropUp(n) end return turtle.drop(n) end

local function isInv(side)
  if not peripheral.isPresent(side) then return false end
  if peripheral.hasType then
    local ok, has = pcall(peripheral.hasType, side, "inventory")
    if ok and has then return true end
  end
  local ok, m = pcall(peripheral.getMethods, side)
  if ok and type(m) == "table" then for _, x in ipairs(m) do if x == "pushItems" or x == "list" then return true end end end
  return false
end
local function openModems()
  local any = false
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" then rednet.open(side); any = true end
  end
  return any
end
local function findPickup()
  if PICK.side and isInv(PICK.side) then return PICK.side end
  local function preferred(side)
    local t = peripheral.getType(side) or ""
    return t:find("barrel") or t:find("backpack")
  end
  for pass = 1, 2 do
    for _, side in ipairs({ "front", "top" }) do
      if isInv(side) and (pass == 2 or preferred(side)) then PICK.side = side; return side end
    end
  end
  for _ = 1, 3 do
    turtle.turnRight()
    if rednet.close then pcall(rednet.close) end
    openModems()
    if isInv("front") then PICK.side = "front"; return "front" end
  end
  turtle.turnRight(); if rednet.close then pcall(rednet.close) end; openModems()
  PICK.side = nil
  return nil
end

local function dumpAll()
  local ok = true
  for i = 1, 16 do
    if turtle.getItemCount(i) > 0 then
      turtle.select(i)
      if not drop() then ok = false end
    end
  end
  turtle.select(1)
  return ok
end

local function waterBelow()
  local ok, b = turtle.inspectDown()
  if not ok then return false, "there's no water under the turtle" end
  if b.name ~= "minecraft:water" then return false, "the block under the turtle is " .. tostring(b.name) .. ", not water" end
  if b.state and b.state.level and b.state.level ~= 0 then return false, "the water under the turtle is flowing - it needs a source block" end
  return true
end

local function counts()
  local c = {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then c[d.name] = (c[d.name] or 0) + d.count end
  end
  return c
end
local function freeSlot() for i = 1, 16 do if turtle.getItemCount(i) == 0 then return i end end end

-- pull from the barrel until we hold at least `need[id]` of every ingredient
local function gather(need)
  for _ = 1, 40 do
    local have, done = counts(), true
    for id, n in pairs(need) do if (have[id] or 0) < n then done = false end end
    if done then return true end
    local s = freeSlot()
    if not s then return false, "barrel is too cluttered - empty it a bit" end
    turtle.select(s)
    if not suck() then return false, "ran out of ingredients in the barrel" end
  end
  return false, "couldn't find all the ingredients in the barrel"
end

-- drop exactly `want` of each item into the water below
local function throwIn(want)
  for id, n in pairs(want) do
    local left = n
    for i = 1, 16 do
      if left <= 0 then break end
      local d = turtle.getItemDetail(i)
      if d and d.name == id then
        local k = math.min(left, d.count)
        turtle.select(i)
        if turtle.dropDown(k) then left = left - k end
      end
    end
    if left > 0 then return false end
  end
  turtle.select(1)
  return true
end

-- pick everything up out of the water
local function fishOut()
  for _ = 1, 64 do
    local s = freeSlot()
    if not s then return false end
    turtle.select(s)
    if not turtle.suckDown() then break end
  end
  turtle.select(1)
  return true
end

local function handleJob(job)
  if type(job) ~= "table" or type(job.items) ~= "table" or type(job.out) ~= "string" then
    return { type = "done", job = job and job.job, ok = false, err = "bad job" }
  end
  local okW, whyW = waterBelow()
  if not okW then return { type = "done", job = job.job, ok = false, err = whyW } end
  if not findPickup() then
    return { type = "done", job = job.job, ok = false, err = "the transformer turtle can't find the barrel - it must touch the turtle" }
  end
  if not dumpAll() then return { type = "done", job = job.job, ok = false, err = "barrel is full" } end
  fishOut(); dumpAll()                                   -- anything left in the water from last time
  local need = {}
  for _, x in ipairs(job.items) do need[x.name] = (need[x.name] or 0) + x.n end
  local ok, err = gather(need)
  if not ok then dumpAll(); return { type = "done", job = job.job, ok = false, err = err } end
  -- keep just the ingredients, everything else goes back first (so the water only gets what it should)
  local kept = {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then
      local want = (need[d.name] or 0) - (kept[d.name] or 0)
      if want <= 0 then turtle.select(i); drop()
      else
        if d.count > want then turtle.select(i); drop(d.count - want) end
        kept[d.name] = (kept[d.name] or 0) + math.min(want, d.count)
      end
    end
  end
  if not throwIn(need) then dumpAll(); return { type = "done", job = job.job, ok = false, err = "couldn't drop the ingredients in the water" } end
  -- wait for the transform, then fish it all out. Whole sets still left over go back in for another go.
  local made, waited, expect = 0, 0, (job.sets or 1) * (job.n or 1)
  local wait = FIRST_WAIT
  while true do
    sleep(wait); waited = waited + wait
    wait = wait + MORE_WAIT
    if not fishOut() then break end
    local c = counts()
    made = c[job.out] or 0
    local sets = math.huge
    for id, n in pairs(need) do sets = math.min(sets, math.floor((c[id] or 0) * (job.sets or 1) / n)) end
    if made >= expect or sets == 0 or waited >= MAX_WAIT then break end
    -- keep the result in the turtle, throw the leftovers back
    local again = {}
    for id, n in pairs(need) do again[id] = math.floor(n / (job.sets or 1)) * sets end
    if not throwIn(again) then break end
  end
  fishOut()
  made = counts()[job.out] or 0
  local full = not dumpAll()
  if made == 0 then
    return { type = "done", job = job.job, ok = false, err = "nothing came out of the water (is it walled in, and the right recipe?)" }
  end
  return { type = "done", job = job.job, ok = true, made = made, full = full }
end

if _G.__TRANSFORMER_TEST then return handleJob end

-- ---------------------------------------------------------- main
term.clear(); term.setCursorPos(1, 1)
print("STORAGE TRANSFORMER (AE2 water recipes)")
if not openModems() then error("No modem touching the turtle. Put a full-block wired modem against it and right-click it.", 0) end
rednet.host(PROTO, "transformer_" .. os.getComputerID())
local okW, whyW = waterBelow()
print(okW and "Water below: OK" or ("Problem: " .. whyW))
local where = findPickup()
if where then print("Barrel found: " .. where); fishOut(); dumpAll()
else print("Can't see the barrel yet - it must touch the turtle (front, top or a side).") end
print("Ready. Waiting for the storage computer...")

while true do
  local from, msg = rednet.receive(PROTO)
  if type(msg) == "table" and msg.type == "ping" then
    rednet.send(from, { type = "pong" }, PROTO)
  elseif type(msg) == "table" and msg.type == "transform" then
    log("Making " .. tostring(msg.out) .. " (" .. tostring(msg.sets) .. " sets)")
    local okRun, reply = pcall(handleJob, msg)
    if not okRun then
      pcall(fishOut); pcall(dumpAll)
      reply = { type = "done", job = msg.job, ok = false, err = "turtle error: " .. tostring(reply) }
    end
    log(reply.ok and ("  made " .. reply.made) or ("  failed: " .. reply.err))
    rednet.send(from, reply, PROTO)
  end
end
