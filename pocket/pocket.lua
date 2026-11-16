-- ============================================================
--  POCKET REMOTE  -  advanced pocket computer + wireless/ender modem
--  ITEMS tab: search the storage, send items straight to you (or the
--             barrel), put your inventory away.
--  MUSIC tab: control the Space Jukebox.
--  Repo: TensorialRhyme5/Minecraft-CC-Projects
-- ============================================================

local STORE_PROTO, MUSIC_PROTO = "storagenet", "spacejukebox"
local MUSIC_REPO = "https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-Music/main/"

local W, H = term.getSize()
if not term.isColour() then error("Needs an ADVANCED pocket computer (colour screen).", 0) end

local netOn = false
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and pcall(rednet.open, name) then netOn = true end
end

-- ---------------------------------------------------------- SHA-256 (signs pocket remote requests)
local band, bor, bxor, bnot, rrot, rshift = bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.rrotate, bit32.rshift
local SHA_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local function sha256(msg)
  msg = tostring(msg)
  local len = #msg
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
  local bits = len * 8
  local hi = math.floor(bits / 4294967296)
  msg = msg .. string.char(
    band(rshift(hi, 24), 255), band(rshift(hi, 16), 255), band(rshift(hi, 8), 255), band(hi, 255),
    band(rshift(bits, 24), 255), band(rshift(bits, 16), 255), band(rshift(bits, 8), 255), band(bits, 255))
  local h0, h1, h2, h3, h4, h5, h6, h7 =
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = bor(a * 16777216, b * 65536, c * 256, d)
    end
    for i = 16, 63 do
      local s0 = bxor(rrot(w[i - 15], 7), rrot(w[i - 15], 18), rshift(w[i - 15], 3))
      local s1 = bxor(rrot(w[i - 2], 17), rrot(w[i - 2], 19), rshift(w[i - 2], 10))
      w[i] = band(w[i - 16] + s0 + w[i - 7] + s1, 0xffffffff)
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 0, 63 do
      local S1 = bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = band(h + S1 + ch + SHA_K[i + 1] + w[i], 0xffffffff)
      local S0 = bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = band(S0 + maj, 0xffffffff)
      h, g, f, e, d, c, b, a = g, f, e, band(d + t1, 0xffffffff), c, b, a, band(t1 + t2, 0xffffffff)
    end
    h0, h1, h2, h3 = band(h0 + a, 0xffffffff), band(h1 + b, 0xffffffff), band(h2 + c, 0xffffffff), band(h3 + d, 0xffffffff)
    h4, h5, h6, h7 = band(h4 + e, 0xffffffff), band(h5 + f, 0xffffffff), band(h6 + g, 0xffffffff), band(h7 + h, 0xffffffff)
  end
  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

-- ---------------------------------------------------------- drawing
local C = {
  bg = colors.black, panel = colors.gray, dim = colors.lightGray, text = colors.white,
  accent = colors.yellow, good = colors.lime, bad = colors.red, cyan = colors.cyan, purple = colors.purple,
  blue = colors.blue, light = colors.lightBlue, pink = colors.magenta,
}
local hex = {}
for i = 0, 15 do hex[2 ^ i] = ("0123456789abcdef"):sub(i + 1, i + 1) end
local fbC, fbF, fbB = {}, {}, {}
local function clear()
  for y = 1, H do fbC[y], fbF[y], fbB[y] = {}, {}, {}; for x = 1, W do fbC[y][x], fbF[y][x], fbB[y][x] = " ", "0", "f" end end
end
local function setCell(x, y, ch, fg, bg)
  if x < 1 or x > W or y < 1 or y > H then return end
  fbC[y][x] = ch; if fg then fbF[y][x] = hex[fg] end; if bg then fbB[y][x] = hex[bg] end
