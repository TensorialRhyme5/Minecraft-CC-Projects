-- BAMBOO SCREEN launcher: grabs the newest screen.lua from GitHub, then runs it (install as "startup.lua").
local REPO = "TensorialRhyme5/Minecraft-CC-Projects"
local ref = "main"
local h0 = http.get("https://api.github.com/repos/" .. REPO .. "/commits/main", { Accept = "application/vnd.github.sha" })
if h0 then local sha = (h0.readAll() or ""):match("^%x+"); h0.close(); if sha and #sha == 40 then ref = sha end end
local h = http.get("https://raw.githubusercontent.com/" .. REPO .. "/" .. ref .. "/bamboo/screen.lua" ..
  (ref == "main" and ("?t=" .. os.epoch("utc")) or ""))
if h then
  local code = h.readAll(); h.close()
  if code and #code > 1000 and load(code, "screen") then
    local f = fs.open("screen.lua", "w"); f.write(code); f.close()
  end
end
while true do
  if fs.exists("screen.lua") and shell.run("screen.lua") then break end
  print("Screen stopped. Restarting in 5s (Ctrl+T to stop)...")
  sleep(5)
end
