-- [ACTIVE] PlotStandPlaceholders
--[[
	Brainrot stand visibility helpers.
	• ButtonPart, BlackPart, Decor, and LevelPanel stay visible.
	• Only Button.Cash (offline billboard anchor) and Spawn shell stay hidden.
--]]

local CollectionService = game:GetService("CollectionService")

local M = {}

M.PLACEHOLDER_ATTR = "StandPlaceholderHidden"
M.DISPLAY_ATTR = "BrainrotStandDisplay"
local STAND_TAG = "BrainrotStand"

local VISIBLE_GAMEPLAY_PART_NAMES: { [string]: boolean } = {
	ButtonPart = true,
	BlackPart = true,
	Level = true,
}

function M.isBrainrotStandModel(m: Instance): boolean
	if not m:IsA("Model") then
		return false
	end
	local par = m.Parent
	if not par or (par.Name ~= "Stands" and par.Name ~= "stands") then
		return false
	end
	if CollectionService:HasTag(m, STAND_TAG) then
		return true
	end
	if m:GetAttribute("BrainrotStand") == true then
		return true
	end
	if m:FindFirstChild("Spawn", true) then
		return true
	end
	if m:FindFirstChild("Button", true) or m:FindFirstChild("LevelPanel", true) then
		return true
	end
	return string.match(m.Name, "^Stand") ~= nil or string.match(m.Name, "^stand") ~= nil
end

function M.isStandDisplayDescendant(inst: Instance): boolean
	local x: Instance? = inst
	while x do
		if x:IsA("Model") and x:GetAttribute(M.DISPLAY_ATTR) == true then
			return true
		end
		x = x.Parent
	end
	return false
end

function M.isCashUtilityPart(part: BasePart, stand: Model): boolean
	local btn = stand:FindFirstChild("Button")
	if not btn then
		return part.Name == "Cash"
	end
	if part.Name == "Cash" and part:IsDescendantOf(btn) then
		return true
	end
	local cash = btn:FindFirstChild("Cash")
	return cash ~= nil and part:IsDescendantOf(cash)
end

function M.isAlwaysHiddenPart(part: BasePart): boolean
	return part.Name == "Cash"
end

function M.isUnderLevelPanel(part: BasePart, stand: Model): boolean
	local x: Instance? = part.Parent
	while x and x ~= stand do
		if x.Name == "LevelPanel" then
			return true
		end
		x = x.Parent
	end
	return false
end

function M.isSpawnShellPart(part: BasePart, stand: Model): boolean
	if part.Name ~= "Spawn" then
		return false
	end
	if M.isStandDisplayDescendant(part) then
		return false
	end
	local btn = stand:FindFirstChild("Button")
	if btn and part:IsDescendantOf(btn) then
		return false
	end
	return true
end

function M.markPlaceholderHidden(part: BasePart)
	part:SetAttribute(M.PLACEHOLDER_ATTR, true)
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
end

function M.shouldStayHidden(part: BasePart): boolean
	return part:GetAttribute(M.PLACEHOLDER_ATTR) == true
end

function M.findButtonPart(stand: Model): BasePart?
	local btn = stand:FindFirstChild("Button")
	if btn then
		local bp = btn:FindFirstChild("ButtonPart")
		if bp and bp:IsA("BasePart") then
			return bp :: BasePart
		end
	end
	local any = stand:FindFirstChild("ButtonPart", true)
	if any and any:IsA("BasePart") then
		return any :: BasePart
	end
	return nil
end

function M.findPromptAnchorPart(stand: Model, spawnPart: BasePart): BasePart
	local decor = stand:FindFirstChild("Decor")
	if decor then
		local cube005 = decor:FindFirstChild("Cube.005", true)
		if cube005 and cube005:IsA("BasePart") then
			return cube005 :: BasePart
		end
		for _, d in ipairs(decor:GetDescendants()) do
			if d:IsA("BasePart") and string.sub(d.Name, 1, 4) == "Cube" then
				if d:FindFirstChildWhichIsA("Attachment", true) or d:FindFirstChildWhichIsA("ProximityPrompt", true) then
					return d :: BasePart
				end
			end
		end
	end
	return spawnPart
