-- Paste into StarterPlayerScripts. MUST be a LocalScript named WorkoutKit.
local parent = script.Parent
local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not script:IsA("LocalScript") then
	warn("[WorkoutKit] Change this to a LocalScript")
end

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

local function boot(name: string): boolean
	local child = parent:FindFirstChild(name)
	if not child then
		warn("[WorkoutKit] missing", name)
		return false
	end
	if not child:IsA("ModuleScript") then
		warn("[WorkoutKit]", name, "must be a ModuleScript, it is a", child.ClassName)
		return false
	end
	local ok, mod = pcall(require, child)
	if not ok then
		warn("[WorkoutKit]", name, "require failed:", mod)
		return false
	end
	if typeof(mod) == "table" and typeof(mod.init) == "function" then
		local initOk, initErr = pcall(mod.init, mod)
		if not initOk then
			warn("[WorkoutKit]", name, "init failed:", initErr)
			return false
		end
	end
	return true
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
		print("[WorkoutKit] loaded")
	else
		warn("[WorkoutKit] StartWorkout remote missing — Gears is not running on the server")
	end
end)
