-- Paste into StarterPlayerScripts on the SELLABLE baseplate only.
-- MUST be a LocalScript (not a ModuleScript, not a server Script).
print("[WorkoutKit] booting…")
local parent = script.Parent

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
