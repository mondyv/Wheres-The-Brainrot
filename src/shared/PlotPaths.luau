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

	-- Prefer Map subtree (streaming / huge Workspace safe)
	local map = Workspace:FindFirstChild("Map")
	if map then
		pushUnique(list, seen, map:FindFirstChild("Spawn And Bases"))
		local lands = map:FindFirstChild("Lands")
		if lands then
			pushUnique(list, seen, lands:FindFirstChild("Spawn And Bases"))
		end
		for _, d in ipairs(map:GetDescendants()) do
			if d.Name == "Spawn And Bases" and (d:IsA("Folder") or d:IsA("Model")) then
				pushUnique(list, seen, d)
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

function M.findSpawnAndBasesFolder(): Instance?
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

	if bestScore > 0 then
		return best
	end
	return candidates[1]
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

function M.findPlotForAssignedSlot(player: Player): Instance?
	local slot = player:GetAttribute("AssignedPlotSlot")
	if typeof(slot) ~= "number" then
		return nil
	end
	local folder = M.findSpawnAndBasesFolder()
	if not folder then
		return nil
	end
	return folder:FindFirstChild("Plot_" .. tostring(math.floor(slot)))
end

return M
