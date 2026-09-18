-- Paste into StarterPlayerScripts on the SELLABLE baseplate only.
-- Do not add this to the live game — init.client already boots WorkoutController.
local parent = script.Parent
local shop = parent:FindFirstChild("WeightUpgradesController") or parent:FindFirstChild("UpgradesController")
if shop then
	local ok, mod = pcall(require, shop)
	if ok and typeof(mod) == "table" and typeof(mod.init) == "function" then
		mod.init()
	elseif not ok then
		warn("[WorkoutKit] shop failed:", mod)
	end
end
local workout = parent:FindFirstChild("WorkoutController")
if workout then
	local ok, mod = pcall(require, workout)
	if ok and typeof(mod) == "table" and typeof(mod.init) == "function" then
		mod.init()
	elseif not ok then
		warn("[WorkoutKit] WorkoutController failed:", mod)
	end
end
