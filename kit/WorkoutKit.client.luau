-- Paste into StarterPlayerScripts on the SELLABLE baseplate only.
-- Do not add this to the live game — init.client already boots WorkoutController.
local parent = script.Parent

local function boot(name: string)
	local child = parent:FindFirstChild(name)
	if not child then
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
