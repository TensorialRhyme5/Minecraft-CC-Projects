-- ============================================================
--  BAMBOO FARM SCREEN  -  computer + advanced monitor (made for 4 wide x 3 tall)
--  Reads the farm's chests over wired modems (a full-block wired modem on each
--  chest, cabled to this computer, all right-clicked so they show red):
--  bamboo blocks stored, how fast they come in, and how much fuel is left.
--  The turtles have no modem (both sides are taken), so this screen watches
--  the chests rather than the turtles.
-- ============================================================

local SAVE = "bamboo_screen.txt"
local mon = peripheral.find("monitor")
if not mon then error("No monitor found: put the monitor against this computer.", 0) end
mon.setTextScale(1)
local W, H = mon.getSize()
if W < 30 then mon.setTextScale(0.5); W, H = mon.getSize() end

local function readT() if not fs.exists(SAVE) then return {} end
  local h = fs.open(SAVE, "r"); local ok, t = pcall(textutils.unserialize, h.readAll()); h.close()
  return ok and type(t) == "table" and t or {} end
local function writeT(t) local h = fs.open(SAVE, "w"); h.write(textutils.serialize(t)); h.close() end
local S = readT()
S.hist = S.hist or {}                                          -- { {t=, blocks=}, ... } one per minute, last 2 hours

local function commas(n)
  local s = tostring(math.floor(n)); local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (r:gsub("^,", ""))
end

local function scan()
  local chests = {}
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p and p.list and p.size and not name:find("turtle", 1, true) then
      local ok, l = pcall(p.list)
      local okS, size = pcall(p.size)
      if ok and okS and type(l) == "table" then
        local c = { name = name, blocks = 0, bamboo = 0, fuel = 0, other = 0, used = 0, size = size }
        for _, it in pairs(l) do
          c.used = c.used + 1
          if it.name == "minecraft:bamboo_block" then c.blocks = c.blocks + it.count
          elseif it.name == "minecraft:bamboo" then c.bamboo = c.bamboo + it.count
          elseif it.name:find("coal", 1, true) and not it.name:find("ore", 1, true) then c.fuel = c.fuel + it.count
          else c.other = c.other + it.count end
        end
        chests[#chests + 1] = c
      end
    end
  end
  table.sort(chests, function(a, b) return a.name < b.name end)
  return chests
end

local function bar(y, frac, col)
  local x1, x2 = 2, W - 1
  local fillTo = x1 + math.floor((x2 - x1 + 1) * math.max(0, math.min(1, frac))) - 1
  mon.setCursorPos(x1, y)
  for x = x1, x2 do mon.setBackgroundColor(x <= fillTo and col or colors.gray); mon.write(" ") end
  mon.setBackgroundColor(colors.black)
end
local function line(y, s, fg) mon.setCursorPos(2, y); mon.setTextColor(fg or colors.white); mon.write(s:sub(1, W - 2)) end

local function draw(chests)
  mon.setBackgroundColor(colors.black); mon.clear()
  mon.setCursorPos(1, 1); mon.setBackgroundColor(colors.green); mon.write((" "):rep(W))
  local title = "BAMBOO FARM"
  mon.setCursorPos(math.floor((W - #title) / 2) + 1, 1); mon.setTextColor(colors.black); mon.write(title)
  mon.setBackgroundColor(colors.black)
  local total, fuel, store = 0, 0, {}
  for _, c in ipairs(chests) do
    total = total + c.blocks
    fuel = fuel + c.fuel
    if c.fuel == 0 then store[#store + 1] = c end              -- a bamboo chest (not the fuel chest)
  end
  -- rate over the last hour
  local now = os.epoch("utc") / 1000
  local rate
  local oldest
  for _, h in ipairs(S.hist) do if now - h.t <= 3700 then oldest = h end end   -- (newest first)
  if oldest and now - oldest.t > 120 then rate = (total - oldest.blocks) / ((now - oldest.t) / 3600) end
  local y = 3
  line(y, "Bamboo blocks: " .. commas(total), colors.lime); y = y + 1
  line(y, "Per hour: " .. (rate and commas(math.max(0, rate)) or "measuring..."), colors.lightGray); y = y + 2
  for i, c in ipairs(store) do
    if y + 1 > H - 2 then break end
    local free = (c.size or 0) - c.used
    local full = c.size and c.size > 0 and c.used / c.size or 0
    line(y, "Chest " .. i .. ": " .. commas(c.blocks) .. " blocks  " .. math.floor(full * 100 + 0.5) .. "% full",
      full >= 0.95 and colors.red or colors.white)
    y = y + 1
    bar(y, full, full >= 0.95 and colors.red or colors.green); y = y + 1
    if free <= 0 then line(y, "FULL - empty it", colors.red); y = y + 1 end
  end
  if #store == 0 then line(y, "No bamboo chests connected", colors.orange); y = y + 1 end
  y = math.max(y + 1, H - 1)
  if y <= H then
    line(y, "Fuel chest: " .. commas(fuel) .. " coal/charcoal", fuel < 64 and colors.red or colors.yellow)
  end
  if fuel == 0 and #chests > 0 and y - 1 > 2 then line(y - 1, "No fuel in any chest!", colors.red) end
  if #chests == 0 then
    line(4, "No chests found.", colors.orange)
    line(5, "Put a wired modem on each chest,", colors.lightGray)
    line(6, "cable them to this computer and", colors.lightGray)
    line(7, "right-click each modem (red).", colors.lightGray)
  end
end

local lastSave = 0
while true do
  local chests = scan()
  local total = 0
  for _, c in ipairs(chests) do total = total + c.blocks end
  local now = os.epoch("utc") / 1000
  if now - lastSave >= 60 then
    table.insert(S.hist, 1, { t = now, blocks = total })
    while #S.hist > 130 do table.remove(S.hist) end
    writeT(S); lastSave = now
  end
  draw(chests)
  local timer = os.startTimer(5)
  repeat local e, a = os.pullEvent() until (e == "timer" and a == timer) or e == "peripheral" or e == "peripheral_detach" or e == "monitor_resize"
  W, H = mon.getSize()
end
