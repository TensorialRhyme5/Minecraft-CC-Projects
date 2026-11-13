-- ============================================================
--  OCEAN VOYAGE  -  underwater visualizer for CC: Tweaked monitors
--  Light rays, kelp, coral, fish schools, jellyfish, a sea turtle,
--  far-off whales and sharks, rising bubbles and marine snow.
--  Tap the screen: burst of bubbles. Q on the computer = quit.
-- ============================================================

local CFG = {
  textScale = 0.5,
  frame     = 0.1,
  snow      = 140,     -- marine snow particles
}

-- ---------------------------------------------------------- monitors (all connected ones mirror)
local mons = {}
local function findMonitors()
  mons = {}
  for _, m in ipairs({ peripheral.find("monitor") }) do
    if m.isColour() then mons[#mons + 1] = { p = m, name = peripheral.getName(m), last = {} } end
  end
end
findMonitors()
if #mons == 0 then error("No advanced monitor found. Attach one to this computer.", 0) end

-- ---------------------------------------------------------- palette (all 16 used)
local PAL = {
  [colors.black]     = 0x04121f,  -- f  deepest water
  [colors.blue]      = 0x0a2740,  -- b  deep water / far silhouettes
  [colors.cyan]      = 0x103a5c,  -- 9  mid water
  [colors.brown]     = 0x175178,  -- c  upper water
  [colors.lightBlue] = 0x2a74a8,  -- 3  near the surface
  [colors.lightGray] = 0x5aa6d6,  -- 8  light rays / snow
  [colors.white]     = 0xe2f6ff,  -- 0  bubbles, highlights
  [colors.yellow]    = 0xcaa86c,  -- 4  sand
  [colors.gray]      = 0x7a6244,  -- 7  sand shadow, rocks, chest
  [colors.green]     = 0x2f8a4a,  -- d  kelp, turtle shell
  [colors.lime]      = 0x7fd65a,  -- 5  light seaweed
  [colors.red]       = 0xff5a5a,  -- e  coral
  [colors.pink]      = 0xff8fc8,  -- 6  coral, jellyfish
  [colors.magenta]   = 0xc04fe0,  -- 2  purple coral, jellyfish glow
  [colors.orange]    = 0xff9a3a,  -- 1  fish
  [colors.purple]    = 0xffd84a,  -- a  yellow fish, gold
}
local function applyPalette()
  for _, m in ipairs(mons) do for c, v in pairs(PAL) do m.p.setPaletteColour(c, v) end end
end
applyPalette()
local DEEP, DARK, MID, UPPER, SURF, RAY, WHITE = "f", "b", "9", "c", "3", "8", "0"
local SAND, SHADOW, KELP, WEED, CORAL, PINK, PURPLE, ORANGE, GOLD = "4", "7", "d", "5", "e", "6", "2", "1", "a"
local WATER = { SURF, UPPER, MID, DARK, DEEP }

-- ---------------------------------------------------------- screen
local W, H, PW, PH
local bgPix                      -- background colour per pixel (water, sand, coral...) worked out once
local bgC, bgF, bgB              -- background cell chars/colours per row
local pz, pc = {}, {}
local function plot(px, py, z, col)
  px, py = math.floor(px + 0.5), math.floor(py + 0.5)
  if px < 0 or py < 0 or px >= PW or py >= PH then return end
  local k = py * PW + px
  local old = pz[k]
  if not old or z < old then pz[k], pc[k] = z, col end
end
local function line(x1, y1, x2, y2, z, col)
  local n = math.max(1, math.ceil(math.max(math.abs(x2 - x1), math.abs(y2 - y1))))
  for i = 0, n do plot(x1 + (x2 - x1) * i / n, y1 + (y2 - y1) * i / n, z, col) end
end
local function ellipse(cx, cy, rx, ry, z, colFn)
  for y = math.floor(cy - ry), math.ceil(cy + ry) do
    for x = math.floor(cx - rx), math.ceil(cx + rx) do
      local dx, dy = (x - cx) / rx, (y - cy) / ry
      if dx * dx + dy * dy <= 1 then
        local c = colFn(dx, dy)
        if c then plot(x, y, z, c) end
      end
    end
  end
end

-- two-colour reduction of a 2x3 cell (pixels 0..5)
local function reduce(cell)
  local cnt, c1, c2 = {}, nil, nil
  for i = 0, 5 do local col = cell[i]; cnt[col] = (cnt[col] or 0) + 1 end
  for col, n in pairs(cnt) do
    if not c1 or n > cnt[c1] then c2 = c1; c1 = col
    elseif not c2 or n > cnt[c2] then c2 = col end
  end
  if not c2 then return " ", "0", c1 end
  local bits = 0
  for i = 0, 5 do if cell[i] == c2 then bits = bits + 2 ^ i end end
  if bits >= 32 then return string.char(128 + (63 - bits)), c1, c2 end
  return string.char(128 + bits), c2, c1
end

local BAYER = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } }
local floorY, dunes = {}, {}
local coral = {}

