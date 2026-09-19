-- Paste into StarterPlayerScripts. MUST be a LocalScript named WorkoutKit.
print("[WorkoutKit] CLIENT booting")
local parent = script.Parent
local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not script:IsA("LocalScript") then
	warn("[WorkoutKit] Change this to a LocalScript")
end

-- Old WorkoutController looks up findPowerFrame as a global (local is defined later).
local function findPowerFrame(host: Instance): GuiObject?
	if host.Name == "WorkoutPowerHud" then
		local direct = host:FindFirstChild("Power")
		if direct and direct:IsA("GuiObject") then
			return direct
		end
	end
	local sideUI = host:FindFirstChild("SideUI")
	local counters = sideUI and sideUI:FindFirstChild("Counters")
	local powerFrame = counters and counters:FindFirstChild("Power")
	if powerFrame and powerFrame:IsA("GuiObject") then
		return powerFrame
	end
	return nil
end
(_G :: any).findPowerFrame = findPowerFrame
pcall(function()
	(shared :: any).findPowerFrame = findPowerFrame
end)
print("[WorkoutKit] hud bind")

local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)
print("[WK-01] default backpack hotbar hidden — tap the on-screen ring")

local function boot(name: string)
	local child = parent:FindFirstChild(name)
	if not child then
		warn("[WorkoutKit] missing", name)
		return
	end
	if not child:IsA("ModuleScript") then
		warn("[WorkoutKit]", name, "must be a ModuleScript, it is a", child.ClassName)
		return
	end
	local ok, mod = pcall(require, child)
	if not ok then
		warn("[WorkoutKit]", name, "require failed:", mod)
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

boot("WeightUpgradesController")
task.spawn(function()
	boot("WorkoutController")
end)
task.spawn(function()
	boot("GameSoundEffects")
end)
task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 8)
	if remotes and remotes:FindFirstChild("StartWorkout") then
		print("[WorkoutKit] remotes ok")
	else
		warn("[WorkoutKit] StartWorkout remote missing")
	end
end)
print("[WorkoutKit] done — Power + SHOP at the bottom")
