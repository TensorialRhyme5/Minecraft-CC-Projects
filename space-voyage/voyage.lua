-- ============================================================
--  SPACE VOYAGE  -  3D visualizer for CC: Tweaked monitors
--  Fly through a 3D starfield toward a warping wireframe shape.
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
for _, m in ipairs({ peripheral.find("monitor") }) do
  if m.isColour() then mons[#mons + 1] = { p = m, name = peripheral.getName(m), last = {} } end
end
if #mons == 0 then error("No advanced monitor found. Attach one to this computer.", 0) end

-- ---------------------------------------------------------- palette
-- f background, c/7/8/0 star depth ramp (far -> near), 2/a/b/9/3 shape depth ramp (far -> near)
local PAL = {
  [colors.black] = 0x020308, [colors.brown] = 0x3c4058, [colors.gray] = 0x6c7292,
  [colors.lightGray] = 0xa8b0d0, [colors.white] = 0xf4f6ff,
}
local SHAPE_SLOTS = { colors.magenta, colors.purple, colors.blue, colors.cyan, colors.lightBlue } -- far -> near
local SHAPE_CH = { "2", "a", "b", "9", "3" }
local STAR_CH = { "c", "7", "8", "0" }
local function applyPalette()
  for _, m in ipairs(mons) do for c, v in pairs(PAL) do m.p.setPaletteColour(c, v) end end
end
applyPalette()

-- hue-shifting shape colours (HSV -> 0xRRGGBB)
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
local function shapePalette(t)
  local base = 0.55 + 0.12 * math.sin(t * 0.05)          -- drifts around cyan / blue / purple
  for i, slot in ipairs(SHAPE_SLOTS) do
    local depth = (i - 1) / (#SHAPE_SLOTS - 1)           -- 0 far .. 1 near
    local col = hsv(base + (1 - depth) * 0.12, 0.75 - depth * 0.35, 0.22 + depth * 0.78)
    for _, m in ipairs(mons) do m.p.setPaletteColour(slot, col) end
  end
end

-- ---------------------------------------------------------- screen
local W, H, PW, PH
local rowsC, rowsF, rowsB = {}, {}, {}
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

-- ---------------------------------------------------------- shapes (point clouds, sampled along their lines)
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
local function fromCurves(name, curves, fn)                   -- `curves` closed loops of equal length
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
  local cube = {}
  for x = -1, 1, 2 do for y = -1, 1, 2 do for z = -1, 1, 2 do cube[#cube + 1] = { x, y, z } end end end
  fromEdges("CUBE", cube)
  fromEdges("OCTAHEDRON", { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } })
  fromCurves("TORUS", 16, function(c, f)
    local u, v = c / 16 * 2 * math.pi, f * 2 * math.pi
    return { (0.68 + 0.32 * math.cos(v)) * math.cos(u), 0.32 * math.sin(v), (0.68 + 0.32 * math.cos(v)) * math.sin(u) }
  end)
  local P = (1 + math.sqrt(5)) / 2
  local ico = {}
  for _, a in ipairs({ -1, 1 }) do for _, b in ipairs({ -P, P }) do
    ico[#ico + 1] = { 0, a, b }; ico[#ico + 1] = { a, b, 0 }; ico[#ico + 1] = { b, 0, a }
  end end
  fromEdges("ICOSAHEDRON", ico)
  fromCurves("GYROSCOPE", 3, function(c, f)
    local a = f * 2 * math.pi
    local x, y = math.cos(a), math.sin(a)
    if c == 0 then return { x, y, 0 } elseif c == 1 then return { x, 0, y } else return { 0, x, y } end
  end)
  fromEdges("PYRAMID", { { 1, 1, 1 }, { 1, -1, -1 }, { -1, 1, -1 }, { -1, -1, 1 } })
  fromCurves("DOUBLE HELIX", 2, function(c, f)                -- two strands, each a long open spiral
    local a = f * 4 * math.pi + c * math.pi
    return { 0.45 * math.cos(a), f * 2 - 1, 0.45 * math.sin(a) }
  end)
  -- tesseract (cube inside a cube, corners joined)
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

-- ---------------------------------------------------------- stars (true 3D depth)
local stars = {}
local function newStar(s, far)
  s = s or {}
  s.x, s.y = (math.random() * 2 - 1) * 1.6, (math.random() * 2 - 1) * 1.2
  s.z = far and (0.85 + math.random() * 0.15) or (0.05 + math.random() * 0.95)
  return s
end
for i = 1, CFG.stars do stars[i] = newStar(nil, false) end

-- ---------------------------------------------------------- frame
local cellBits, cellZ, cellCol = {}, {}, {}
local function plot(px, py, z, col)
  px, py = math.floor(px + 0.5), math.floor(py + 0.5)
  if px < 0 or py < 0 or px >= PW or py >= PH then return end
  local cx, cy = math.floor(px / 2), math.floor(py / 3)
  local k = cy * W + cx
  local bit = 2 ^ ((py % 3) * 2 + px % 2)
  local b = cellBits[k] or 0
  if math.floor(b / bit) % 2 == 0 then cellBits[k] = b + bit end
  if not cellZ[k] or z < cellZ[k] then cellZ[k], cellCol[k] = z, col end
end
local function line(x1, y1, x2, y2, z, col)
  local n = math.max(1, math.ceil(math.max(math.abs(x2 - x1), math.abs(y2 - y1))))
  for i = 0, n do plot(x1 + (x2 - x1) * i / n, y1 + (y2 - y1) * i / n, z, col) end
end

local state = { speed = CFG.speed, boostUntil = 0, from = 1, to = 1, start = -100, nextAt = 0, idx = 1, spinExtra = 0 }
local function nextShape(t)
  state.from = state.to
  state.idx = state.idx % #SHAPES + 1
  state.to = state.idx
  state.start, state.nextAt = t, t + CFG.morph + CFG.hold
end

local function render(t, dt)
  cellBits, cellZ, cellCol = {}, {}, {}
  local cx, cy = PW / 2, PH / 2
  local focal = math.min(PW, PH) * 0.5
  local roll = math.sin(t * 0.07) * 0.35                    -- gentle banking
  local cr, sr = math.cos(roll), math.sin(roll)
  local yaw = math.sin(t * 0.05) * 0.25                      -- drifting heading
  local boost = t < state.boostUntil and 4 or 1
  local speed = state.speed * boost

  -- stars
  for _, s in ipairs(stars) do
    local z0 = s.z
    s.z = s.z - speed * dt
    if s.z <= 0.03 then newStar(s, true); z0 = s.z end
    local x, y = s.x + yaw * (1 - s.z), s.y
    local rx, ry = x * cr - y * sr, x * sr + y * cr
    local px, py = cx + rx / s.z * focal, cy + ry / s.z * focal
    if px < -5 or py < -5 or px > PW + 5 or py > PH + 5 then
      newStar(s, true)
    else
      local col = s.z > 0.7 and STAR_CH[1] or (s.z > 0.42 and STAR_CH[2] or (s.z > 0.2 and STAR_CH[3] or STAR_CH[4]))
      local zz = 5 + s.z                                     -- stars always sit behind the shape
      plot(px, py, zz, col)
      if s.z < 0.2 then plot(px + 1, py, zz, col) end        -- close stars are a little bigger
      if s.z < 0.12 then plot(px, py + 1, zz, col); plot(px + 1, py + 1, zz, col) end
      -- short faint trail only for very close stars (long streaks only while boosting)
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

  -- warping shape
  if state.nextAt == 0 then state.nextAt = t + CFG.hold end
  if t >= state.nextAt then nextShape(t) end
  local f = math.max(0, math.min(1, (t - state.start) / CFG.morph))
  local e = f * f * (3 - 2 * f)
  local warping = f > 0 and f < 1
  local A, B = SHAPES[state.from], SHAPES[state.to]
  state.spinExtra = state.spinExtra + (warping and math.sin(f * math.pi) * 1.5 or 0) * dt
  local a1, a2 = t * 0.35 + state.spinExtra, t * 0.5 + state.spinExtra * 0.7
  local c1, s1, c2, s2 = math.cos(a1), math.sin(a1), math.cos(a2), math.sin(a2)
  local dist = 3.4 + 0.5 * math.sin(t * 0.13)                -- drifts closer / farther
  local size = math.min(PW, PH) * 0.42 * (1 + 0.15 * math.sin(f * math.pi))
  local proj = {}
  for i = 1, NP do
    local a, b = A.p[i], B.p[i]
    local x = a[1] + (b[1] - a[1]) * e
    local y = a[2] + (b[2] - a[2]) * e
    local z = a[3] + (b[3] - a[3]) * e
    if warping then                                          -- swirl outward mid-warp
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
    local level = math.max(1, math.min(5, math.floor((1 - (zz + 1) / 2) * 5) + 1))   -- near = 5
    local col = SHAPE_CH[level]
    local q = proj[i + 1]
    if adj[i] and q then line(p[1], p[2], q[1], q[2], zz, col) else plot(p[1], p[2], zz, col) end
  end

  -- cells -> screen rows
  for y = 0, H - 1 do
    local c, fg, bg = {}, {}, {}
    for x = 0, W - 1 do
      local k = y * W + x
      local bits = cellBits[k]
      if bits then
        local col = cellCol[k]
        if bits >= 32 then c[x + 1], fg[x + 1], bg[x + 1] = string.char(128 + (63 - bits)), "f", col
        else c[x + 1], fg[x + 1], bg[x + 1] = string.char(128 + bits), col, "f" end
      else
        c[x + 1], fg[x + 1], bg[x + 1] = " ", "0", "f"
      end
    end
    rowsC[y + 1], rowsF[y + 1], rowsB[y + 1] = table.concat(c), table.concat(fg), table.concat(bg)
  end
  shapePalette(t)
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
if _G.__JB_TEST then _G.__JB = { hits = function() return { { id = "screen", x1 = 1, y1 = 1, x2 = W, y2 = H } } end, state = state } end

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
    state.boostUntil = now() + 1.5
    nextShape(now())
  elseif ev == "key" and a == keys.space then state.boostUntil = now() + 1.5
  elseif ev == "key" and a == keys.up then state.speed = math.min(1.5, state.speed + 0.1)
  elseif ev == "key" and a == keys.down then state.speed = math.max(0.05, state.speed - 0.1)
  elseif ev == "monitor_resize" or ev == "peripheral" or ev == "peripheral_detach" then
    mons = {}
    for _, m in ipairs({ peripheral.find("monitor") }) do
      if m.isColour() then mons[#mons + 1] = { p = m, name = peripheral.getName(m), last = {} } end
    end
    if #mons > 0 then applyPalette(); setup() end
  end
end

for _, m in ipairs(mons) do
  for i = 0, 15 do m.p.setPaletteColour(2 ^ i, term.nativePaletteColour(2 ^ i)) end
  m.p.setBackgroundColour(colors.black); m.p.clear()
end
term.clear(); term.setCursorPos(1, 1); print("Space Voyage stopped.")
