-- MINER launcher: grabs the newest miner.lua from GitHub, then runs it (install as "startup.lua").
-- It asks GitHub for the newest version's id first, so a fresh push is picked up right away
-- (the plain link can be up to 5 minutes behind). Falls back to the plain link if that fails.
local REPO = "TensorialRhyme5/Minecraft-CC-Projects"
local function newest()
  if fs.exists("update_sha.txt") then                        -- handed to us by the mine computer (U key)
    local f = fs.open("update_sha.txt", "r"); local sha = f.readAll() or ""; f.close()
    fs.delete("update_sha.txt")
    sha = sha:match("^%x+")
    if sha and #sha == 40 then return sha end
  end
  local h = http.get("https://api.github.com/repos/" .. REPO .. "/commits/main", { Accept = "application/vnd.github.sha" })
  if h then
    local sha = (h.readAll() or ""):match("^%x+"); h.close()
    if sha and #sha == 40 then return sha end
  end
  return "main"
end
local ref = newest()
local h = http.get("https://raw.githubusercontent.com/" .. REPO .. "/" .. ref .. "/mining/miner.lua" ..
  (ref == "main" and ("?t=" .. os.epoch("utc")) or ""))
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
