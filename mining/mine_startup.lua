-- MINE COMPUTER launcher: the mine storage (same program as home) + the turtle base in a second tab.
-- Install on the mine's Advanced Computer as "startup.lua". Updates itself from GitHub on every boot.
local REPO = "TensorialRhyme5/Minecraft-CC-Projects"
-- the newest version's id, so a fresh push is picked up right away (the plain link can lag 5 minutes)
local function newest()
  if fs.exists("update_sha.txt") then                        -- written by the Turtles tab (U key)
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
local REF = newest()
local RAW = "https://raw.githubusercontent.com/" .. REPO .. "/" .. REF .. "/"
local function get(path, file)
  local h = http.get(RAW .. path .. (REF == "main" and ("?t=" .. os.epoch("utc")) or ""))
  if not h then return false end
  local code = h.readAll(); h.close()
  if not code or #code < 200 or not load(code, file) then return false end
  local f = fs.open(file, "w"); f.write(code); f.close()
  return true
end
local JUNK = {
  "minecraft:stone", "minecraft:cobblestone", "minecraft:deepslate", "minecraft:cobbled_deepslate",
  "minecraft:tuff", "minecraft:granite", "minecraft:diorite", "minecraft:andesite", "minecraft:calcite",
  "minecraft:dirt", "minecraft:gravel", "minecraft:sand", "minecraft:netherrack", "minecraft:blackstone",
  "minecraft:basalt", "minecraft:smooth_basalt", "minecraft:dripstone_block",
}

-- first boot: the plain wooden chests are the drop-off chests and the fuel chest
local function setup()
  term.clear(); term.setCursorPos(1, 1)
  term.setTextColour(colors.yellow); print("MINE setup"); term.setTextColour(colors.white)
  local chests = {}
  for _, name in ipairs(peripheral.getNames()) do
    if name:find("^minecraft:chest") then chests[#chests + 1] = name end
  end
  table.sort(chests)
  local fuel
  for i, name in ipairs(chests) do
    local l = peripheral.call(name, "list")
    local n, coalOnly = 0, true
    for _, it in pairs(l) do n = n + 1; if it.name ~= "minecraft:coal" and it.name ~= "minecraft:charcoal" then coalOnly = false end end
    print(i .. ") " .. name .. "  " .. (n == 0 and "empty" or (coalOnly and "only coal" or "has items")))
    if n > 0 and coalOnly then fuel = fuel and -1 or i end
  end
  if #chests == 0 then print("No wooden chests found on the network - connect the drop-off chests and reboot."); error("", 0) end
  if fuel and fuel > 0 then
    print("Fuel chest = " .. chests[fuel] .. " (the one with only coal)")
  elseif #chests >= 3 then
    write("Which number is the FUEL chest? ")
    fuel = tonumber(read())
  end
  local inputs, exclude = {}, {}
  for i, name in ipairs(chests) do
    if i == fuel then exclude[#exclude + 1] = name else inputs[#inputs + 1] = name end
  end
  local cfg = { title = "MINE", inputs = inputs, exclude = exclude, junk = JUNK, keep = 1000,
    junkTo = "copper", otherTo = "iron" }
  local f = fs.open("storage_config.txt", "w"); f.write(textutils.serialize(cfg)); f.close()
  print("Drop-off chests: " .. table.concat(inputs, ", "))
  print("Saved. (Delete storage_config.txt to redo this.)")
  sleep(3)
end

term.clear(); term.setCursorPos(1, 1)
print("Checking for updates...")
get("storage/storage.lua", "storage.lua")
get("mining/minebase.lua", "minebase.lua")
if not fs.exists("storage_config.txt") then setup() end
if multishell then
  local id = shell.openTab("minebase.lua")
  multishell.setTitle(id, "Turtles")
  multishell.setTitle(multishell.getCurrent(), "Storage")
end
while true do
  if fs.exists("storage.lua") and shell.run("storage.lua") then break end
  print("Storage stopped. Restarting in 5s (Ctrl+T to stop)...")
  sleep(5)
end
