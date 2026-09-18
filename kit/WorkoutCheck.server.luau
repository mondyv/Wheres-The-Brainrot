-- WorkoutCheck — paste as a Script in ServerScriptService (not StarterPlayer).
-- Play → View → Output. Fix every NEED line.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")
local SoundService = game:GetService("SoundService")

local missing = 0

local function ok(msg: string)
	print("[WorkoutCheck] OK   ", msg)
end

local function bad(msg: string)
	missing += 1
	warn("[WorkoutCheck] NEED ", msg)
end

print("========== WORKOUT KIT CHECK ==========")
task.wait(0.5)

if not script:IsDescendantOf(ServerScriptService) then
	bad("MOVE WorkoutCheck into ServerScriptService (it is in the wrong folder)")
end

local gears = ServerScriptService:FindFirstChild("Gears", true)
if gears and gears:IsA("Script") and not gears:IsA("LocalScript") then
	ok("ServerScriptService.Gears")
else
	bad("Move Gears into ServerScriptService as a server Script — StarterPlayerScripts will never run it")
end

local gearService = ServerScriptService:FindFirstChild("GearService", true)
if gearService and gearService:IsA("ModuleScript") then
	ok("ServerScriptService.GearService")
else
	bad("Move GearService ModuleScript into ServerScriptService (next to Gears)")
end

local cash = ServerScriptService:FindFirstChild("WorkoutCash", true)
if cash and cash:IsA("Script") then
	ok("WorkoutCash")
else
	bad("Move WorkoutCash into ServerScriptService")
end

local sps = StarterPlayer:FindFirstChild("StarterPlayerScripts")
if sps then
	for _, name in { "Gears", "GearService", "WorkoutCash", "WorkoutSetup", "WorkoutCheck", "WorkoutLicense" } do
		local wrong = sps:FindFirstChild(name) or sps:FindFirstChild(name .. " ")
		if wrong then
			bad(name .. " is in StarterPlayerScripts — drag it to ServerScriptService")
		end
	end
	local kit = sps:FindFirstChild("WorkoutKit")
	if kit and kit:IsA("LocalScript") then
		ok("WorkoutKit LocalScript")
	elseif kit then
		bad("WorkoutKit must be a LocalScript (it is " .. kit.ClassName .. ")")
	else
		bad("WorkoutKit LocalScript in StarterPlayerScripts")
	end
end

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if remotes and remotes:FindFirstChild("StartWorkout") then
	ok("Remotes exist (Gears is running)")
else
	bad("No remotes — Gears is not running on the server")
end

local shared = ReplicatedStorage:FindFirstChild("Shared")
if shared and shared:FindFirstChild("GearConfig") then
	ok("Shared.GearConfig")
else
	bad("ReplicatedStorage.Shared.GearConfig")
end

local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
if assets and assets:FindFirstChild("Gears") then
	ok("EssentialAssets.Gears")
else
	bad("EssentialAssets.Gears (not Workspace.Gears)")
end

local main = StarterGui:FindFirstChild("Main")
local upgrades = main and main:FindFirstChild("Frames") and main.Frames:FindFirstChild("Upgrades")
if upgrades and upgrades:FindFirstChild("Container") then
	ok("Main.Frames.Upgrades.Container")
else
	bad("StarterGui.Main.Frames.Upgrades.Container with a row named 1")
end

if SoundService:FindFirstChild("SoundEffects") then
	ok("SoundEffects")
else
	bad("SoundService.SoundEffects")
end

print("----------------------------------------")
if missing == 0 then
	print("[WorkoutCheck] Ready. Top-left Power + SHOP. Equip Tree Branch from the backpack.")
else
	warn("[WorkoutCheck]", missing, "problem(s).")
end
print("========================================")

Players.PlayerAdded:Connect(function(player)
	if player:GetAttribute("Cash") == nil then
		player:SetAttribute("Cash", 1_000_000)
	end
end)
for _, p in Players:GetPlayers() do
	if p:GetAttribute("Cash") == nil then
		p:SetAttribute("Cash", 1_000_000)
	end
end
