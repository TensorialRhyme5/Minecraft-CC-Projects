-- ============================================================
--  STORAGE CRAFTER  -  runs on a crafty turtle
--  Layout:  [full wired modem] [TURTLE] -> [pickup barrel]
--  The storage computer puts the ingredients in the barrel and
--  tells this turtle the recipe over the wired network. The turtle
--  pulls them out, lays out the 3x3 grid, crafts, and puts the
--  result back in the barrel.
-- ============================================================

local PROTO = "storagecraft"
local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }        -- turtle slots that form the 3x3 grid
local STAGE = { 4, 8, 12, 13, 14, 15, 16 }          -- spare slots used while sorting
local isGrid = {}
for _, s in ipairs(GRID) do isGrid[s] = true end

local function craftFn(n)
  if turtle.craft then return turtle.craft(n) end
  local wb = peripheral.find("workbench")
  if wb and wb.craft then return wb.craft(n) end
  return false, "no crafting table on this turtle"
end

local function log(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
  print(table.concat(t, " "))
end

-- put everything back in the barrel
local function dumpAll()
  local ok = true
  for i = 1, 16 do
    if turtle.getItemCount(i) > 0 then
      turtle.select(i)
      if not turtle.drop() then ok = false end
    end
  end
  turtle.select(1)
  return ok
end

local function freeStage()
  for _, st in ipairs(STAGE) do if turtle.getItemCount(st) == 0 then return st end end
end

-- Move anything that doesn't belong in a grid slot (wrong item, too many, or a slot the recipe
-- leaves empty) out to the spare slots. A pickup can spill into the next slot, so we check often.
local function tidy(cells, k)
  for _, s in ipairs(GRID) do
    local d = turtle.getItemDetail(s)
    if d then
      local extra = 0
      if cells[s] ~= d.name then extra = d.count elseif d.count > k then extra = d.count - k end
      if extra > 0 then
        local st = freeStage()
        if not st then return false end
        turtle.select(s); turtle.transferTo(st, extra)
      end
    end
  end
  return true
end

-- fill grid slots from whatever is sitting in the spare slots
local function distribute(cells, k)
  for _, st in ipairs(STAGE) do
    local d = turtle.getItemDetail(st)
    if d then
      for s, name in pairs(cells) do
        if name == d.name and turtle.getItemCount(st) > 0 then
          local have = turtle.getItemCount(s)
          local cur = turtle.getItemDetail(s)
          if have < k and (not cur or cur.name == name) then
            turtle.select(st); turtle.transferTo(s, k - have)
          end
        end
      end
    end
  end
end

local function satisfied(cells, k)
  for s, name in pairs(cells) do
    local d = turtle.getItemDetail(s)
    if not d or d.name ~= name or d.count ~= k then return false end
  end
  return true
end

-- Pull stacks out of the barrel until every grid slot holds exactly k of the item it needs.
-- cells = { [turtleSlot] = "mod:item" }
local function gather(cells, k)
  for tries = 1, 60 do
    if not tidy(cells, k) then return false, "barrel is too cluttered - empty it a bit" end
    distribute(cells, k)
    if satisfied(cells, k) then return true end
    local st = freeStage()
    if not st then return false, "barrel is too cluttered - empty it a bit" end
    turtle.select(st)
    if not turtle.suck() then return false, "ran out of ingredients in the barrel" end
  end
  return false, "couldn't find all the ingredients in the barrel"
end

local function handleJob(job)
  if type(job) ~= "table" or type(job.cells) ~= "table" or type(job.k) ~= "number" then
    return { type = "done", job = job and job.job, ok = false, err = "bad job" }
  end
  if not dumpAll() then
    return { type = "done", job = job.job, ok = false, err = "barrel is full" }
  end
  local cells = {}
  for s, name in pairs(job.cells) do cells[tonumber(s)] = name end
  local ok, err = gather(cells, job.k)
  -- everything that isn't part of the grid goes back before crafting
  for _, s in ipairs(STAGE) do
    if turtle.getItemCount(s) > 0 then turtle.select(s); turtle.drop() end
  end
  if not ok then
    dumpAll()
    return { type = "done", job = job.job, ok = false, err = err }
  end
  -- craft. Unstackable results (armor, tools) only come out one per call, so keep going
  -- and empty the result slots into the barrel between calls.
  local made, done, why = 0, 0, nil
  local dropped = true
  while done < job.k do
    turtle.select(16)
    local before = 0
    for _, g in ipairs(GRID) do before = before + turtle.getItemCount(g) end
    local ok, err = craftFn(job.k - done)
    if not ok then why = err; break end
    local after = 0
    for _, g in ipairs(GRID) do after = after + turtle.getItemCount(g) end
    local steps = math.max(1, math.floor((before - after) / math.max(1, job.slots or 1) + 0.5))
    done = done + steps
    for _, st in ipairs(STAGE) do                  -- move the results out of the way
      local d = turtle.getItemDetail(st)
      if d then
        if d.name == job.out then made = made + d.count end
        turtle.select(st)
        if not turtle.drop() then dropped = false end
      end
    end
    if after == 0 then break end
  end
  for _, g in ipairs(GRID) do                     -- a last result can land in an emptied grid slot
    local d = turtle.getItemDetail(g)
    if d and d.name == job.out and not job.cells[g] then made = made + d.count end
  end
  dumpAll()
  if made == 0 then
    return { type = "done", job = job.job, ok = false, err = "the game rejected the recipe (" .. tostring(why or "no match") .. ")" }
  end
  return { type = "done", job = job.job, ok = true, made = made, full = not dropped }
end

if _G.__CRAFTER_TEST then return handleJob end

-- ---------------------------------------------------------- main
term.clear(); term.setCursorPos(1, 1)
print("STORAGE CRAFTER")
local opened = false
for _, side in ipairs(rs.getSides()) do
  if peripheral.getType(side) == "modem" then rednet.open(side); opened = true end
end
if not opened then error("No modem touching the turtle. Put a full-block wired modem against it and right-click it.", 0) end
if not turtle.craft and not peripheral.find("workbench") then
  error("This isn't a crafty turtle - craft it together with a crafting table.", 0)
end
rednet.host(PROTO, "crafter_" .. os.getComputerID())
dumpAll()
print("Ready. Waiting for the storage computer...")
print("Barrel goes in FRONT of the turtle.")

while true do
  local from, msg = rednet.receive(PROTO)
  if type(msg) == "table" and msg.type == "ping" then
    rednet.send(from, { type = "pong" }, PROTO)
  elseif type(msg) == "table" and msg.type == "craft" then
    log("Crafting " .. msg.k .. "x " .. tostring(msg.out))
    local okRun, reply = pcall(handleJob, msg)
    if not okRun then
      pcall(dumpAll)
      reply = { type = "done", job = msg.job, ok = false, err = "turtle error: " .. tostring(reply) }
    end
    log(reply.ok and ("  made " .. reply.made) or ("  failed: " .. reply.err))
    rednet.send(from, reply, PROTO)
  end
end
