-- [ACTIVE] BrainrotVisualSettings
--[[
	Client-only brainrot visibility + mutation VFX toggles (Settings UI).
	• ShowOtherBrainrots (default on) — hide other players' world brainrots locally.
	• BrainrotVFXEnabled (default on) — disable ParticleEmitter / Trail / Beam on brainrots.
--]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local SHOW_OTHERS_ATTR = "ShowOtherBrainrots"
local VFX_ENABLED_ATTR = "BrainrotVFXEnabled"
local ATTR_LTM_PREV = "__OtherBrainrotLTM"
local ATTR_VFX_PREV = "__BrainrotVFXPrevEnabled"

local trackedModels: { [Model]: boolean } = {}
local trackedTools: { [Tool]: boolean } = {}

local function showOtherBrainrots(): boolean
	return player:GetAttribute(SHOW_OTHERS_ATTR) ~= false
end

local function brainrotVfxEnabled(): boolean
	return player:GetAttribute(VFX_ENABLED_ATTR) ~= false
end

local function resolveOwnerUserId(root: Instance): number?
	local uid = root:GetAttribute("OwnerUserId")
	if typeof(uid) == "number" then
		return uid
	end
	local char = root:FindFirstAncestorWhichIsA("Model")
	if char then
		local plr = Players:GetPlayerFromCharacter(char)
		if plr then
			return plr.UserId
		end
	end
	return nil
end

local function isBrainrotWorldModel(model: Model): boolean
	if model:GetAttribute("BrainrotStandDisplay") == true then
		return true
	end
	if model:GetAttribute("BrainrotCarryPhase") ~= nil then
		return true
	end
	if typeof(model:GetAttribute("BrainrotName")) == "string" and model:GetAttribute("BrainrotName") ~= "" then
		return true
	end
	return false
end

local function isBrainrotTool(tool: Tool): boolean
	return tool:GetAttribute("BrainrotTool") == true
end

local function shouldHideFromOthers(root: Instance): boolean
	if showOtherBrainrots() then
		return false
	end
	local owner = resolveOwnerUserId(root)
	if owner == nil then
		return false
	end
	return owner ~= player.UserId
end

local function applyPartVisibility(part: BasePart, hide: boolean)
	if hide then
		if part:GetAttribute(ATTR_LTM_PREV) == nil then
			part:SetAttribute(ATTR_LTM_PREV, part.LocalTransparencyModifier)
		end
		part.LocalTransparencyModifier = 1
	else
		local prev = part:GetAttribute(ATTR_LTM_PREV)
		if typeof(prev) == "number" then
			part.LocalTransparencyModifier = prev
		else
			part.LocalTransparencyModifier = 0
		end
		part:SetAttribute(ATTR_LTM_PREV, nil)
	end
end

local function applyVfxInstance(inst: Instance, enabled: boolean)
	if not (inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam")) then
		return
	end
	local fx = inst :: any
	if enabled then
		local prev = inst:GetAttribute(ATTR_VFX_PREV)
		if typeof(prev) == "boolean" then
			fx.Enabled = prev
		end
		inst:SetAttribute(ATTR_VFX_PREV, nil)
	else
		if inst:GetAttribute(ATTR_VFX_PREV) == nil then
			inst:SetAttribute(ATTR_VFX_PREV, fx.Enabled)
		end
		fx.Enabled = false
	end
end

local function applyInstance(root: Instance, inst: Instance)
	local hideOthers = shouldHideFromOthers(root)
	local vfxOn = brainrotVfxEnabled()
	if inst:IsA("BasePart") then
		applyPartVisibility(inst :: BasePart, hideOthers)
	end
	applyVfxInstance(inst, vfxOn)
end

local function applyToRoot(root: Instance)
	local hideOthers = shouldHideFromOthers(root)
	local vfxOn = brainrotVfxEnabled()

	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			applyPartVisibility(d :: BasePart, hideOthers)
		end
		applyVfxInstance(d, vfxOn)
	end
	if root:IsA("BasePart") then
		applyPartVisibility(root :: BasePart, hideOthers)
	end
end

local function trackModel(model: Model)
	if trackedModels[model] then
		applyToRoot(model)
		return
	end
	trackedModels[model] = true
	applyToRoot(model)
	model.DescendantAdded:Connect(function(ch)
		if not model.Parent then
			return
		end
		-- Only touch the new instance — never re-walk the whole model (O(n²) stutter).
		task.defer(function()
			if model.Parent and ch.Parent then
				applyInstance(model, ch)
			end
		end)
	end)
	model.Destroying:Once(function()
		trackedModels[model] = nil
	end)
end

local function trackTool(tool: Tool)
	if trackedTools[tool] then
		applyToRoot(tool)
		return
	end
	trackedTools[tool] = true
	applyToRoot(tool)
	tool.DescendantAdded:Connect(function(ch)
		task.defer(function()
			if tool.Parent and ch.Parent then
				applyInstance(tool, ch)
			end
		end)
	end)
	tool.Destroying:Once(function()
		trackedTools[tool] = nil
	end)
end

local function tryTrack(inst: Instance)
	if inst:IsA("Model") and isBrainrotWorldModel(inst) then
		trackModel(inst)
	elseif inst:IsA("Tool") and isBrainrotTool(inst) then
		trackTool(inst)
	end
end

local function scanWorkspace()
	-- Stack GetChildren + yields. Never Workspace:GetDescendants() (sync timeout).
	local stack: { Instance } = { Workspace }
	local scanned = 0
	while #stack > 0 do
		local node = table.remove(stack) :: Instance
		local ok, children = pcall(function()
			return node:GetChildren()
		end)
		if not ok or typeof(children) ~= "table" then
			continue
		end
		for _, ch in children do
			scanned += 1
			if scanned % 250 == 0 then
				task.wait()
			end
			tryTrack(ch)
			table.insert(stack, ch)
		end
	end
	for _, plr in Players:GetPlayers() do
		local bp = plr:FindFirstChildOfClass("Backpack")
		if bp then
			for _, ch in bp:GetChildren() do
				tryTrack(ch)
			end
		end
		if plr.Character then
			for _, ch in plr.Character:GetChildren() do
				tryTrack(ch)
			end
		end
	end
end

local function refreshAll()
	for model in trackedModels do
		if model.Parent then
			applyToRoot(model)
		end
	end
	for tool in trackedTools do
		if tool.Parent then
			applyToRoot(tool)
		end
	end
	scanWorkspace()
end

local BrainrotVisualSettings = {}

function BrainrotVisualSettings.showOtherBrainrots(): boolean
	return showOtherBrainrots()
end

function BrainrotVisualSettings.shouldShowHeaderForModel(model: Model): boolean
	if showOtherBrainrots() then
		return true
	end
	local owner = resolveOwnerUserId(model)
	if owner == nil then
		return true
	end
	return owner == player.UserId
end

function BrainrotVisualSettings.init()
	if player:GetAttribute(SHOW_OTHERS_ATTR) == nil then
		player:SetAttribute(SHOW_OTHERS_ATTR, true)
	end
	if player:GetAttribute(VFX_ENABLED_ATTR) == nil then
		player:SetAttribute(VFX_ENABLED_ATTR, true)
	end

	Workspace.DescendantAdded:Connect(function(inst)
		-- Ignore most streaming noise; only Models/Tools can be brainrots.
		if not (inst:IsA("Model") or inst:IsA("Tool")) then
			return
		end
		task.defer(function()
			tryTrack(inst)
		end)
	end)

	Players.PlayerAdded:Connect(function(plr)
		plr.CharacterAdded:Connect(function(char)
			char.ChildAdded:Connect(function(ch)
				task.defer(function()
					tryTrack(ch)
				end)
			end)
			for _, ch in char:GetChildren() do
				tryTrack(ch)
			end
		end)
		local bp = plr:WaitForChild("Backpack")
		bp.ChildAdded:Connect(function(ch)
			tryTrack(ch)
		end)
	end)

	for _, plr in Players:GetPlayers() do
		if plr.Character then
			for _, ch in plr.Character:GetChildren() do
				tryTrack(ch)
			end
		end
		local bp = plr:FindFirstChildOfClass("Backpack")
		if bp then
			for _, ch in bp:GetChildren() do
				tryTrack(ch)
			end
		end
	end

	player:GetAttributeChangedSignal(SHOW_OTHERS_ATTR):Connect(refreshAll)
	player:GetAttributeChangedSignal(VFX_ENABLED_ATTR):Connect(refreshAll)

	task.defer(scanWorkspace)
end

return BrainrotVisualSettings
