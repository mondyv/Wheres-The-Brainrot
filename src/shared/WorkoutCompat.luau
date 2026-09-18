-- WorkoutCompat
-- Small require/format helpers so the workout scripts still boot if you drop
-- them on a blank baseplate (no swing, no rebirth, no brainrot modules).
-- Keep this next to GearConfig in ReplicatedStorage.Shared.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local M = {}

function M.tryRequire(parent: Instance?, name: string): any?
	if not parent then
		return nil
	end
	local child = parent:FindFirstChild(name)
	if not child then
		return nil
	end
	local ok, mod = pcall(require, child)
	if not ok then
		warn("[WorkoutCompat] skip", name, mod)
		return nil
	end
	return mod
end

function M.shared(name: string): any?
	local folder = ReplicatedStorage:FindFirstChild("Shared")
	return M.tryRequire(folder, name)
end

function M.formatNumber(n: number): string
	local v = math.max(0, math.floor(n))
	if v < 1000 then
		return tostring(v)
	end
	local suffixes = { "K", "M", "B", "T", "Qd", "Qn", "Sx", "Sp" }
	local i = 0
	local x = v / 1
	while x >= 1000 and i < #suffixes do
		x /= 1000
		i += 1
	end
	if i == 0 then
		return tostring(v)
	end
	local rounded = math.floor(x * 10 + 0.5) / 10
	if rounded >= 1000 and i < #suffixes then
		rounded /= 1000
		i += 1
	end
	if rounded % 1 == 0 then
		return string.format("%d%s", rounded, suffixes[i])
	end
	return string.format("%.1f%s", rounded, suffixes[i])
end

return M
