-- WorkoutSetup
-- Paste this as a Script in ServerScriptService on the SELLABLE baseplate.
-- Play the game, open View → Output. This prints what is missing.
--
-- CORRECT TREE (names must match):
--
-- ServerScriptService
--   Gears                  Script          (from Gears.server — creates remotes + tools)
--   WorkoutCash            Script          (gives starting Cash)
--   WorkoutSetup           Script          (this file)
--   WorkoutLicense         Script          (license)
--   GearService            ModuleScript    (OR inside a Folder named Modules)
--
-- StarterPlayer.StarterPlayerScripts
--   WorkoutKit             LocalScript     (MUST be LocalScript or nothing boots)
--   WorkoutController      ModuleScript
--   WeightUpgradesController ModuleScript
--   GameSoundEffects       ModuleScript
--   ClientSFXVolume        ModuleScript
--   OtherVfxController     ModuleScript
--   GearRainbowFX          ModuleScript
--
-- ReplicatedStorage
--   Shared
--     WorkoutCompat, GearConfig, WorkoutPower   ModuleScripts
--   EssentialAssets
--     Gears, ComboVFX, OtherVFX
--
-- StarterGui.Main.Frames.Upgrades.Container   (shop rows; need a child named "1")
-- StarterGui.Main.Frames["Edit Power"]        (optional)
-- SoundService.SoundEffects                   (Lifting, combo, Purchase, …)
--
-- Do NOT use Workspace.Gears as the shop. Tools are built by GearService
-- from ReplicatedStorage.EssentialAssets.Gears.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")
local SoundService = game:GetService("SoundService")

local missing = 0

local function ok(msg: string)
	print("[WorkoutSetup] OK   ", msg)
end

local function bad(msg: string)
	missing += 1
	warn("[WorkoutSetup] NEED ", msg)
end

local function findNamed(root: Instance, name: string): Instance?
	local direct = root:FindFirstChild(name)
	if direct then
		return direct
	end
	return root:FindFirstChild(name, true)
end

print("========== WORKOUT KIT SETUP ==========")

local gears = findNamed(ServerScriptService, "Gears")
if gears and gears:IsA("Script") and not gears:IsA("LocalScript") then
	ok("ServerScriptService.Gears (server Script)")
else
	bad("Put Gears as a Script (server) in ServerScriptService — without this, equip does nothing")
end

local gearService = findNamed(ServerScriptService, "GearService")
if gearService and gearService:IsA("ModuleScript") then
	ok("GearService ModuleScript")
else
	bad("Put GearService ModuleScript next to Gears, or in ServerScriptService.Modules")
end

local cash = findNamed(ServerScriptService, "WorkoutCash")
if cash and cash:IsA("Script") then
	ok("WorkoutCash")
else
	bad("Put WorkoutCash Script in ServerScriptService (gives Cash for the shop)")
end

local shared = ReplicatedStorage:FindFirstChild("Shared")
if shared then
	for _, name in { "WorkoutCompat", "GearConfig", "WorkoutPower" } do
		local m = shared:FindFirstChild(name)
		if m and m:IsA("ModuleScript") then
			ok("ReplicatedStorage.Shared." .. name)
		else
			bad("ReplicatedStorage.Shared." .. name .. " ModuleScript")
		end
	end
else
	bad("ReplicatedStorage.Shared folder")
end

local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
local gearsFolder = assets and assets:FindFirstChild("Gears")
if gearsFolder then
	ok("EssentialAssets.Gears")
else
	bad("ReplicatedStorage.EssentialAssets.Gears (the mesh templates)")
end
if assets and assets:FindFirstChild("ComboVFX") then
	ok("EssentialAssets.ComboVFX")
else
	bad("ReplicatedStorage.EssentialAssets.ComboVFX (combo VFX)")
end

local sps = StarterPlayer:FindFirstChild("StarterPlayerScripts")
if not sps then
	bad("StarterPlayer.StarterPlayerScripts")
else
	local kit = sps:FindFirstChild("WorkoutKit")
	if kit and kit:IsA("LocalScript") then
		ok("WorkoutKit LocalScript")
	elseif kit then
		bad("WorkoutKit is a " .. kit.ClassName .. " — change Class to LocalScript or nothing will boot")
	else
		bad("StarterPlayerScripts.WorkoutKit LocalScript (this calls init on the modules)")
	end
	for _, name in {
		"WorkoutController",
		"WeightUpgradesController",
		"GameSoundEffects",
		"ClientSFXVolume",
		"OtherVfxController",
		"GearRainbowFX",
	} do
		local m = sps:FindFirstChild(name)
		if m and m:IsA("ModuleScript") then
			ok("StarterPlayerScripts." .. name)
		elseif m then
			bad(name .. " must be a ModuleScript (it is a " .. m.ClassName .. ")")
		else
			bad("StarterPlayerScripts." .. name .. " ModuleScript")
		end
	end
end

local main = StarterGui:FindFirstChild("Main")
if main and main:IsA("ScreenGui") then
	ok("StarterGui.Main")
	local frames = main:FindFirstChild("Frames")
	local upgrades = frames and frames:FindFirstChild("Upgrades")
	local container = upgrades and upgrades:FindFirstChild("Container")
	if container then
		ok("Main.Frames.Upgrades.Container")
		if container:FindFirstChild("1") then
			ok("shop row template named 1")
		else
			bad("Main.Frames.Upgrades.Container needs a row named 1 (clone template)")
		end
	else
		bad("Main.Frames.Upgrades.Container — shop panel. Copy Frames.Upgrades from the original game")
	end
else
	bad("StarterGui.Main ScreenGui")
end

local sfx = SoundService:FindFirstChild("SoundEffects")
if sfx then
	ok("SoundService.SoundEffects")
	if sfx:FindFirstChild("Lifting") then
		ok("SoundEffects.Lifting")
	else
		bad("SoundEffects.Lifting")
	end
else
	bad("SoundService.SoundEffects folder")
end

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if remotes and remotes:FindFirstChild("StartWorkout") then
	ok("Remotes.StartWorkout (Gears is running)")
else
	bad("ReplicatedStorage.Remotes missing — Gears Script is not running. Add it, then press Play again")
end

print("----------------------------------------")
if missing == 0 then
	print("[WorkoutSetup] All checks passed. Top-left = Power + SHOP. Equip the tool in the backpack.")
else
	warn("[WorkoutSetup]", missing, "problem(s). Fix NEED lines, then Play again.")
	warn("[WorkoutSetup] Workspace.Gears is NOT used. Leave tools to GearService.")
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
