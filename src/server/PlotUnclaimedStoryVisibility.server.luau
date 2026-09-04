-- [ACTIVE] PlotUnclaimedStoryVisibility.server
--[[
	PlotUnclaimedStoryVisibility (server)
	When PlotOwnerUserId is unset, keep story 1 visible and hide upper stories + floating UI.
	When claimed, show the full plot.

	First story name: "1 Story" / "1st Story" (spacing + case tolerant).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local PlotStandPlaceholders = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotStandPlaceholders"))

local ATTR_PART_T = "__PlotUnclPartT"
local ATTR_PART_CC = "__PlotUnclPartCC"
local ATTR_PART_CQ = "__PlotUnclPartCQ"
local ATTR_PART_CT = "__PlotUnclPartCT"
local ATTR_DECAL_T = "__PlotUnclDecalT"
local ATTR_PP = "__PlotUnclPP"
local ATTR_GUI = "__PlotUnclGui"
local ATTR_EMIT = "__PlotUnclEmit"

local hooked: { [Instance]: boolean } = {}
local hookedFolders: { [Instance]: boolean } = {}
local refreshScheduled: { [Instance]: boolean } = {}
local _applyPlotStoryVisibility: (plot: Instance) -> ()

local function normalizeKey(name: string): string
	return string.gsub(string.lower(name), "%s+", "")
end

local function alphaNumericKey(name: string): string
	-- Same logical name tolerates "Upgrade / Add", "UpgradeAdd", Studio renames.
	return string.gsub(string.lower(name), "[^a-z0-9]", "")
end

local function isFirstStoryName(name: string): boolean
	local key = normalizeKey(name)
	return key == "1story" or key == "1ststory"
end

local function firstStoryOf(plot: Instance): Instance?
	for _, ch in ipairs(plot:GetChildren()) do
		if isFirstStoryName(ch.Name) then
			return ch
		end
	end
	return nil
end

local function plotIsClaimed(plot: Instance): boolean
	local uid = plot:GetAttribute("PlotOwnerUserId")
	if typeof(uid) ~= "number" then
		return false
	end
	return Players:GetPlayerByUserId(uid) ~= nil
end

local function stashPartProps(p: BasePart)
	if p:GetAttribute(ATTR_PART_T) == nil then
		p:SetAttribute(ATTR_PART_T, p.Transparency)
	end
	if p:GetAttribute(ATTR_PART_CC) == nil then
		p:SetAttribute(ATTR_PART_CC, p.CanCollide)
	end
	if p:GetAttribute(ATTR_PART_CQ) == nil then
		p:SetAttribute(ATTR_PART_CQ, p.CanQuery)
	end
	if p:GetAttribute(ATTR_PART_CT) == nil then
		p:SetAttribute(ATTR_PART_CT, p.CanTouch)
	end
end

local function restorePartProps(p: BasePart)
	if PlotStandPlaceholders.isAlwaysHiddenPart(p) then
		PlotStandPlaceholders.markPlaceholderHidden(p)
		return
	end
	if PlotStandPlaceholders.shouldStayHidden(p) then
		PlotStandPlaceholders.markPlaceholderHidden(p)
		return
	end
	if PlotStandPlaceholders.isStandDisplayDescendant(p) then
		p.Transparency = 0
		p.CanCollide = false
		p.CanQuery = true
		p.CanTouch = false
		return
	end
	local t = p:GetAttribute(ATTR_PART_T)
	if typeof(t) == "number" then
		p.Transparency = t
	else
		p.Transparency = 0
	end
	p:SetAttribute(ATTR_PART_T, nil)
	local cc = p:GetAttribute(ATTR_PART_CC)
	if typeof(cc) == "boolean" then
		p.CanCollide = cc
	end
	p:SetAttribute(ATTR_PART_CC, nil)
	local cq = p:GetAttribute(ATTR_PART_CQ)
	if typeof(cq) == "boolean" then
		p.CanQuery = cq
	end
	p:SetAttribute(ATTR_PART_CQ, nil)
	local ct = p:GetAttribute(ATTR_PART_CT)
	if typeof(ct) == "boolean" then
		p.CanTouch = ct
	end
	p:SetAttribute(ATTR_PART_CT, nil)
end

local function hidePart(p: BasePart)
	if PlotStandPlaceholders.isStandDisplayDescendant(p) then
		return
	end
	stashPartProps(p)
	p.Transparency = 1
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
end

local function applyVisibleToInstance(d: Instance, visible: boolean)
	if d:IsA("BasePart") then
		local p = d :: BasePart
		if visible then
			restorePartProps(p)
		else
			hidePart(p)
		end
	elseif d:IsA("Decal") or d:IsA("Texture") then
		local surf = d :: any
		if visible then
			local t = d:GetAttribute(ATTR_DECAL_T)
			if typeof(t) == "number" then
				surf.Transparency = t
			end
			d:SetAttribute(ATTR_DECAL_T, nil)
		else
			if d:GetAttribute(ATTR_DECAL_T) == nil then
				d:SetAttribute(ATTR_DECAL_T, surf.Transparency)
			end
			surf.Transparency = 1
		end
	elseif d:IsA("ProximityPrompt") then
		local pp = d :: ProximityPrompt
		if visible then
			local prev = d:GetAttribute(ATTR_PP)
			if typeof(prev) == "boolean" then
				pp.Enabled = prev
			end
			d:SetAttribute(ATTR_PP, nil)
		else
			if d:GetAttribute(ATTR_PP) == nil then
				d:SetAttribute(ATTR_PP, pp.Enabled)
			end
			pp.Enabled = false
		end
	elseif d:IsA("SurfaceGui") or d:IsA("BillboardGui") then
		local gui = d :: LayerCollector
		if visible then
			local prev = d:GetAttribute(ATTR_GUI)
			if typeof(prev) == "boolean" then
				gui.Enabled = prev
			end
			d:SetAttribute(ATTR_GUI, nil)
		else
			if d:GetAttribute(ATTR_GUI) == nil then
				d:SetAttribute(ATTR_GUI, gui.Enabled)
			end
			gui.Enabled = false
		end
	elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
		local fx = d :: any
		if visible then
			local prev = d:GetAttribute(ATTR_EMIT)
			if typeof(prev) == "boolean" then
				fx.Enabled = prev
			end
			d:SetAttribute(ATTR_EMIT, nil)
		else
			if d:GetAttribute(ATTR_EMIT) == nil then
				d:SetAttribute(ATTR_EMIT, fx.Enabled)
			end
			fx.Enabled = false
		end
	end
end

local function setSubtreeVisible(root: Instance, visible: boolean)
	applyVisibleToInstance(root, visible)
	for _, d in ipairs(root:GetDescendants()) do
		applyVisibleToInstance(d, visible)
	end
end

local function findFloorDirectUnder(story: Instance): Instance?
	for _, ch in ipairs(story:GetChildren()) do
		if string.lower(ch.Name) == "floor" then
			return ch
		end
	end
	return nil
end

-- Floor may be nested oddly; prefer first story, else first "Floor" folder/model under the plot.
local function _findFloorFolderForPlot(plot: Instance): Instance?
	local story = firstStoryOf(plot)
	if story then
		local f = findFloorDirectUnder(story)
		if f then
			return f
		end
	end
	for _, d in ipairs(plot:GetDescendants()) do
		if (d:IsA("Folder") or d:IsA("Model")) and string.lower(d.Name) == "floor" then
			return d
		end
	end
	return nil
end

local PLOT_SIGN_NAME_KEYS: { [string]: boolean } = {
	plotusername = true,
	plot_username = true,
	plotusernamelabel = true,
	usernamesign = true,
	plotsign = true,
}

-- Extra matches for Studio renames ("Plot_UserName_Label", etc.)
local SIGN_FOLDER_ALPHA_KEYS: { [string]: boolean } = {
	plotusername = true,
	plotusernamelabel = true,
	plotsign = true,
	usernamesign = true,
}

local function isPlotSignFolder(inst: Instance): boolean
	if not (inst:IsA("Folder") or inst:IsA("Model")) then
		return false
	end
	if PLOT_SIGN_NAME_KEYS[normalizeKey(inst.Name)] == true then
		return true
	end
	return SIGN_FOLDER_ALPHA_KEYS[alphaNumericKey(inst.Name)] == true
end

local function isFloorUnlockSignModel(m: Model): boolean
	local ak = alphaNumericKey(m.Name)
	return ak == "upgradeadd"
		or (string.find(ak, "upgrade", 1, true) ~= nil and string.find(ak, "add", 1, true) ~= nil)
end

local function isGenericSignModel(inst: Instance): boolean
	if not inst:IsA("Model") then
		return false
	end
	if isFloorUnlockSignModel(inst) then
		return false
	end
	local ak = alphaNumericKey(inst.Name)
	if ak == "sign" then
		return true
	end
	if inst:FindFirstChild("GUIPart", true) and inst:FindFirstChildWhichIsA("SurfaceGui", true) then
		return true
	end
	return false
end

local function isProtectedStandUi(inst: Instance, plotRoot: Instance): boolean
	local x: Instance? = inst
	while x and x ~= plotRoot do
		if x.Name == "LevelPanel" or x.Name == "Button" or x.Name == "PlotUsername" then
			return true
		end
		if x:IsA("Model") and isFloorUnlockSignModel(x) then
			return true
		end
		x = x.Parent
	end
	return false
end

local function stripFloatingUiAndSigns(plot: Instance, keepPlotGui: boolean?)
	local toDestroy: { Instance } = {}
	for _, d in ipairs(plot:GetDescendants()) do
		if d:IsA("BillboardGui") then
			table.insert(toDestroy, d)
		elseif d.Name == "PlotGUI" and d:IsA("SurfaceGui") then
			if keepPlotGui ~= true then
				table.insert(toDestroy, d)
			end
		elseif d:IsA("SurfaceGui") and not isProtectedStandUi(d, plot) then
			table.insert(toDestroy, d)
		elseif isPlotSignFolder(d) or isGenericSignModel(d) then
			if keepPlotGui ~= true then
				table.insert(toDestroy, d)
			end
		end
	end
	for _, inst in ipairs(toDestroy) do
		inst:Destroy()
	end
end

local function hidePlotSignUnder(parent: Instance)
	for _, d in ipairs(parent:GetDescendants()) do
		if isPlotSignFolder(d) or isGenericSignModel(d) then
			setSubtreeVisible(d, false)
		end
	end
end

local function isLikelyBrainrotStandModel(m: Model): boolean
	return PlotStandPlaceholders.isBrainrotStandModel(m)
end

local function findStandsFolder(story: Instance): Instance?
	return PlotStandPlaceholders.findStandsFolder(story)
end

-- After the plot-wide hide, only re-show collision/render parts under Floor — not LayerCollectors
-- (otherwise empty-stand SurfaceGuis / Billboards pop back on).
local function isUnderStandsSubtree(inst: Instance): boolean
	local x: Instance? = inst
	while x do
		if x.Name == "Stands" or x.Name == "stands" then
			return true
		end
		if x:IsA("Model") and isLikelyBrainrotStandModel(x) then
			return true
		end
		x = x.Parent
	end
	return false
end

local function restoreUnclaimedFloorGeometryOnly(floorFolder: Instance)
	local function visit(inst: Instance)
		if inst:IsA("BasePart") then
			applyVisibleToInstance(inst, true)
		elseif inst:IsA("Decal") or inst:IsA("Texture") then
			applyVisibleToInstance(inst, true)
		elseif inst:IsA("ProximityPrompt") then
			applyVisibleToInstance(inst, false)
		elseif inst:IsA("SurfaceGui") or inst:IsA("BillboardGui") then
			applyVisibleToInstance(inst, false)
		elseif inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam") then
			applyVisibleToInstance(inst, false)
		end
	end
	visit(floorFolder)
	for _, d in ipairs(floorFolder:GetDescendants()) do
		visit(d)
	end
end

local function stripStandAndSignUnderFloor(floorFolder: Instance)
	for _, d in ipairs(floorFolder:GetDescendants()) do
		if (d.Name == "Stands" or d.Name == "stands") and (d:IsA("Folder") or d:IsA("Model")) then
			setSubtreeVisible(d, false)
		end
	end
	for _, d in ipairs(floorFolder:GetDescendants()) do
		if d:IsA("Model") and isLikelyBrainrotStandModel(d) then
			setSubtreeVisible(d, false)
		end
	end
	hidePlotSignUnder(floorFolder)
	for _, d in ipairs(floorFolder:GetDescendants()) do
		if d:IsA("Model") then
			local ak = alphaNumericKey(d.Name)
			-- Floor unlock signs: tolerate "Upgrade/Add", "Upgrade Add", renamed variants.
			if ak == "upgradeadd" or (string.find(ak, "upgrade", 1, true) and string.find(ak, "add", 1, true)) then
				setSubtreeVisible(d, false)
				continue
			end
			-- Generic hanging sign meshes that still replicate under Floor — hide only when clearly interactive/UI.
			if ak == "sign" then
				if
					d:FindFirstChildWhichIsA("SurfaceGui", true)
					or d:FindFirstChildWhichIsA("BillboardGui", true)
					or d:FindFirstChildWhichIsA("ProximityPrompt", true)
					or d:FindFirstChild("GUIPart", true)
				then
					setSubtreeVisible(d, false)
				end
			end
		end
	end
	-- Stand UI shell used before BrainrotStand tag is applied
	for _, d in ipairs(floorFolder:GetDescendants()) do
		if d.Name == "LevelPanel" and (d:IsA("Folder") or d:IsA("Model")) then
			setSubtreeVisible(d, false)
		end
	end
end

local function restoreUnclaimedFirstStoryFloorOnly(story: Instance)
	local floorFolder = findFloorDirectUnder(story)
	if floorFolder then
		restoreUnclaimedFloorGeometryOnly(floorFolder)
		stripStandAndSignUnderFloor(floorFolder)
		return
	end
	for _, d in ipairs(story:GetDescendants()) do
		if isUnderStandsSubtree(d) then
			continue
		end
		if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
			applyVisibleToInstance(d, true)
		elseif d:IsA("SurfaceGui") or d:IsA("BillboardGui") then
			applyVisibleToInstance(d, false)
		end
	end
end

_applyPlotStoryVisibility = function(plot: Instance)
	if plot:GetAttribute("PlotFloorStub") == true then
		local story = firstStoryOf(plot)
		if story then
			restoreUnclaimedFirstStoryFloorOnly(story)
		else
			setSubtreeVisible(plot, true)
		end
		return
	end

	if plotIsClaimed(plot) then
		-- Claimed plots: only fix stand pads. Skip full-tree walks (major lag on 7 full bases).
		PlotStandPlaceholders.ensureStandsVisibleInPlot(plot)
		return
	end

	-- Unclaimed: hide upper stories + stands (cheap — no full-tree walks per descendant event).
	setSubtreeVisible(plot, true)
	for _, ch in ipairs(plot:GetChildren()) do
		local digits = string.match(ch.Name, "^(%d+)")
		local storyNum = if digits then tonumber(digits) else nil
		if storyNum and storyNum > 1 then
			setSubtreeVisible(ch, false)
		end
	end
	local story = firstStoryOf(plot)
	if story then
		local stands = findStandsFolder(story)
		if stands then
			setSubtreeVisible(stands, false)
		end
	end
	hidePlotSignUnder(plot)
	stripFloatingUiAndSigns(plot, false)
end

local function schedulePlotRefresh(plot: Instance)
	if refreshScheduled[plot] then
		return
	end
	refreshScheduled[plot] = true
	task.defer(function()
		refreshScheduled[plot] = nil
		if plot.Parent then
			_applyPlotStoryVisibility(plot)
		end
	end)
end

local function _plotRootFromDescendant(inst: Instance): Instance?
	local cur: Instance? = inst
	while cur do
		if PlotPaths.isPlotRoot(cur) then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

local function shouldHookPlot(plot: Instance): boolean
	return PlotPaths.isPlotRoot(plot)
end

local function ensureInternal(): Folder
	local f = ServerStorage:FindFirstChild("BrainrotInternal")
	if not f then
		f = Instance.new("Folder")
		f.Name = "BrainrotInternal"
		f.Parent = ServerStorage
	end
	return f :: Folder
end

local function tryHookPlot(plot: Instance)
	if not shouldHookPlot(plot) then
		return
	end
	if hooked[plot] then
		schedulePlotRefresh(plot)
		return
	end
	hooked[plot] = true

	plot:GetAttributeChangedSignal("PlotOwnerUserId"):Connect(function()
		schedulePlotRefresh(plot)
	end)

	plot.Destroying:Once(function()
		hooked[plot] = nil
		refreshScheduled[plot] = nil
	end)

	_applyPlotStoryVisibility(plot)
end

local function hookSpawnFolder(folder: Instance)
	if hookedFolders[folder] then
		for _, ch in ipairs(folder:GetChildren()) do
			tryHookPlot(ch)
		end
		return
	end
	hookedFolders[folder] = true

	for _, ch in ipairs(folder:GetChildren()) do
		tryHookPlot(ch)
	end
	folder.ChildAdded:Connect(function(ch)
		if PlotPaths.isPlotRoot(ch) then
			task.defer(function()
				tryHookPlot(ch)
			end)
		end
	end)
end

local function bootstrapSpawnFolders()
	local seen: { [Instance]: boolean } = {}
	local function add(folder: Instance?)
		if folder and not seen[folder] then
			seen[folder] = true
			hookSpawnFolder(folder)
		end
	end

	local map = Workspace:FindFirstChild("Map")
	if map then
		add(map:FindFirstChild("Spawn And Bases"))
	end
	for _, folder in ipairs(PlotPaths.collectSpawnAndBasesCandidates()) do
		if PlotPaths.anchorScore(folder) > 0 then
			add(folder)
		end
	end
end

local refreshBindable = ensureInternal():FindFirstChild("RequestPlotVisibilityRefresh")
if not refreshBindable then
	refreshBindable = Instance.new("BindableFunction")
	refreshBindable.Name = "RequestPlotVisibilityRefresh"
	refreshBindable.Parent = ensureInternal()
end
(refreshBindable :: BindableFunction).OnInvoke = function(plotOrNil: Instance?)
	if plotOrNil and plotOrNil:IsA("Instance") then
		schedulePlotRefresh(plotOrNil)
		return
	end
	for plot in pairs(hooked) do
		if plot.Parent then
			schedulePlotRefresh(plot)
		end
	end
end

task.spawn(function()
	PlotPaths.waitForSpawnAndBasesFolder(120)
	bootstrapSpawnFolders()
end)
