-- Ocean Voyage launcher: grabs the newest ocean.lua from GitHub, then runs it.
local URL = "https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-CC-Projects/main/ocean-voyage/ocean.lua"

local function update()
  local h = http.get(URL .. "?t=" .. os.epoch("utc"))
  if not h then return false end
  local code = h.readAll()
  h.close()
  if not code or #code < 1000 or not load(code, "ocean") then return false end
  local f = fs.open("ocean.lua", "w")
  f.write(code)
  f.close()
  return true
end

while true do
  term.clear(); term.setCursorPos(1, 1)
  print("Checking for Ocean Voyage updates...")
  if update() then print("Up to date.") else print("Update failed, using saved copy.") end
  if not fs.exists("ocean.lua") then
    print("No ocean.lua yet. Retrying in 10s...")
    sleep(10)
  elseif shell.run("ocean.lua") then
    break
  else
    print("Crashed. Restarting in 5s (Ctrl+T to stop)...")
    sleep(5)
  end
end
