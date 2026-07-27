-- [ACTIVE] PlotPaths
--[[
	PlotPaths — resolves the folder containing BasePOSPart anchor parts.

	Known layouts:
	  workspace.Map["Spawn And Bases"]
	  workspace.Map.[...anything...]["Spawn And Bases"]
	  workspace.Lands["Spawn And Bases"]
	  workspace.Map.Lands["Spawn And Bases"]

	We locate every instance named exactly "Spawn And Bases" (Folder / Model),
	then prefer the one with the most BasePOSPart* BaseParts.
--]]

local Workspace = game:GetService("Workspace")

local M = {}

local function pushUnique(list: { Instance }, seen: { [Instance]: boolean }, inst: Instance?)
	if not inst then
		return
	end
	if seen[inst] then
		return
	end
	seen[inst] = true
	table.insert(list, inst)
end

local function anchorCount(folder: Instance): number
	local n = 0
	for slot = 1, 32 do
		local pos = folder:FindFirstChild("BasePOSPart" .. tostring(slot))
		if pos and pos:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

function M.anchorScore(folder: Instance?): number
	if not folder then
		return 0
	end
	return anchorCount(folder)
end

function M.collectSpawnAndBasesCandidates(): { Instance }
	local list: { Instance } = {}
	local seen: { [Instance]: boolean } = {}

	-- Known paths only — never map:GetDescendants() (entire world scan blocked UIBlox boot).
	local map = Workspace:FindFirstChild("Map")
	if map then
		pushUnique(list, seen, map:FindFirstChild("Spawn And Bases"))
		local lands = map:FindFirstChild("Lands")
		if lands then
			pushUnique(list, seen, lands:FindFirstChild("Spawn And Bases"))
		end
		for _, child in map:GetChildren() do
			if child.Name == "Spawn And Bases" and (child:IsA("Folder") or child:IsA("Model")) then
				pushUnique(list, seen, child)
			elseif child:IsA("Folder") or child:IsA("Model") then
				local nested = child:FindFirstChild("Spawn And Bases")
				if nested then
					pushUnique(list, seen, nested)
				end
			end
		end
	end

	local wsLands = Workspace:FindFirstChild("Lands")
	if wsLands then
		pushUnique(list, seen, wsLands:FindFirstChild("Spawn And Bases"))
	end

	pushUnique(list, seen, Workspace:FindFirstChild("Spawn And Bases"))

	return list
end

-- Cache the resolved folder. collectSpawnAndBasesCandidates() runs map:GetDescendants() over the
-- ENTIRE world, and this resolver is called on every stand collect / plot check — re-scanning each
-- time caused severe server hitches. "Spawn And Bases" is a stable Folder, so a .Parent check is
-- enough to know the cache is still valid.
local cachedSpawnBases: Instance? = nil

function M.findSpawnAndBasesFolder(): Instance?
	if cachedSpawnBases and cachedSpawnBases.Parent then
		return cachedSpawnBases
	end

	local candidates = M.collectSpawnAndBasesCandidates()
	local best: Instance? = nil
	local bestScore = -1

	for _, folder in ipairs(candidates) do
		local score = anchorCount(folder)
		if score > bestScore then
			bestScore = score
			best = folder
		end
	end

	if bestScore > 0 and best then
		-- Confident match (has plot anchors): safe to cache.
		cachedSpawnBases = best
		return best
	end

	-- Anchors may not have streamed/loaded yet; return a best-effort candidate but only cache it
	-- when it's the sole candidate (so we don't lock onto the wrong folder during load).
	if #candidates == 1 then
		cachedSpawnBases = candidates[1]
	end
	return candidates[1]
end

function M.invalidateSpawnAndBasesCache()
	cachedSpawnBases = nil
end

function M.waitForSpawnAndBasesFolder(timeoutSec: number): Instance?
	local deadline = os.clock() + math.max(timeoutSec, 0.05)
	Workspace:WaitForChild("Map", math.min(timeoutSec > 2 and math.floor(timeoutSec) or 120, 120))

	while os.clock() < deadline do
		local folder = M.findSpawnAndBasesFolder()
		if folder and anchorCount(folder) > 0 then
			return folder
		end
		task.wait(0.25)
	end
	return M.findSpawnAndBasesFolder()
end

function M.isPlotRoot(inst: Instance): boolean
	if not (inst:IsA("Model") or inst:IsA("Folder")) then
		return false
	end
	if typeof(inst:GetAttribute("PlotSlotId")) == "number" then
		return true
	end
	return string.match(inst.Name, "^Plot_%d+$") ~= nil
end

function M.firstStoryFolder(plot: Instance): Instance?
	local s = plot:FindFirstChild("1 Story")
	if s then
		return s
	end
	return plot:FindFirstChild("1st Story")
end

function M.findPlotOwnedByPlayer(player: Player): Instance?
	local folder = M.findSpawnAndBasesFolder()
	if not folder then
		return nil
	end
	for _, ch in ipairs(folder:GetChildren()) do
		if M.isPlotRoot(ch) and ch:GetAttribute("PlotOwnerUserId") == player.UserId then
			return ch
		end
	end
	return nil
end

function M.findPlotForAssignedSlot(player: Player): Instance?
	local folder = M.findSpawnAndBasesFolder()
	if not folder then
		return nil
	end

	-- Always prefer the plot you actually own.
	local owned = M.findPlotOwnedByPlayer(player)
	if owned then
		return owned
	end

	local slot = player:GetAttribute("AssignedPlotSlot")
	if typeof(slot) == "number" then
		local bySlot = folder:FindFirstChild("Plot_" .. tostring(math.floor(slot)))
		if bySlot and M.isPlotRoot(bySlot) then
			local uid = bySlot:GetAttribute("PlotOwnerUserId")
			-- Only return assigned slot when unclaimed (still assigning) or yours.
			if typeof(uid) ~= "number" or uid == player.UserId then
				return bySlot
			end
		end
	end

	return nil
end

return M
