-- Pocket Remote launcher: grabs the newest pocket.lua from GitHub, then runs it.
local URL = "https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-CC-Projects/main/pocket/pocket.lua"

local function update()
  local h = http.get(URL .. "?t=" .. os.epoch("utc"))
  if not h then return false end
  local code = h.readAll()
  h.close()
  if not code or #code < 500 or not load(code, "pocket") then return false end
  local f = fs.open("pocket.lua", "w")
  f.write(code)
  f.close()
  return true
end

term.clear(); term.setCursorPos(1, 1)
print("Checking for updates...")
if update() then print("Up to date.") else print("Update failed, using saved copy.") end
if fs.exists("pocket.lua") then
  shell.run("pocket.lua")
else
  print("No pocket.lua yet - check the internet connection and reboot.")
end