local function buildBackground()
  bgPix = {}
  -- water gradient (dithered between neighbouring shades)
  for py = 0, PH - 1 do
    local f = py / PH * (#WATER - 1)
    local i = math.floor(f)
    local frac = f - i
    for px = 0, PW - 1 do
      local th = (BAYER[py % 4 + 1][px % 4 + 1] + 0.5) / 16
      bgPix[py * PW + px] = WATER[math.min(#WATER, (frac > th) and i + 2 or i + 1)]
    end
  end
  -- sand dunes
  local base = PH * 0.86
  for px = 0, PW - 1 do
    local y = base + math.sin(px * 0.021) * PH * 0.025 + math.sin(px * 0.057 + 1.3) * PH * 0.012
    floorY[px] = math.floor(y)
    for py = floorY[px], PH - 1 do
      local shade = ((math.sin(px * 12.9898 + py * 78.233) * 43758.5453) % 1 < 0.07) or (py == floorY[px] and px % 3 == 0)
      bgPix[py * PW + px] = shade and SHADOW or SAND
    end
  end
  local function put(x, y, c)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    if x >= 0 and y >= 0 and x < PW and y < PH then bgPix[y * PW + x] = c end
  end
  -- rocks
  for _, r in ipairs({ { 0.08, 9 }, { 0.47, 7 }, { 0.9, 11 } }) do
    local cx = math.floor(PW * r[1]); local cy = floorY[cx]
    for y = -r[2], 0 do for x = -r[2] * 1.6, r[2] * 1.6 do
      if (x / (r[2] * 1.6)) ^ 2 + (y / r[2]) ^ 2 <= 1 then put(cx + x, cy + y, (x + y < -r[2] * 0.6) and SAND or SHADOW) end
    end end
  end
  -- branching coral (static)
  local function branch(x, y, ang, len, w, col, depth)
    local x2, y2 = x + math.cos(ang) * len, y - math.sin(ang) * len
    local n = math.ceil(len)
    for i = 0, n do
      local bx, by = x + (x2 - x) * i / n, y + (y2 - y) * i / n
      for o = 0, w - 1 do put(bx + o, by, col) end
    end
    if depth > 0 then
      branch(x2, y2, ang + 0.45, len * 0.72, math.max(1, w - 1), col, depth - 1)
      branch(x2, y2, ang - 0.4, len * 0.7, math.max(1, w - 1), col, depth - 1)
    end
  end
  coral = {}
  local spots = { { 0.16, CORAL }, { 0.27, PINK }, { 0.37, PURPLE }, { 0.62, CORAL }, { 0.71, PURPLE }, { 0.83, PINK } }
  for _, s in ipairs(spots) do
    local x = math.floor(PW * s[1]); local y = floorY[x]
    branch(x, y, math.pi / 2, PH * 0.05, 2, s[2], 3)
    coral[#coral + 1] = { x = x, y = y }
  end
  -- brain-coral mounds
  for _, s in ipairs({ { 0.22, PINK }, { 0.56, CORAL }, { 0.77, GOLD } }) do
    local cx = math.floor(PW * s[1]); local cy = floorY[cx]
    for y = -6, 0 do for x = -9, 9 do
      if (x / 9) ^ 2 + (y / 6) ^ 2 <= 1 then put(cx + x, cy + y, ((x + y) % 3 == 0) and SHADOW or s[2]) end
    end end
  end
  -- treasure chest
  local cx = math.floor(PW * 0.52); local cy = floorY[cx]
  for y = -9, 0 do for x = -8, 8 do
    local c = SHADOW
    if y <= -6 then c = (math.abs(x) <= 7) and SHADOW or nil end
    if y == -5 or math.abs(x) == 8 or x == 0 then c = GOLD end
    if c then put(cx + x, cy + y, c) end
  end end
  -- reduce background to cells once
  bgC, bgF, bgB = {}, {}, {}
  for cy = 0, H - 1 do
    local rc, rf, rb = {}, {}, {}
    for cx2 = 0, W - 1 do
      local cell = {}
      for i = 0, 5 do cell[i] = bgPix[(cy * 3 + math.floor(i / 2)) * PW + cx2 * 2 + i % 2] end
      rc[cx2 + 1], rf[cx2 + 1], rb[cx2 + 1] = reduce(cell)
    end
    bgC[cy + 1], bgF[cy + 1], bgB[cy + 1] = rc, rf, rb
  end
end

local function setup()
  W, H = math.huge, math.huge
  for _, m in ipairs(mons) do
    m.p.setTextScale(CFG.textScale)
    local w, h = m.p.getSize()
    W, H = math.min(W, w), math.min(H, h)
    m.p.setBackgroundColour(colors.black); m.p.clear(); m.last = {}
  end
  PW, PH = W * 2, H * 3
  buildBackground()
end

-- ---------------------------------------------------------- creatures and effects
local function rnd(a, b) return a + math.random() * (b - a) end
local snow, bubbles, kelp, schools, jellies, bigs = {}, {}, {}, {}, {}, {}
local rays
local turtle
local nextSpawn = { school = 1, jelly = 3, big = 20, turtle = 12, vent = 0 }
local started = false

local function initWorld()
  snow = {}
  for i = 1, CFG.snow do snow[i] = { x = rnd(0, PW), y = rnd(0, PH), z = rnd(0.3, 1), ph = rnd(0, 6) } end
  kelp = {}
  for _, f in ipairs({ 0.04, 0.11, 0.3, 0.33, 0.44, 0.6, 0.66, 0.87, 0.95 }) do
    local x = math.floor(PW * f)
    kelp[#kelp + 1] = { x = x, h = rnd(PH * 0.22, PH * 0.48), ph = rnd(0, 6), col = math.random() < 0.5 and KELP or WEED }
  end
  bubbles = {}
end

local FISH_COLS = { { ORANGE, WHITE }, { GOLD, GOLD }, { PINK, WHITE }, { CORAL, GOLD }, { WEED, GOLD } }
local function spawnSchool(t)
  local dir = math.random(0, 1) == 0 and -1 or 1
  local z = rnd(0.7, 1.6)
  local n = math.random(6, 13)
  local cols = FISH_COLS[math.random(1, #FISH_COLS)]
  local s = { dir = dir, z = z, x = dir > 0 and -PW * 0.3 or PW * 1.3, y = rnd(PH * 0.2, PH * 0.7),
              v = rnd(14, 26) / z, ph = rnd(0, 6), fish = {}, cols = cols }
  for i = 1, n do s.fish[i] = { dx = rnd(-PW * 0.12, PW * 0.12), dy = rnd(-PH * 0.08, PH * 0.08), ph = rnd(0, 6) } end
  schools[#schools + 1] = s
end
local function spawnJelly()
  jellies[#jellies + 1] = { x = rnd(PW * 0.1, PW * 0.9), y = PH * 0.74, z = rnd(0.8, 1.5), ph = rnd(0, 6),
                            col = math.random() < 0.5 and PINK or PURPLE }
end
local function spawnBig()
  local dir = math.random(0, 1) == 0 and -1 or 1
  bigs[#bigs + 1] = { kind = math.random() < 0.55 and "whale" or "shark", dir = dir,
    x = dir > 0 and -PW * 0.5 or PW * 1.5, y = rnd(PH * 0.25, PH * 0.5), v = rnd(6, 10) }
end
local function spawnTurtle()
  local dir = math.random(0, 1) == 0 and -1 or 1
  turtle = { dir = dir, x = dir > 0 and -40 or PW + 40, y = rnd(PH * 0.3, PH * 0.6), v = rnd(10, 15), ph = 0 }
end
local function burst(px, py)
  for _ = 1, 25 do bubbles[#bubbles + 1] = { x = px + rnd(-6, 6), y = py + rnd(-4, 4), r = rnd(0.5, 2.2), v = rnd(12, 30), ph = rnd(0, 6) } end
end

local function fishSprite(x, y, dir, s, z, col1, col2, wig)
  -- body ellipse + tail triangle + eye; s = size in pixels
  ellipse(x, y, s, s * 0.5, z, function(dx, dy)
    if dx * dir > 0.45 and dy < -0.1 and dy > -0.5 then return DEEP end         -- eye
    if math.abs(dx) < 0.18 and col2 ~= col1 then return col2 end                -- stripe
    return col1
  end)
  local tx = x - dir * s
  for k = 0, math.floor(s * 0.7) do
    local hh = (k + 1) * 0.55 + wig
    line(tx - dir * k, y - hh, tx - dir * k, y + hh, z, col1)
  end
end

local function render(t, dt)
  pz, pc = {}, {}
  if not started then
    started = true
    for k, v in pairs(nextSpawn) do nextSpawn[k] = t + v end
  end

  -- light rays from the surface: each ray's dot pattern is worked out once, then swayed side to side
  if not rays then
    rays = {}
    for i = 0, 5 do
      local dots = {}
      local width = PW * 0.035
      local len = PH * (0.5 + 0.15 * math.sin(i * 2.1))
      for y = 0, math.floor(len) do
        local fade = 1 - y / len
        local wy = width * (1 + y / len)
        for x = -math.floor(wy), math.floor(wy) do
          local edge = 1 - math.abs(x) / (wy + 1)                     -- softer at the sides
          local h = (math.sin(x * 12.9898 + y * 78.233 + i * 3.7) * 43758.5453) % 1   -- random-looking, no stripes
          if h < fade * edge * 0.5 then dots[#dots + 1] = x + math.floor(y * 0.28); dots[#dots + 1] = y end
        end
      end
      rays[i + 1] = { x0 = PW * (0.08 + i * 0.17), ph = i * 1.7, dots = dots }
    end
  end
  for _, r in ipairs(rays) do
    local ox = math.floor(r.x0 + math.sin(t * 0.25 + r.ph) * PW * 0.04)
    local d = r.dots
    for i = 1, #d, 2 do plot(ox + d[i], d[i + 1], 9, RAY) end
  end

  -- far silhouettes: whales and sharks (dark, slow)
  if t >= nextSpawn.big then spawnBig(); nextSpawn.big = t + rnd(35, 60) end
  for i = #bigs, 1, -1 do
    local b = bigs[i]
    b.x = b.x + b.dir * b.v * dt
    if (b.dir > 0 and b.x > PW * 1.6) or (b.dir < 0 and b.x < -PW * 0.6) then table.remove(bigs, i)
    else
      local tail = math.sin(t * 1.2) * 4
      if b.kind == "whale" then
        ellipse(b.x, b.y, PW * 0.17, PH * 0.07, 8, function(dx, dy) return dy > 0.55 and MID or DARK end)
        for k = 0, 14 do line(b.x - b.dir * (PW * 0.17 + k), b.y - k * 0.4 + tail * k / 14, b.x - b.dir * (PW * 0.17 + k), b.y + k * 0.25 + tail * k / 14, 8, DARK) end
        line(b.x - b.dir * (PW * 0.17 + 14), b.y - 9 + tail, b.x - b.dir * (PW * 0.17 + 14), b.y + 6 + tail, 8, DARK)
        ellipse(b.x + b.dir * PW * 0.02, b.y + PH * 0.06, 12, 3, 8, function() return DARK end)    -- flipper
      else
        ellipse(b.x, b.y, PW * 0.1, PH * 0.028, 8, function() return DARK end)
        for k = 0, 9 do line(b.x + b.dir * (k - 4), b.y - PH * 0.028 - (9 - math.abs(k - 3) * 1.4), b.x + b.dir * (k - 4), b.y - PH * 0.028, 8, DARK) end
        for k = 0, 10 do line(b.x - b.dir * (PW * 0.1 + k), b.y - k * 0.9 + tail, b.x - b.dir * (PW * 0.1 + k), b.y + k * 0.6 + tail, 8, DARK) end
      end
    end
  end

  -- marine snow
  for _, s in ipairs(snow) do
    s.y = s.y + (3 + 5 * (1 - s.z)) * dt
    s.x = s.x + math.sin(t * 0.5 + s.ph) * 2 * dt
    if s.y > PH then s.y = -2; s.x = rnd(0, PW) end
    plot(s.x, s.y, 6 + s.z, s.z < 0.55 and WHITE or RAY)
  end

  -- kelp / seaweed swaying
  for _, k in ipairs(kelp) do
    local base = floorY[math.min(PW - 1, k.x)] or PH
    local px, py = k.x, base
    local segs = math.floor(k.h / 3)
    for i = 1, segs do
      local f = i / segs
      local nx = k.x + math.sin(t * 0.9 + k.ph + f * 2.2) * 9 * f
      local ny = base - k.h * f
      line(px, py, nx, ny, 0.8, k.col); line(px + 1, py, nx + 1, ny, 0.8, k.col)
      if i % 4 == 0 then line(nx, ny, nx + 4 * (i % 8 == 0 and 1 or -1), ny - 2, 0.8, k.col) end   -- leaves
      px, py = nx, ny
    end
  end

  -- sea turtle
  if not turtle and t >= nextSpawn.turtle then spawnTurtle() end
  if turtle then
    local tt = turtle
    tt.x = tt.x + tt.dir * tt.v * dt
    tt.y = tt.y + math.sin(t * 0.6) * 3 * dt
    if (tt.dir > 0 and tt.x > PW + 50) or (tt.dir < 0 and tt.x < -50) then turtle = nil; nextSpawn.turtle = t + rnd(30, 50)
    else
      local flap = math.sin(t * 2.2) * 5
      ellipse(tt.x - tt.dir * 3, tt.y - 10 + flap, 9, 3, 1.25, function() return KELP end)        -- front flipper
      ellipse(tt.x - tt.dir * 13, tt.y + 6 - flap * 0.5, 5, 2, 1.25, function() return KELP end) -- back flipper
      ellipse(tt.x, tt.y, 16, 9, 1.2, function(dx, dy)                                            -- shell
        if dy > 0.6 then return SAND end
        return ((math.floor((dx + 1) * 4) + math.floor((dy + 1) * 3)) % 2 == 0) and KELP or WEED
      end)
      ellipse(tt.x + tt.dir * 19, tt.y - 2, 5, 4, 1.2, function(dx, dy)                           -- head
        if dx * tt.dir > 0.2 and dy < -0.1 then return DEEP end
        return WEED
      end)
    end
  end

  -- fish schools
  if t >= nextSpawn.school and #schools < 3 then spawnSchool(t); nextSpawn.school = t + rnd(6, 14) end
  for i = #schools, 1, -1 do
    local s = schools[i]
    s.x = s.x + s.dir * s.v * dt
    if (s.dir > 0 and s.x > PW * 1.35) or (s.dir < 0 and s.x < -PW * 0.35) then table.remove(schools, i)
    else
      local size = 4.5 / s.z
      for _, f in ipairs(s.fish) do
        local fx = s.x + f.dx / s.z
        local fy = s.y + f.dy / s.z + math.sin(t * 1.5 + f.ph + fx * 0.02) * 4
        fishSprite(fx, fy, s.dir, size, s.z, s.cols[1], s.cols[2], math.sin(t * 8 + f.ph) * 0.8)
      end
    end
  end

  -- jellyfish
  if t >= nextSpawn.jelly and #jellies < 3 then spawnJelly(); nextSpawn.jelly = t + rnd(8, 16) end
  for i = #jellies, 1, -1 do
    local j = jellies[i]
    local pulse = math.sin(t * 2.4 + j.ph)
    j.y = j.y - (4 + math.max(0, pulse) * 9) / j.z * dt
    j.x = j.x + math.sin(t * 0.4 + j.ph) * 3 * dt
    if j.y < -40 then table.remove(jellies, i)
    else
      local r = 9 / j.z
      local rx, ry = r * (1 + 0.15 * pulse), r * (0.75 - 0.15 * pulse)
      ellipse(j.x, j.y, rx, ry, j.z, function(dx, dy)
        if dy > 0.1 then return nil end
        if dy < -0.55 and math.abs(dx) < 0.4 then return WHITE end
        return (dx * dx + dy * dy > 0.6) and j.col or PINK
      end)
      for k = 0, 5 do                                                   -- wavy tentacles
        local tx = j.x - rx * 0.8 + k * rx * 0.32
        local len = r * (2 + (k % 2) * 0.8)
        local px2, py2 = tx, j.y + 1
        for q = 1, math.floor(len / 2) do
          local nx = tx + math.sin(t * 2 + k + q * 0.6) * 2.2
          local ny = j.y + 1 + q * 2
          line(px2, py2, nx, ny, j.z + 0.01, (q % 3 == 0) and PURPLE or j.col)
          px2, py2 = nx, ny
        end
      end
    end
  end

  -- bubbles from vents in the coral + tap bursts
  if t >= nextSpawn.vent then
    local c = coral[math.random(1, #coral)]
    if c then for _ = 1, math.random(2, 5) do bubbles[#bubbles + 1] = { x = c.x + rnd(-3, 3), y = c.y - PH * 0.06, r = rnd(0.5, 1.8), v = rnd(10, 22), ph = rnd(0, 6) } end end
    nextSpawn.vent = t + rnd(0.6, 1.8)
  end
  for i = #bubbles, 1, -1 do
    local b = bubbles[i]
    b.y = b.y - b.v * dt
    b.x = b.x + math.sin(t * 3 + b.ph) * 4 * dt
    b.r = math.min(3.5, b.r + dt * 0.25)
    if b.y < -5 then table.remove(bubbles, i)
    elseif b.r < 1.2 then plot(b.x, b.y, 0.5, WHITE)
    else
      for a = 0, 11 do
        local ang = a / 12 * 2 * math.pi
        plot(b.x + math.cos(ang) * b.r, b.y + math.sin(ang) * b.r, 0.5, (a == 4) and WHITE or RAY)
      end
      plot(b.x - b.r * 0.4, b.y - b.r * 0.4, 0.45, WHITE)
    end
  end

  -- treasure glint
  local gx = math.floor(PW * 0.52)
  if math.sin(t * 1.3) > 0.85 then
    local gy = (floorY[gx] or PH) - 6
    plot(gx + 4, gy, 0.4, WHITE); plot(gx + 3, gy, 0.4, WHITE); plot(gx + 5, gy, 0.4, WHITE)
    plot(gx + 4, gy - 1, 0.4, WHITE); plot(gx + 4, gy + 1, 0.4, WHITE)
  end

  -- merge moving things with the background and draw
  local touched = {}
  for k, col in pairs(pc) do
    local px, py = k % PW, math.floor(k / PW)
    local ck = math.floor(py / 3) * W + math.floor(px / 2)
    local cell = touched[ck]
    if not cell then cell = {}; touched[ck] = cell end
    cell[(py % 3) * 2 + px % 2] = col
  end
  for _, m in ipairs(mons) do m.rows = m.rows or {} end
  for y = 0, H - 1 do
    local rc, rf, rb = bgC[y + 1], bgF[y + 1], bgB[y + 1]
    local c, f, b = {}, {}, {}
    for x = 0, W - 1 do
      local cell = touched[y * W + x]
      if cell then
        for i = 0, 5 do
          if not cell[i] then cell[i] = bgPix[(y * 3 + math.floor(i / 2)) * PW + x * 2 + i % 2] end
        end
        c[x + 1], f[x + 1], b[x + 1] = reduce(cell)
      else
        c[x + 1], f[x + 1], b[x + 1] = rc[x + 1], rf[x + 1], rb[x + 1]
      end
    end
    local sc, sf, sb = table.concat(c), table.concat(f), table.concat(b)
    local key = sc .. sf .. sb
    for _, m in ipairs(mons) do
      if m.last[y + 1] ~= key then m.p.setCursorPos(1, y + 1); m.p.blit(sc, sf, sb); m.last[y + 1] = key end
    end
  end
end

-- ---------------------------------------------------------- main loop
math.randomseed(os.epoch("utc"))
setup()
initWorld()
term.clear(); term.setCursorPos(1, 1)
print("OCEAN VOYAGE")
print("Tap the screen for a burst of bubbles")
print("Q = quit")
if _G.__JB_TEST then
  _G.__JB = { hits = function() return { { id = "screen", x1 = 1, y1 = 1, x2 = W, y2 = H } } end,
    spawn = { school = spawnSchool, jelly = spawnJelly, big = spawnBig, turtle = spawnTurtle },
    get = function() return { schools = schools, jellies = jellies, bigs = bigs, turtle = turtle } end }
end

local function now() return os.epoch("utc") / 1000 end
local last = now()
local timer = os.startTimer(0)
while true do
  local ev, a, b, c = os.pullEventRaw()
  if ev == "terminate" or (ev == "key" and a == keys.q) then break
  elseif ev == "timer" and a == timer then
    local t = now()
    render(t, math.min(0.3, t - last))
    last = t
    timer = os.startTimer(CFG.frame)
  elseif ev == "monitor_touch" then
    burst((b - 1) * 2 + 1, (c - 1) * 3 + 1)
  elseif ev == "monitor_resize" or ev == "peripheral" or ev == "peripheral_detach" then
    findMonitors()
    if #mons > 0 then applyPalette(); setup(); initWorld(); rays = nil end
  end
end

for _, m in ipairs(mons) do
  for i = 0, 15 do m.p.setPaletteColour(2 ^ i, term.nativePaletteColour(2 ^ i)) end
  m.p.setBackgroundColour(colors.black); m.p.clear()
end
term.clear(); term.setCursorPos(1, 1); print("Ocean Voyage stopped.")
