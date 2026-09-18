-- Paste into StarterPlayerScripts on the SELLABLE baseplate only.
-- MUST be a LocalScript (not a ModuleScript, not a server Script).
print("[WorkoutKit] booting…")
local parent = script.Parent
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not script:IsA("LocalScript") then
	warn("[WorkoutKit] This must be a LocalScript. Right now it is a", script.ClassName, "so the shop never starts.")
end

for _, name in { "Gears", "GearService", "WorkoutCash", "WorkoutSetup", "WorkoutCheck", "WorkoutLicense" } do
	local wrong = parent:FindFirstChild(name) or parent:FindFirstChild(name .. " ")
	if wrong then
		warn("[WorkoutKit] MOVE", name, "out of StarterPlayerScripts into ServerScriptService (server Script / ModuleScript). It does nothing here.")
	end
end

if ServerScriptService:FindFirstChild("Gears", true) == nil then
	warn("[WorkoutKit] ServerScriptService has no Gears Script. Drag StarterPlayerScripts.Gears into ServerScriptService.")
end

task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 6)
	if not (remotes and remotes:FindFirstChild("StartWorkout")) then
		warn("[WorkoutKit] StartWorkout remote missing. Equip will do nothing until Gears is a server Script in ServerScriptService.")
	end
end)

local function boot(name: string)
	local child = parent:FindFirstChild(name)
	if not child then
		warn("[WorkoutKit] missing ModuleScript:", name)
		return
	end
	if not child:IsA("ModuleScript") then
		warn("[WorkoutKit]", name, "must be a ModuleScript — you pasted it as a", child.ClassName)
		return
	end
	local ok, mod = pcall(require, child)
	if not ok then
		warn("[WorkoutKit]", name, "failed:", mod)
		return
	end
	if typeof(mod) == "table" and typeof(mod.init) == "function" then
		local initOk, initErr = pcall(mod.init, mod)
		if not initOk then
			warn("[WorkoutKit]", name, "init failed:", initErr)
		end
	end
end

boot("GameSoundEffects")
boot("WeightUpgradesController")
if not parent:FindFirstChild("WeightUpgradesController") then
	boot("UpgradesController")
end
boot("WorkoutController")
print("[WorkoutKit] done — look top-left for Power + SHOP")
