-- MINER launcher: grabs the newest miner.lua from GitHub, then runs it (install as "startup.lua").
local URL = "https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-CC-Projects/main/mining/miner.lua"
local h = http.get(URL .. "?t=" .. os.epoch("utc"))
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
