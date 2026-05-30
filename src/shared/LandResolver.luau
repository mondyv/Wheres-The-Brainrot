--[[
	Resolve Land 1–10 from a world position using Map.Lands Land<N> folders.
	Matches BushHarvest plot resolution (nearest land center).
--]]

local M = {}

local PLOT_NAME_PATTERN = "^Land(%d+)$"
local MAX_LAND = 10

local function collectLandCandidates(): { Instance }
	local map = workspace:FindFirstChild("Map")
	if not map then
		return {}
	end
	local result: { Instance } = {}
	local seen: { [Instance]: boolean } = {}

	local function consider(child: Instance)
		if seen[child] then
			return
		end
		if tonumber(string.match(child.Name, PLOT_NAME_PATTERN)) then
			seen[child] = true
			table.insert(result, child)
		end
	end

	local lands = map:FindFirstChild("Lands")
	if lands then
		for _, c in lands:GetChildren() do
			consider(c)
		end
	end
	for _, c in map:GetChildren() do
		consider(c)
	end
	return result
end

local function centerOfLand(child: Instance): Vector3?
	if child:IsA("Model") then
		return (child :: Model):GetBoundingBox().Position
	elseif child:IsA("BasePart") then
		return (child :: BasePart).Position
	elseif child:IsA("Folder") then
		local sum = Vector3.zero
		local count = 0
		for _, d in ipairs((child :: Folder):GetDescendants()) do
			if d:IsA("BasePart") then
				sum += d.Position
				count += 1
				if count >= 60 then
					break
				end
			end
		end
		if count > 0 then
			return sum / count
		end
	end
	return nil
end

function M.resolveLandAtPosition(worldPos: Vector3): number
	local best = 1
	local bestDist = math.huge
	for _, child in ipairs(collectLandCandidates()) do
		local n = tonumber(string.match(child.Name, PLOT_NAME_PATTERN)) or 1
		local plotAttr = child:GetAttribute("Plot")
		if typeof(plotAttr) == "number" then
			n = math.floor(plotAttr)
		end
		local centerPos = centerOfLand(child)
		if centerPos then
			local dist = (centerPos - worldPos).Magnitude
			if dist < bestDist then
				bestDist = dist
				best = math.clamp(n, 1, MAX_LAND)
			end
		elseif bestDist == math.huge then
			best = math.clamp(n, 1, MAX_LAND)
		end
	end
	return best
end

return M