end

function M.showGameplayPart(part: BasePart)
	part:SetAttribute(M.PLACEHOLDER_ATTR, nil)
	if part.Transparency >= 1 then
		part.Transparency = 0
	end
end

function M.hideSpawnShellOnStand(stand: Model)
	if not M.findButtonPart(stand) then
		return
	end
	for _, d in ipairs(stand:GetDescendants()) do
		if d:IsA("BasePart") and M.isSpawnShellPart(d :: BasePart, stand) then
			M.markPlaceholderHidden(d :: BasePart)
		end
	end
end

-- Cloned plots often keep SurfaceGui/BillboardGui Adornee pointing at the
-- source stand, so cash and level text draw on a random other slot.
function M.fixStandGuiAdornees(stand: Model)
	for _, d in ipairs(stand:GetDescendants()) do
		if d:IsA("SurfaceGui") then
			local parent = d.Parent
			if parent and parent:IsA("BasePart") then
				local gui = d :: SurfaceGui
				if gui.Adornee ~= nil and gui.Adornee ~= parent then
					gui.Adornee = parent
				end
			end
		elseif d:IsA("BillboardGui") then
			local gui = d :: BillboardGui
			local adornee = gui.Adornee
			if adornee and not adornee:IsDescendantOf(stand) then
				local parent = d.Parent
				if parent and parent:IsA("BasePart") then
					gui.Adornee = parent
				elseif parent and parent:IsA("Attachment") then
					gui.Adornee = parent
				end
			end
		end
	end
end

function M.ensureStandVisible(stand: Model)
	local decor = stand:FindFirstChild("Decor")
	local button = stand:FindFirstChild("Button")
	for _, d in ipairs(stand:GetDescendants()) do
		if d:IsA("BasePart") then
			local p = d :: BasePart
			if M.isCashUtilityPart(p, stand) then
				M.markPlaceholderHidden(p)
			elseif M.isSpawnShellPart(p, stand) then
				M.markPlaceholderHidden(p)
			else
				local show = VISIBLE_GAMEPLAY_PART_NAMES[p.Name]
					or M.isUnderLevelPanel(p, stand)
					or (decor ~= nil and p:IsDescendantOf(decor))
					or (button ~= nil and p:IsDescendantOf(button) and not M.isCashUtilityPart(p, stand))
				if show then
					M.showGameplayPart(p)
					if p.Name == "ButtonPart" then
						p.CanTouch = true
					end
				end
			end
		elseif d:IsA("SurfaceGui") then
			local x: Instance? = d.Parent
			local enable = false
			while x and x ~= stand do
				if x.Name == "Button" or x.Name == "LevelPanel" then
					enable = true
					break
				end
				x = x.Parent
			end
			if enable then
				(d :: SurfaceGui).Enabled = true
			end
		end
	end
	M.fixStandGuiAdornees(stand)
	M.hideSpawnShellOnStand(stand)
end

function M.ensureStandsVisibleInPlot(plot: Instance)
	for _, story in ipairs(plot:GetChildren()) do
		local standsFolder = M.findStandsFolder(story)
		if not standsFolder then
			continue
		end
		for _, ch in ipairs(standsFolder:GetChildren()) do
			if ch:IsA("Model") and M.isBrainrotStandModel(ch) then
				M.ensureStandVisible(ch :: Model)
			end
		end
	end
end

function M.hideShellsOnStand(stand: Model)
	M.ensureStandVisible(stand)
end

function M.hideShellsInPlot(plot: Instance)
	M.ensureStandsVisibleInPlot(plot)
end

function M.showGameplayPartsOnStand(stand: Model)
	M.ensureStandVisible(stand)
end

function M.findStandsFolder(story: Instance): Instance?
	local stands = story:FindFirstChild("Stands") or story:FindFirstChild("stands")
	if stands then
		return stands
	end
	for _, d in ipairs(story:GetDescendants()) do
		if (d.Name == "Stands" or d.Name == "stands") and (d:IsA("Folder") or d:IsA("Model")) then
			return d
		end
	end
	return nil
end

return M