end
local function text(x, y, s, fg, bg) for i = 1, #s do setCell(x + i - 1, y, s:sub(i, i), fg, bg) end end
local function center(y, s, fg, bg) text(math.floor((W - #s) / 2) + 1, y, s, fg, bg) end
local function fill(x1, y1, x2, y2, bg) for y = y1, y2 do for x = x1, x2 do setCell(x, y, " ", C.text, bg) end end end
local function present()
  for y = 1, H do term.setCursorPos(1, y); term.blit(table.concat(fbC[y]), table.concat(fbF[y]), table.concat(fbB[y])) end
end
local function fit(s, w) s = tostring(s or ""); if #s > w then return s:sub(1, math.max(1, w - 1)) .. "." end return s end
local function now() return os.epoch("utc") / 1000 end
local function commas(n)
  local s = tostring(math.floor(n)); local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (r:gsub("^,", ""))
end
local function short(n)
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) elseif n >= 1e5 then return string.format("%dk", math.floor(n / 1000)) end
  return commas(n)
end
local function fmtTime(sec) sec = math.max(0, math.floor(sec or 0)); return string.format("%d:%02d", math.floor(sec / 60), sec % 60) end

local hits, flash = {}, {}
local function hit(id, x1, y1, x2, y2, fn) hits[#hits + 1] = { id = id, x1 = x1, y1 = y1, x2 = x2, y2 = y2, fn = fn } end
local function button(id, x1, y1, x2, y2, label, fg, bg, fn)
  if flash[id] and now() - flash[id] < 0.15 then fg, bg = C.bg, C.text end
  fill(x1, y1, x2, y2, bg)
  text(x1 + math.floor((x2 - x1 + 1 - #label) / 2), math.floor((y1 + y2) / 2), label, fg, bg)
  hit(id, x1, y1, x2, y2, fn)
end

-- ---------------------------------------------------------- state
local UI = { tab = "items", q = "", page = 1, sel = nil, toMe = true, searchAt = 0, code = "" }
local S = { id = nil, results = {}, found = 0, info = nil, infoAt = 0, lastQ = nil, lookAt = -100 }
local M = { st = nil, at = 0, id = nil, lists = nil }

-- pairing: the storage shows a code, you type it here; requests are then signed with a key made
-- from that code (the code itself never goes over the air)
local KEYFILE = "storage_pairing.txt"
local PAIRED = nil                    -- { key, player }
if fs.exists(KEYFILE) then
  local f = fs.open(KEYFILE, "r")
  local ok, d = pcall(textutils.unserialize, f.readAll()); f.close()
  if ok and type(d) == "table" and d.key then PAIRED = d end
end
local lastCtr = 0
local function nextCtr()
  local c = os.epoch("utc")
  if c <= lastCtr then c = lastCtr + 1 end
  lastCtr = c
  return c
end
local function canon(msg)
  return table.concat({ tostring(msg.type), tostring(msg.q or ""), tostring(msg.id or ""), tostring(msg.n or ""), tostring(msg.to or ""),
    tostring(msg.off or ""), tostring(msg.lim or "") }, "|")
end
local function storageSend(msg)
  if not S.id or not PAIRED then return end
  msg.dev = os.getComputerID()
  msg.ctr = nextCtr()
  msg.mac = sha256(PAIRED.key .. "|" .. msg.ctr .. "|" .. canon(msg))
  rednet.send(S.id, msg, STORE_PROTO)
end
local function sendPair()
  local code = UI.code:upper()
  if #code ~= 8 then UI.pairMsg = "The code has 8 letters/numbers"; return end
  local dev = os.getComputerID()
  local nonce = tostring(math.random(1, 2 ^ 30)) .. tostring(os.epoch("utc"))
  UI.pairing = code
  UI.pairMsg = "Pairing..."
  local msg = { type = "pair", dev = dev, nonce = nonce, proof = sha256(code .. "|pair|" .. dev .. "|" .. nonce) }
  if S.id then rednet.send(S.id, msg, STORE_PROTO) else rednet.broadcast(msg, STORE_PROTO) end
end
local function findStorage()
  S.lookAt = now()
  local id = rednet.lookup(STORE_PROTO)
  if type(id) == "table" then id = id[1] end
  S.id = id
end
local ROWS = 13                         -- result rows on screen (set properly below)
local function search()
  UI.searchAt = 0; S.lastQ = UI.q
  storageSend({ type = "search", q = UI.q, off = (UI.page - 1) * ROWS, lim = ROWS })
end
local function musicSend(msg)
  if M.id then rednet.send(M.id, msg, MUSIC_PROTO) else rednet.broadcast(msg, MUSIC_PROTO) end
end
local function musicOnline() return M.st ~= nil and now() - M.at < 4 end
local function musicPos()
  local st = M.st
  if not st or not st.title then return 0 end
  if st.anchor then return now() - st.anchor end
  return st.pos or 0
end

-- ---------------------------------------------------------- ITEMS tab
local ROWS_TOP, ROWS_BOT = 3, H - 5
ROWS = ROWS_BOT - ROWS_TOP + 1
local function drawPairing()
  center(3, "PAIR WITH STORAGE", C.accent)
  text(2, 5, "On the storage screen:", C.dim)
  text(2, 6, "REMOTES > tap your name", C.text)
  text(2, 8, "then type the code here:", C.dim)
  fill(4, 10, W - 3, 12, C.panel)
  local shown = UI.code:upper()
  shown = (shown:sub(1, 4) .. (#shown > 4 and ("-" .. shown:sub(5)) or "")) .. (#shown < 8 and "_" or "")
  center(11, shown, C.accent, C.panel)
  button("pairgo", 4, 14, W - 3, 16, "PAIR", C.bg, #UI.code == 8 and C.good or C.panel, sendPair)
  if UI.pairMsg then center(18, fit(UI.pairMsg, W), UI.pairMsg:find("ail") and C.bad or C.dim) end
  if not S.id then center(H, "(looking for storage...)", C.panel) end
end

local function drawItems()
  if not PAIRED then drawPairing(); return end
  -- search box
  fill(1, 2, W, 2, C.panel)
  if UI.q == "" then text(2, 2, "type to search...", C.dim, C.panel)
  else text(2, 2, fit(UI.q, W - 3) .. "_", C.text, C.panel) end
  if UI.q ~= "" then button("clr", W - 1, 2, W, 2, "x", C.bad, C.panel, function() UI.q = ""; UI.page = 1; UI.searchAt = now() end) end

  if not netOn then center(6, "No modem!", C.bad); center(7, "Craft this pocket with a", C.dim); center(8, "wireless or ender modem", C.dim)
  elseif not S.id then center(6, "Looking for storage...", C.dim); center(8, "(storage computer needs", C.dim); center(9, "a wireless modem too)", C.dim)
  elseif UI.sel then
    local it = UI.sel
    text(2, 4, fit(it.name, W - 2), C.accent)
    text(2, 5, it.id:gsub("#.*$", ""), C.dim)
    text(2, 7, "In storage: ", C.dim); text(14, 7, commas(it.count), C.cyan)
    text(2, 9, "Send to:", C.accent)
    local me = UI.toMe and (not S.info or S.info.im)
    button("tome", 11, 9, 17, 9, fit(PAIRED and PAIRED.player or "ME", 7), me and C.bg or C.text, me and C.cyan or C.panel, function() UI.toMe = true end)
    button("topk", 19, 9, W - 1, 9, "BARREL", me and C.text or C.bg, me and C.panel or C.good, function() UI.toMe = false end)
    local amounts = { { "1", 1 }, { "16", 16 }, { "64", 64 }, { "ALL", math.huge } }
    for i, a in ipairs(amounts) do
      local x = 2 + (i - 1) * 6
      button("n" .. a[1], x, 11, x + 4, 13, a[1], C.bg, me and C.cyan or C.good, function()
        storageSend({ type = "send", id = it.id, n = a[2], to = me and "me" or "pickup" })
        S.info = S.info or {}
        S.info.status = "Sending " .. a[1] .. " " .. it.name .. "..."
      end)
    end
    if S.info and not S.info.im and UI.toMe then
      text(2, 15, "No Inventory Manager:", C.bad); text(2, 16, "sending to the barrel", C.dim)
    end
    button("back", 2, ROWS_BOT, W - 1, ROWS_BOT, "\17 BACK", C.bg, C.accent, function() UI.sel = nil end)
  else
    local rows = ROWS
    local pages = math.max(1, math.ceil(S.found / rows))
    if UI.page > pages and S.lastQ == UI.q and S.got then UI.page = pages; search() end
    if #S.results == 0 then center(6, S.lastQ and "Nothing found" or "Searching...", C.dim) end
    for r = 1, rows do
      local it = S.results[r]
      if not it then break end
      local y = ROWS_TOP + r - 1
      local bg = (r % 2 == 0) and C.bg or C.blue
      fill(1, y, W, y, bg)
      local n = short(it.count)
      text(1, y, fit(it.name, W - #n - 2), it.close and C.dim or C.text, bg)
      text(W - #n + 1, y, n, C.cyan, bg)
      hit("it" .. r, 1, y, W, y, function() UI.sel = it end)
    end
    -- pager
    local y = ROWS_BOT + 1
    local pg = UI.page .. "/" .. pages .. "  (" .. S.found .. ")"
    center(y, pg, C.dim)
    if UI.page > 1 then button("prev", 1, y, 4, y, "\17", C.accent, C.panel, function() UI.page = UI.page - 1; search() end) end
    if UI.page < pages then button("next", W - 3, y, W, y, "\16", C.accent, C.panel, function() UI.page = UI.page + 1; search() end) end
  end
  -- bottom: put away inventory
  if S.id and not UI.sel then
    local can = S.info and S.info.im
    button("dump", 1, H - 3, W, H - 2, "PUT AWAY MY INVENTORY", can and C.bg or C.dim, can and C.cyan or C.panel, function()
      if not can then S.info = S.info or {}; S.info.status = "Needs an Inventory Manager"; return end
      storageSend({ type = "dump" })
      S.info.status = "Putting your inventory away..."
    end)
  end
  local st = S.info and (S.info.busy or S.info.status) or ""
  text(1, H - 1, fit(st, W), C.dim)
  if S.info and S.info.slots then
    text(1, H, fit(short(S.info.total or 0) .. " items, " .. math.floor((S.info.used or 0) / math.max(1, S.info.slots) * 100) .. "% full", W), C.panel)
  end
end

-- ---------------------------------------------------------- MUSIC tab
local function shuffled(n)
  local t = {}
  for i = 1, n do t[i] = i end
  for i = n, 2, -1 do local j = math.random(1, i); t[i], t[j] = t[j], t[i] end
  return t
end
local function drawMusic(t)
  local st = M.st or {}
  if not musicOnline() then
    center(6, "Looking for the jukebox...", C.dim)
    center(8, netOn and "(out of range?)" or "No modem!", netOn and C.dim or C.bad)
  else
    if st.power == false then center(4, "Jukebox is off", C.dim)
    elseif not st.title then center(4, "Nothing playing", C.dim)
    else
      local title = st.title or ""
      if #title > W - 2 then
        local pad = title .. "   " .. title
        local off = math.floor(t * 4) % (#title + 3)
        title = pad:sub(off + 1, off + W - 2)
      end
      text(2, 3, title, C.accent)
      text(2, 4, fit(st.artist or "", W - 2), C.dim)
      text(2, 5, fit(st.names and st.curPl and st.names[st.curPl] or "", W - 2), C.purple)
    end
    local dur = st.dur or 0
    local pos = math.max(0, math.min(dur, musicPos()))
    local bw = W - 2
    local f = dur > 0 and math.floor(pos / dur * bw + 0.5) or 0
    for i = 1, bw do setCell(1 + i, 7, "\140", i <= f and C.light or C.panel, C.bg) end
    if dur > 0 then hit("seek", 2, 7, W - 1, 7, function(x) musicSend({ cmd = "seek", sec = (x - 2) / math.max(1, bw - 1) * dur }) end) end
    text(2, 8, fmtTime(pos), C.dim)
    local d = fmtTime(dur); text(W - #d, 8, d, C.dim)
    local playing = st.title and not st.paused
    button("mprev", 2, 10, 8, 12, "\17\17", C.text, C.panel, function() musicSend({ cmd = "prev" }) end)
    button("mplay", 10, 10, 17, 12, playing and "| |" or "\16", C.bg, C.good, function() musicSend({ cmd = "toggle" }) end)
    button("mnext", 19, 10, W - 1, 12, "\16\16", C.text, C.panel, function() musicSend({ cmd = "next" }) end)
    -- jukebox volume
    local vol = tonumber(st.volume)
    text(2, 14, "VOL", C.accent)
    button("vdn", 6, 14, 7, 14, "-", C.text, C.panel, function() if vol then musicSend({ cmd = "volume", vol = vol - 0.1 }) end end)
    local vx1, vx2 = 9, W - 7
    local vw = vx2 - vx1 + 1
    local vf = vol and math.floor(vol / 3 * vw + 0.5) or 0
    for i = 1, vw do setCell(vx1 + i - 1, 14, " ", C.text, i <= vf and C.good or C.panel) end
    if vol then hit("vbar", vx1, 14, vx2, 14, function(x) musicSend({ cmd = "volume", vol = (x - vx1 + 1) / vw * 3 }) end) end
    button("vup", vx2 + 2, 14, vx2 + 3, 14, "+", C.text, C.panel, function() if vol then musicSend({ cmd = "volume", vol = vol + 0.1 }) end end)
    local pct = vol and (math.floor(vol * 100 + 0.5) .. "%") or ""
    text(W - #pct + 1, 15, pct, C.dim)
    -- playlists (tap = shuffle-play)
    local names = st.names or {}
    local half = math.floor((W - 1) / 2)
    for i = 1, math.min(4, #names) do
      local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
      local x1 = 1 + col * (half + 1)
      local y1 = 16 + row * 2
      local cur = st.curPl == i
      button("pl" .. i, x1, y1, x1 + half - 1, y1 + 1, fit(names[i], half - 1), cur and C.bg or C.text, cur and C.accent or C.purple, function()
        local n = M.lists and M.lists[i] and #M.lists[i].songs
        if n and n > 0 then musicSend({ cmd = "play", pl = i, order = shuffled(n), idx = 1 }) end
      end)
    end
  end
end

-- ---------------------------------------------------------- main
local function draw(t)
  clear(); hits = {}
  local items = UI.tab == "items"
  button("tabI", 1, 1, 13, 1, "ITEMS", items and C.bg or C.text, items and C.accent or C.panel, function() UI.tab = "items"; search() end)
  button("tabM", 14, 1, W, 1, "MUSIC", items and C.text or C.bg, items and C.panel or C.accent, function() UI.tab = "music" end)
  if items then drawItems() else drawMusic(t) end
  present()
end

local function loadLists()
  local h = http.get(MUSIC_REPO .. "playlists.json?t=" .. os.epoch("utc"))
  if not h then return end
  local ok, data = pcall(textutils.unserializeJSON, h.readAll()); h.close()
  if not ok or type(data) ~= "table" then return end
  local list = {}
  for name, songs in pairs(data) do list[#list + 1] = { name = name, songs = songs } end
  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)   -- same order as the jukebox
  M.lists = list
end

local function main()
  math.randomseed(os.epoch("utc"))
  local timer = os.startTimer(0)
  local lastInfo = 0
  while true do
    local ev, a, b, c = os.pullEventRaw()
    local t = now()
    if ev == "terminate" then return
    elseif ev == "timer" and a == timer then
      if not S.id and t - S.lookAt > 5 then findStorage(); if S.id then search() end end
      if UI.searchAt > 0 and t >= UI.searchAt then search() end
      if S.id and UI.tab == "items" and t - lastInfo > ((S.info and S.info.busy) and 1 or 5) then
        lastInfo = t
        if UI.sel then storageSend({ type = "info" }) else search() end
      end
      if UI.tab == "music" and not musicOnline() and t - (M.helloAt or 0) > 3 then M.helloAt = t; musicSend({ cmd = "hello" }) end
      draw(t)
      timer = os.startTimer(0.2)
    elseif ev == "mouse_click" then
      for i = #hits, 1, -1 do
        local h = hits[i]
        if b >= h.x1 and b <= h.x2 and c >= h.y1 and c <= h.y2 then flash[h.id] = t; h.fn(b, c); break end
      end
      draw(t)
    elseif ev == "mouse_scroll" and UI.tab == "items" and not UI.sel then
      UI.page = math.max(1, UI.page + a); search(); draw(t)
    elseif ev == "char" and UI.tab == "items" and not PAIRED then
      if a:match("[%w]") and #UI.code < 8 then UI.code = UI.code .. a:upper() end
      draw(t)
    elseif ev == "key" and UI.tab == "items" and not PAIRED then
      if a == keys.backspace then UI.code = UI.code:sub(1, -2) elseif a == keys.enter then sendPair() end
      draw(t)
    elseif ev == "char" and UI.tab == "items" then
      UI.q = UI.q .. a; UI.page = 1; UI.sel = nil; UI.searchAt = t + 0.35; draw(t)
    elseif ev == "key" and UI.tab == "items" then
      if a == keys.backspace then UI.q = UI.q:sub(1, -2); UI.page = 1; UI.sel = nil; UI.searchAt = t + 0.35; draw(t)
      elseif a == keys.enter then search() end
    elseif ev == "rednet_message" then
      local msg = b
      if c == STORE_PROTO and type(msg) == "table" and msg.dev ~= nil and tonumber(msg.dev) ~= os.getComputerID() then
        -- a reply meant for another pocket: ignore
      elseif c == STORE_PROTO and type(msg) == "table" and msg.type == "paired" then
        if msg.ok and UI.pairing then
          PAIRED = { key = sha256(UI.pairing .. "|key|" .. os.getComputerID()), player = msg.player }
          local f = fs.open(KEYFILE, "w"); f.write(textutils.serialize(PAIRED)); f.close()
          S.id, UI.code, UI.pairing, UI.pairMsg = a, "", nil, nil
          search()
        else
          UI.pairMsg = "Pairing failed: " .. tostring(msg.why or "?")
        end
      elseif c == STORE_PROTO and type(msg) == "table" and msg.type == "denied" then
        if msg.why == "not paired" then PAIRED = nil; fs.delete(KEYFILE); UI.pairMsg = "This pocket was removed - pair again" end
      elseif c == STORE_PROTO and type(msg) == "table" then
        S.id = a
        if msg.type == "results" then
          if msg.q == UI.q and (msg.off or 0) == (UI.page - 1) * ROWS then S.results, S.found, S.got = msg.items or {}, msg.found or 0, true end
          if UI.sel then for _, it in ipairs(msg.items or {}) do if it.id == UI.sel.id then UI.sel.count = it.count end end end
        end
        if msg.type == "results" or msg.type == "info" then S.info, S.infoAt = msg, t end
      elseif c == MUSIC_PROTO and type(msg) == "table" and msg.type == "state" then
        M.st, M.at, M.id = msg, t, a
      end
    end
  end
end

parallel.waitForAny(main, function() loadLists(); while true do os.pullEvent("pocket_never") end end)
term.setBackgroundColour(colors.black); term.clear(); term.setCursorPos(1, 1)
print("Pocket remote closed.")
