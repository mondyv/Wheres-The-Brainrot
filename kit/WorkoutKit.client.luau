-- Paste into StarterPlayerScripts on the SELLABLE baseplate only.
-- MUST be a LocalScript (not a ModuleScript, not a server Script).
print("[WorkoutKit] CLIENT booting — if you do not see this, Output is filtered to Server only (click All)")
local parent = script.Parent
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not script:IsA("LocalScript") then
	warn("[WorkoutKit] This must be a LocalScript. Right now it is a", script.ClassName, "so the shop never starts.")
end

for _, name in { "Gears", "GearService", "WorkoutCash", "WorkoutSetup", "WorkoutCheck", "WorkoutLicense" } do
	local wrong = parent:FindFirstChild(name) or parent:FindFirstChild(name .. " ")
	if wrong then
		warn("[WorkoutKit] MOVE", name, "out of StarterPlayerScripts into ServerScriptService.")
	end
end

if ServerScriptService:FindFirstChild("Gears", true) == nil then
	warn("[WorkoutKit] ServerScriptService has no Gears Script.")
end

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
		else
			print("[WorkoutKit] started", name)
		end
	end
end

-- Shop first so SFX cannot block the SHOP button.
boot("WeightUpgradesController")
if not parent:FindFirstChild("WeightUpgradesController") then
	boot("UpgradesController")
end
boot("WorkoutController")
task.spawn(function()
	boot("GameSoundEffects")
end)

task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 8)
	if not (remotes and remotes:FindFirstChild("StartWorkout")) then
		warn("[WorkoutKit] StartWorkout remote missing. Equip will do nothing.")
	else
		print("[WorkoutKit] remotes ok")
	end
end)

print("[WorkoutKit] done — look TOP-LEFT for a gold Power number and a green SHOP button")
