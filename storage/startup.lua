-- Storage Manager launcher: grabs the newest storage.lua from GitHub, then runs it.
local URL = "https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-CC-Projects/main/storage/storage.lua"

local function update()
  local h = http.get(URL .. "?t=" .. os.epoch("utc"))
  if not h then return false end
  local code = h.readAll()
  h.close()
  if not code or #code < 1000 or not load(code, "storage") then return false end
  local f = fs.open("storage.lua", "w")
  f.write(code)
  f.close()
  return true
end

while true do
  term.clear(); term.setCursorPos(1, 1)
  print("Checking for Storage Manager updates...")
  if update() then print("Up to date.") else print("Update failed, using saved copy.") end
  if not fs.exists("storage.lua") then
    print("No storage.lua yet. Retrying in 10s...")
    sleep(10)
  elseif shell.run("storage.lua") then
    break
  else
    print("Crashed. Restarting in 5s (Ctrl+T to stop)...")
    sleep(5)
  end
end
