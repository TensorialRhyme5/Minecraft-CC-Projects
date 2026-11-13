-- ============================================================
--  SPACE VOYAGE  -  3D visualizer for CC: Tweaked monitors
--  Fly through space past planets, ships, comets and nebulae
--  toward a warping wireframe shape.
--  Tap the screen: hyperspace boost + next shape.
--  Keys on the computer: Space = boost, Up/Down = speed, Q = quit
-- ============================================================

local CFG = {
  textScale = 0.5,
  frame     = 0.1,    -- seconds per frame
  stars     = 520,
  points    = 720,    -- points per shape (more = smoother lines)
  speed     = 0.35,   -- cruising speed through the starfield
  hold      = 6,      -- seconds a shape stays before warping
  morph     = 2.5,    -- seconds a warp takes
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

-- ---------------------------------------------------------- palette (16 colours, all used)
--  f  background          c 7 8 0  stars far -> near (c is also planet night side)
--  2 a b 9 3  shape far -> near (re-coloured every frame)
--  1 orange   4 yellow   5 lime   e red      (planets, ships, comets)
--  6 nebula pink   d nebula teal              (dim, far away)
local PAL = {
  [colors.black] = 0x020308, [colors.brown] = 0x2c3046, [colors.gray] = 0x6c7292,
  [colors.lightGray] = 0xa8b0d0, [colors.white] = 0xf4f6ff,
  [colors.orange] = 0xff9a4a, [colors.yellow] = 0xffd84a, [colors.lime] = 0x6fd65a, [colors.red] = 0xff4a4a,
  [colors.pink] = 0x4a1f3e, [colors.green] = 0x153c44,
}
local SHAPE_SLOTS = { colors.magenta, colors.purple, colors.blue, colors.cyan, colors.lightBlue } -- far -> near
local SHAPE_CH = { "2", "a", "b", "9", "3" }
local STAR_CH = { "c", "7", "8", "0" }
local ORANGE, YELLOW, LIME, RED, NEB1, NEB2 = "1", "4", "5", "e", "6", "d"
local DARK, GRAY, LGRAY, WHITE = "c", "7", "8", "0"
local function applyPalette()
  for _, m in ipairs(mons) do for c, v in pairs(PAL) do m.p.setPaletteColour(c, v) end end
end
applyPalette()

local function hsv(h, s, v)
  h = (h % 1) * 6
  local i = math.floor(h)
  local f = h - i
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  local r, g, b
  if i == 0 then r, g, b = v, t, p elseif i == 1 then r, g, b = q, v, p elseif i == 2 then r, g, b = p, v, t
  elseif i == 3 then r, g, b = p, q, v elseif i == 4 then r, g, b = t, p, v else r, g, b = v, p, q end
  return math.floor(r * 255) * 65536 + math.floor(g * 255) * 256 + math.floor(b * 255)
end
-- every shape has its own colour family; it blends to the next one while warping
local function shapeHue(i) return (0.52 + (i - 1) * 0.618) % 1 end
local function shapePalette(hue)
  for i, slot in ipairs(SHAPE_SLOTS) do
    local depth = (i - 1) / (#SHAPE_SLOTS - 1)           -- 0 far .. 1 near
    local col = hsv(hue + (1 - depth) * 0.08, 0.85 - depth * 0.35, 0.25 + depth * 0.75)
    for _, m in ipairs(mons) do m.p.setPaletteColour(slot, col) end
  end
end

-- ---------------------------------------------------------- screen + pixel buffer
local W, H, PW, PH
local function setup()
  W, H = math.huge, math.huge
  for _, m in ipairs(mons) do
    m.p.setTextScale(CFG.textScale)
    local w, h = m.p.getSize()
    W, H = math.min(W, w), math.min(H, h)
    m.p.setBackgroundColour(colors.black); m.p.clear(); m.last = {}
  end
  PW, PH = W * 2, H * 3
end

-- every lit pixel keeps the colour of whatever is closest to the camera (smaller depth wins)
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
local function disk(cx, cy, r, z, colFn)                     -- filled circle, colFn(dx, dy) -> colour or nil
  local r2 = r * r
  for y = math.floor(cy - r), math.ceil(cy + r) do
    for x = math.floor(cx - r), math.ceil(cx + r) do
      local dx, dy = x - cx, y - cy
      if dx * dx + dy * dy <= r2 then
        local c = colFn(dx / r, dy / r)
        if c then plot(x, y, z, c) end
      end
    end
  end
end

-- ---------------------------------------------------------- shapes (point clouds sampled along their lines)
local NP = CFG.points
local SHAPES = {}
local function finish(name, pts, adj)
  local r = 0
  for _, v in ipairs(pts) do r = math.max(r, math.sqrt(v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2)) end
  for _, v in ipairs(pts) do v[1], v[2], v[3] = v[1] / r, v[2] / r, v[3] / r end
  SHAPES[#SHAPES + 1] = { name = name, p = pts, adj = adj }   -- adj[i]: point i connects to point i+1
end
local function fromEdges(name, verts, edges)
  if not edges then                                          -- all pairs at the shortest distance
    edges = {}
    local best = math.huge
    local function d2(a, b) return (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2 end
    for i = 1, #verts do for j = i + 1, #verts do best = math.min(best, d2(verts[i], verts[j])) end end
    for i = 1, #verts do for j = i + 1, #verts do
      if math.abs(d2(verts[i], verts[j]) - best) < 1e-6 then edges[#edges + 1] = { i, j } end
    end end
  end
  local pts, adj, per = {}, {}, NP / #edges
  for n = 0, NP - 1 do
    local ei = math.floor(n / per) + 1
    local e = edges[ei]
    local k = n - math.floor((ei - 1) * per)
    local cnt = math.floor(ei * per) - math.floor((ei - 1) * per)
    local f = cnt > 1 and k / (cnt - 1) or 0.5
    local a, b = verts[e[1]], verts[e[2]]
    pts[#pts + 1] = { a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f }
    adj[#pts] = k < cnt - 1
  end
  finish(name, pts, adj)
end
local function fromCurves(name, curves, fn)
  local per = NP / curves
  local pts, adj = {}, {}
  for n = 0, NP - 1 do
    local c = math.floor(n / per)
    local k = n - math.floor(c * per)
    local cnt = math.floor((c + 1) * per) - math.floor(c * per)
    pts[#pts + 1] = fn(c, k / cnt)
    adj[#pts] = k < cnt - 1
  end
  finish(name, pts, adj)
end
do
  local TAU = 2 * math.pi
  local P = (1 + math.sqrt(5)) / 2
  local cube = {}
  for x = -1, 1, 2 do for y = -1, 1, 2 do for z = -1, 1, 2 do cube[#cube + 1] = { x, y, z } end end end
  fromEdges("CUBE", cube)
  fromEdges("OCTAHEDRON", { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } })
  fromCurves("TORUS", 16, function(c, f)
    local u, v = c / 16 * TAU, f * TAU
    return { (0.68 + 0.32 * math.cos(v)) * math.cos(u), 0.32 * math.sin(v), (0.68 + 0.32 * math.cos(v)) * math.sin(u) }
  end)
  local ico = {}
  for _, a in ipairs({ -1, 1 }) do for _, b in ipairs({ -P, P }) do
    ico[#ico + 1] = { 0, a, b }; ico[#ico + 1] = { a, b, 0 }; ico[#ico + 1] = { b, 0, a }
  end end
  fromEdges("ICOSAHEDRON", ico)
  fromCurves("SPHERE", 8, function(c, f)                       -- 4 latitude rings + 4 meridians
    local a = f * TAU
    if c < 4 then
      local lat = (-0.6 + c * 0.4) * math.pi / 2
      return { math.cos(lat) * math.cos(a), math.sin(lat), math.cos(lat) * math.sin(a) }
    end
    local lon = (c - 4) / 4 * math.pi
    return { math.cos(a) * math.cos(lon), math.sin(a), math.cos(a) * math.sin(lon) }
  end)
  fromEdges("PYRAMID", { { 1, 1, 1 }, { 1, -1, -1 }, { -1, 1, -1 }, { -1, -1, 1 } })
  fromCurves("TREFOIL KNOT", 1, function(_, f)
    local t = f * TAU
    return { math.sin(t) + 2 * math.sin(2 * t), math.cos(t) - 2 * math.cos(2 * t), -math.sin(3 * t) * 1.2 }
  end)
  fromCurves("GYROSCOPE", 3, function(c, f)
    local a = f * TAU
    local x, y = math.cos(a), math.sin(a)
    if c == 0 then return { x, y, 0 } elseif c == 1 then return { x, 0, y } else return { 0, x, y } end
  end)
  do                                                           -- star: two interlocking tetrahedra
    local v = { { 1, 1, 1 }, { 1, -1, -1 }, { -1, 1, -1 }, { -1, -1, 1 }, { -1, -1, -1 }, { -1, 1, 1 }, { 1, -1, 1 }, { 1, 1, -1 } }
    local e = {}
    for base = 0, 4, 4 do for i = 1, 4 do for j = i + 1, 4 do e[#e + 1] = { base + i, base + j } end end end
    fromEdges("STAR", v, e)
  end
  fromCurves("DOUBLE HELIX", 2, function(c, f)
    local a = f * 4 * math.pi + c * math.pi
    return { 0.45 * math.cos(a), f * 2 - 1, 0.45 * math.sin(a) }
  end)
  do                                                           -- dodecahedron
    local v, ip = {}, 1 / P
    for x = -1, 1, 2 do for y = -1, 1, 2 do for z = -1, 1, 2 do v[#v + 1] = { x, y, z } end end end
    for _, a in ipairs({ -1, 1 }) do for _, b in ipairs({ -1, 1 }) do
      v[#v + 1] = { 0, a * ip, b * P }; v[#v + 1] = { a * ip, b * P, 0 }; v[#v + 1] = { a * P, 0, b * ip }
    end end
    fromEdges("DODECAHEDRON", v)
  end
  fromCurves("COIL", 1, function(_, f)
    local a = f * 5 * TAU
    return { 0.7 * math.cos(a), f * 2.4 - 1.2, 0.7 * math.sin(a) }
  end)
  do                                                           -- diamond: hexagonal bipyramid
    local v, e = {}, {}
    for i = 0, 5 do local a = i / 6 * TAU; v[#v + 1] = { math.cos(a), 0.15, math.sin(a) } end
    v[7], v[8] = { 0, 0.85, 0 }, { 0, -1.3, 0 }
    for i = 1, 6 do e[#e + 1] = { i, i % 6 + 1 }; e[#e + 1] = { i, 7 }; e[#e + 1] = { i, 8 } end
    fromEdges("DIAMOND", v, e)
  end
  do                                                           -- tesseract: cube in a cube
    local v, e = {}, {}
    for _, s in ipairs({ 1, 0.5 }) do
      for x = -1, 1, 2 do for y = -1, 1, 2 do for z = -1, 1, 2 do v[#v + 1] = { x * s, y * s, z * s } end end end
    end
    for base = 0, 8, 8 do
      for i = 1, 8 do for j = i + 1, 8 do
        local a, b = v[base + i], v[base + j]
        local diff = 0
        for k = 1, 3 do if a[k] ~= b[k] then diff = diff + 1 end end
        if diff == 1 then e[#e + 1] = { base + i, base + j } end
      end end
    end
    for i = 1, 8 do e[#e + 1] = { i, i + 8 } end
    fromEdges("TESSERACT", v, e)
  end
end

-- ---------------------------------------------------------- the world
local stars = {}
local function newStar(s, far)
  s = s or {}
  s.x, s.y = (math.random() * 2 - 1) * 1.6, (math.random() * 2 - 1) * 1.2
  s.z = far and (0.85 + math.random() * 0.15) or (0.05 + math.random() * 0.95)
  return s
end
for i = 1, CFG.stars do stars[i] = newStar(nil, false) end

-- nebula: faint coloured clouds far away (fixed in the sky, drift with the camera)
local nebula = {}
for i = 1, 3 do
  nebula[i] = { x = (math.random() * 2 - 1) * 0.9, y = (math.random() * 2 - 1) * 0.6, r = 0.18 + math.random() * 0.18,
                col = (i % 2 == 0) and NEB1 or NEB2, seed = math.random(1, 1000) }
end

-- objects that fly by: planets, ufos, rockets, comets, asteroids
local objects = {}
local nextSpawn = { planet = 4, ufo = 10, rocket = 22, comet = 15, asteroid = 8 }   -- seconds after start
local spawnStarted = false
local PLANETS = {
  { lit = ORANGE, band = YELLOW, ring = YELLOW },   -- ringed gas giant
  { lit = LIME, band = nil },                       -- green world
  { lit = RED, band = ORANGE },                     -- red world
  { lit = LGRAY, band = GRAY },                     -- moon-like rock
}
local function rnd(a, b) return a + math.random() * (b - a) end
local function spawn(kind, t)
  local side = math.random(0, 1) == 0 and -1 or 1
  if kind == "planet" then
    local p = PLANETS[math.random(1, #PLANETS)]
    objects[#objects + 1] = { kind = kind, style = p, x = side * rnd(0.5, 1.1), y = rnd(-0.6, 0.6), z = 3.2,
      r = rnd(0.25, 0.42), vx = -side * 0.02, born = t, ring = p.ring and true or false }
  elseif kind == "ufo" then
    objects[#objects + 1] = { kind = kind, x = -side * 2.2, y = rnd(-0.5, 0.5), z = rnd(0.9, 1.8), vx = side * rnd(0.35, 0.6),
      wob = rnd(0, 6), front = math.random() < 0.4 }
  elseif kind == "rocket" then
    objects[#objects + 1] = { kind = kind, x = -side * 2.2, y = rnd(-0.6, 0.6), z = rnd(1.0, 2.0), vx = side * rnd(0.5, 0.8),
      front = math.random() < 0.5 }
  elseif kind == "comet" then
    objects[#objects + 1] = { kind = kind, x = -side * 1.8, y = rnd(-0.7, -0.2), z = rnd(2.0, 3.0),
      vx = side * rnd(0.25, 0.4), vy = rnd(0.03, 0.08) }
  elseif kind == "asteroid" then
    local n = math.random(1, 3)
    for _ = 1, n do
      objects[#objects + 1] = { kind = kind, x = rnd(-0.8, 0.8), y = rnd(-0.6, 0.6), z = 2.5, r = rnd(0.03, 0.07),
        spin = rnd(0, 6), lumps = { rnd(0.7, 1), rnd(0.7, 1), rnd(0.7, 1), rnd(0.7, 1), rnd(0.7, 1), rnd(0.7, 1) } }
    end
  end
end
local GAP = { planet = { 28, 45 }, ufo = { 14, 26 }, rocket = { 18, 34 }, comet = { 16, 30 }, asteroid = { 9, 18 } }

-- ---------------------------------------------------------- frame
local state = { speed = CFG.speed, boostUntil = 0, from = 1, to = 1, start = -100, nextAt = 0, idx = 1, spinExtra = 0 }
local function nextShape(t)
  state.from = state.to
  state.idx = state.idx % #SHAPES + 1
  state.to = state.idx
  state.start, state.nextAt = t, t + CFG.morph + CFG.hold
end

local function render(t, dt)
  pz, pc = {}, {}
  local cx, cy = PW / 2, PH / 2
  local focal = math.min(PW, PH) * 0.5
  local roll = math.sin(t * 0.07) * 0.35
  local cr, sr = math.cos(roll), math.sin(roll)
  local yaw = math.sin(t * 0.05) * 0.25
  local boost = t < state.boostUntil and 4 or 1
  local speed = state.speed * boost
  local function project(x, y, z)                            -- world -> screen (with camera roll)
    local rx, ry = x * cr - y * sr, x * sr + y * cr
    return cx + rx / z * focal, cy + ry / z * focal
  end

  -- nebula (depth 4.5): dithered faint clouds; the dot pattern is worked out once, then just moved
  for _, n in ipairs(nebula) do
    if not n.dots then
      n.dots = {}
      local r = n.r * focal
      for y = -math.ceil(r), math.ceil(r) do
        for x = -math.ceil(r * 1.4), math.ceil(r * 1.4) do
          local dx, dy = x / (r * 1.4), y / r
          local d = dx * dx + dy * dy
          if d < 1 and ((x * 73856093 + y * 19349663 + n.seed) % 1000) / 1000 > 0.45 + d * 0.55 then
            n.dots[#n.dots + 1] = x; n.dots[#n.dots + 1] = y
          end
        end
      end
    end
    local nx, ny = project(n.x + yaw * 0.3, n.y, 1)
    nx, ny = math.floor(nx), math.floor(ny)
    local d, col = n.dots, n.col
    for i = 1, #d, 2 do plot(nx + d[i], ny + d[i + 1], 4.5, col) end
  end

  -- stars (depth 5+)
  for _, s in ipairs(stars) do
    s.z = s.z - speed * dt
    if s.z <= 0.03 then newStar(s, true) end
    local px, py = project(s.x + yaw * (1 - s.z), s.y, s.z)
    if px < -5 or py < -5 or px > PW + 5 or py > PH + 5 then
      newStar(s, true)
    else
      local col = s.z > 0.7 and STAR_CH[1] or (s.z > 0.42 and STAR_CH[2] or (s.z > 0.2 and STAR_CH[3] or STAR_CH[4]))
      local zz = 5 + s.z
      plot(px, py, zz, col)
      if s.z < 0.2 then plot(px + 1, py, zz, col) end
      if s.z < 0.12 then plot(px, py + 1, zz, col); plot(px + 1, py + 1, zz, col) end
      local maxLen = boost > 1 and 22 or (s.z < 0.18 and 4 or 0)
      if maxLen > 0 then
        local dx, dy = px - cx, py - cy
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 0 then
          local tl = math.min(maxLen, len * 0.15)
          line(px - dx / len * tl, py - dy / len * tl, px, py, zz + 0.5, boost > 1 and col or STAR_CH[1])
        end
      end
    end
  end

  -- spawn + move flying objects
  if not spawnStarted then
    spawnStarted = true
    for k, v in pairs(nextSpawn) do nextSpawn[k] = t + v end
  end
  for kind, at in pairs(nextSpawn) do
    if t >= at then
      local busy = false
      if kind == "planet" then for _, o in ipairs(objects) do if o.kind == "planet" then busy = true end end end
      if not busy then spawn(kind, t) end
      nextSpawn[kind] = t + rnd(GAP[kind][1], GAP[kind][2])
    end
  end
  for i = #objects, 1, -1 do
    local o = objects[i]
    local gone = false
    if o.kind == "planet" then
      o.z = o.z - speed * dt * 0.35; o.x = o.x + o.vx * dt
      local px, py = project(o.x, o.y, o.z)
      local r = o.r / o.z * focal
      if o.z < 0.35 or px + r < -10 or px - r > PW + 10 then gone = true
      else
        local st = o.style
        local spinPh = t * 0.15
        local function shade(nx, ny)
          local nz = math.sqrt(math.max(0, 1 - nx * nx - ny * ny))
          local b = -0.55 * nx - 0.5 * ny + 0.67 * nz         -- lit from upper-left
          if b < -0.05 then return DARK end
          if st.band then
            local band = math.sin((ny * 7 + math.sin(nx * 3 + spinPh)) * 1.3)
            if band > 0.55 then return st.band end
          end
          return st.lit
        end
        if o.ring then                                          -- back half of the ring (behind planet)
          for a = 0, 179 do
            local ang = a / 180 * 2 * math.pi
            local rx2, ry2 = math.cos(ang) * r * 1.9, math.sin(ang) * r * 0.42
            plot(px + rx2 + ry2 * 0.4, py + ry2 - rx2 * 0.12, (math.sin(ang) < 0) and 3.3 or 2.9, YELLOW)
          end
        end
        disk(px, py, r, 3.0, shade)
      end
    elseif o.kind == "ufo" then
      o.x = o.x + o.vx * dt
      local bob = math.sin(t * 2 + o.wob) * 0.04
      local px, py = project(o.x, o.y + bob, o.z)
      local s = 0.16 / o.z * focal
      local depth = o.front and -3 or 2
      if (o.vx > 0 and o.x > 2.4) or (o.vx < 0 and o.x < -2.4) then gone = true
      else
        disk(px, py - s * 0.18, s * 0.42, depth, function(nx, ny) if ny < 0.15 then return ny < -0.4 and WHITE or LIME end end) -- dome
        for y = -1, 1 do                                         -- hull: flat ellipse
          local w = s * (1 - math.abs(y) * 0.35)
          line(px - w, py + y * s * 0.12, px + w, py + y * s * 0.12, depth, y < 0 and LGRAY or GRAY)
        end
        local hw = s
        for k = 0, 4 do                                          -- blinking rim lights
          local lx = px - hw * 0.8 + k * hw * 0.4
          local on = math.floor(t * 4 + k) % 3
          local col = on == 0 and RED or (on == 1 and YELLOW or LIME)
          plot(lx, py + s * 0.05, depth - 0.1, col); plot(lx + 1, py + s * 0.05, depth - 0.1, col)
        end
      end
    elseif o.kind == "rocket" then
      o.x = o.x + o.vx * dt
      local px, py = project(o.x, o.y, o.z)
      local s = 0.12 / o.z * focal
      local dir = o.vx > 0 and 1 or -1
      local depth = o.front and -3 or 2
      if (dir > 0 and o.x > 2.4) or (dir < 0 and o.x < -2.4) then gone = true
      else
        for y = -1, 1 do line(px - s * dir, py + y * s * 0.18, px + s * 0.6 * dir, py + y * s * 0.18, depth, WHITE) end
        for k = 0, math.floor(s * 0.6) do                        -- nose cone
          local hh = s * 0.3 * (1 - k / (s * 0.6 + 1))
          line(px + (s * 0.6 + k) * dir, py - hh, px + (s * 0.6 + k) * dir, py + hh, depth, RED)
        end
        line(px - s * dir, py - s * 0.5, px - s * 0.5 * dir, py - s * 0.18, depth, RED)   -- fins
        line(px - s * dir, py + s * 0.5, px - s * 0.5 * dir, py + s * 0.18, depth, RED)
        plot(px + s * 0.15 * dir, py, depth - 0.1, "3")                                   -- window
        local fl = s * (0.6 + 0.4 * math.sin(t * 25))                                     -- flickering flame
        for y = -1, 1 do line(px - s * dir, py + y * s * 0.12, px - (s + fl * (1 - math.abs(y) * 0.4)) * dir, py + y * s * 0.12, depth + 0.1, math.abs(y) == 0 and YELLOW or ORANGE) end
      end
    elseif o.kind == "comet" then
      o.x = o.x + o.vx * dt; o.y = o.y + o.vy * dt
      local px, py = project(o.x, o.y, o.z)
      if o.x > 2.2 or o.x < -2.2 then gone = true
      else
        local tx, ty = -o.vx, -o.vy
        local tl = math.sqrt(tx * tx + ty * ty)
        tx, ty = tx / tl, ty / tl
        local len = 0.35 / o.z * focal
        for k = 0, math.floor(len) do                            -- tail: yellow near the head, orange further back
          local f = k / len
          local spread = f * len * 0.12
          local col = f < 0.3 and YELLOW or ORANGE
          if f < 0.85 or (k % 2 == 0) then
            plot(px + tx * k, py + ty * k, 3.5, col)
            if spread > 1 then plot(px + tx * k - ty * spread * math.sin(k + t * 5), py + ty * k + tx * spread * math.sin(k + t * 5), 3.6, ORANGE) end
          end
        end
        disk(px, py, math.max(1.2, 0.012 / o.z * focal), 3.4, function() return WHITE end)
      end
    elseif o.kind == "asteroid" then
      o.z = o.z - speed * dt * 1.6
      o.spin = o.spin + dt * 1.5
      local px, py = project(o.x, o.y, o.z)
      local r = o.r / o.z * focal
      if o.z < 0.15 or px < -r - 5 or px > PW + r + 5 or py < -r - 5 or py > PH + r + 5 then gone = true
      else
        local depth = o.z < 1 and -2 or 2.5                     -- close ones pass in front of the shape
        disk(px, py, r, depth, function(nx, ny)
          local a = math.atan2(ny, nx) + o.spin
          local lump = o.lumps[math.floor(((a % (2 * math.pi)) / (2 * math.pi)) * 6) + 1]
          if nx * nx + ny * ny > lump * lump then return nil end
          return (nx + ny < -0.2) and LGRAY or ((nx + ny > 0.6) and DARK or GRAY)
        end)
      end
    end
    if gone then table.remove(objects, i) end
  end

  -- warping shape (depth -1..1)
  if state.nextAt == 0 then state.nextAt = t + CFG.hold end
  if t >= state.nextAt then nextShape(t) end
  local f = math.max(0, math.min(1, (t - state.start) / CFG.morph))
  local e = f * f * (3 - 2 * f)
  local warping = f > 0 and f < 1
  local A, B = SHAPES[state.from], SHAPES[state.to]
  state.spinExtra = state.spinExtra + (warping and math.sin(f * math.pi) * 1.5 or 0) * dt
  local a1, a2 = t * 0.35 + state.spinExtra, t * 0.5 + state.spinExtra * 0.7
  local c1, s1, c2, s2 = math.cos(a1), math.sin(a1), math.cos(a2), math.sin(a2)
  local dist = 3.4 + 0.5 * math.sin(t * 0.13)
  local size = math.min(PW, PH) * 0.42 * (1 + 0.15 * math.sin(f * math.pi))
  local proj = {}
  for i = 1, NP do
    local a, b = A.p[i], B.p[i]
    local x = a[1] + (b[1] - a[1]) * e
    local y = a[2] + (b[2] - a[2]) * e
    local z = a[3] + (b[3] - a[3]) * e
    if warping then
      local sw = math.sin(f * math.pi) * 0.35
      local ang = sw * (1 + y)
      x, z = x * math.cos(ang) - z * math.sin(ang), x * math.sin(ang) + z * math.cos(ang)
      x, y, z = x * (1 + sw * 0.4), y * (1 + sw * 0.4), z * (1 + sw * 0.4)
    end
    y, z = y * c1 - z * s1, y * s1 + z * c1
    x, z = x * c2 + z * s2, -x * s2 + z * c2
    local rx, ry = x * cr - y * sr, x * sr + y * cr
    local d = z + dist
    proj[i] = { cx + rx * size * 3 / d, cy + ry * size * 3 / d, z }
  end
  local adj = f < 0.5 and A.adj or B.adj
  for i = 1, NP do
    local p = proj[i]
    local zz = p[3]
    local level = math.max(1, math.min(5, math.floor((1 - (zz + 1) / 2) * 5) + 1))
    local q = proj[i + 1]
    if adj[i] and q then line(p[1], p[2], q[1], q[2], zz, SHAPE_CH[level]) else plot(p[1], p[2], zz, SHAPE_CH[level]) end
  end
  -- colour family follows the shape, blending while it warps
  local h1, h2 = shapeHue(state.from), shapeHue(state.to)
  local dh = ((h2 - h1 + 0.5) % 1) - 0.5
  shapePalette(h1 + dh * e)

  -- pixels -> screen cells (each cell shows its two most common colours)
  local cells = {}
  for k, col in pairs(pc) do
    local px, py = k % PW, math.floor(k / PW)
    local ck = math.floor(py / 3) * W + math.floor(px / 2)
    local cell = cells[ck]
    if not cell then cell = {}; cells[ck] = cell end
    cell[(py % 3) * 2 + px % 2] = col
  end
  local rowsC, rowsF, rowsB = {}, {}, {}
  for y = 0, H - 1 do
    local c, fg, bg = {}, {}, {}
    for x = 0, W - 1 do
      local cell = cells[y * W + x]
      if cell then
        local cnt, c1, c2 = { f = 0 }, nil, nil
        for i = 0, 5 do local col = cell[i] or "f"; cnt[col] = (cnt[col] or 0) + 1 end
        for col, n in pairs(cnt) do
          if n > 0 then
            if not c1 or n > cnt[c1] then c2 = c1; c1 = col
            elseif not c2 or n > cnt[c2] then c2 = col end
          end
        end
        if not c2 then
          c[x + 1], fg[x + 1], bg[x + 1] = " ", "0", c1
        else
          local bits = 0
          for i = 0, 5 do if (cell[i] or "f") == c2 then bits = bits + 2 ^ i end end
          if bits >= 32 then c[x + 1], fg[x + 1], bg[x + 1] = string.char(128 + (63 - bits)), c1, c2
          else c[x + 1], fg[x + 1], bg[x + 1] = string.char(128 + bits), c2, c1 end
        end
      else
        c[x + 1], fg[x + 1], bg[x + 1] = " ", "0", "f"
      end
    end
    rowsC[y + 1], rowsF[y + 1], rowsB[y + 1] = table.concat(c), table.concat(fg), table.concat(bg)
  end
  for _, m in ipairs(mons) do
    for y = 1, H do
      local key = rowsC[y] .. rowsF[y] .. rowsB[y]
      if m.last[y] ~= key then m.p.setCursorPos(1, y); m.p.blit(rowsC[y], rowsF[y], rowsB[y]); m.last[y] = key end
    end
  end
end

-- ---------------------------------------------------------- main loop
math.randomseed(os.epoch("utc"))
setup()
term.clear(); term.setCursorPos(1, 1)
print("SPACE VOYAGE")
print("Tap the screen: boost + next shape")
print("Space = boost  Up/Down = speed  Q = quit")
if _G.__JB_TEST then
  _G.__JB = { hits = function() return { { id = "screen", x1 = 1, y1 = 1, x2 = W, y2 = H } } end, state = state,
    objects = objects, spawn = spawn }
end

local function now() return os.epoch("utc") / 1000 end
local last = now()
local timer = os.startTimer(0)
while true do
  local ev, a = os.pullEventRaw()
  if ev == "terminate" or (ev == "key" and a == keys.q) then break
  elseif ev == "timer" and a == timer then
    local t = now()
    render(t, math.min(0.3, t - last))
    last = t
    timer = os.startTimer(CFG.frame)
  elseif ev == "monitor_touch" then
    state.boostUntil = now() + 1.5
    nextShape(now())
  elseif ev == "key" and a == keys.space then state.boostUntil = now() + 1.5
  elseif ev == "key" and a == keys.up then state.speed = math.min(1.5, state.speed + 0.1)
  elseif ev == "key" and a == keys.down then state.speed = math.max(0.05, state.speed - 0.1)
  elseif ev == "monitor_resize" or ev == "peripheral" or ev == "peripheral_detach" then
    findMonitors()
    if #mons > 0 then
      applyPalette(); setup()
      for _, n in ipairs(nebula) do n.dots = nil end            -- re-make cloud patterns for the new size
    end
  end
end

for _, m in ipairs(mons) do
  for i = 0, 15 do m.p.setPaletteColour(2 ^ i, term.nativePaletteColour(2 ^ i)) end
  m.p.setBackgroundColour(colors.black); m.p.clear()
end
term.clear(); term.setCursorPos(1, 1); print("Space Voyage stopped.")
