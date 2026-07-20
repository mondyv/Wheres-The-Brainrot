-- [ACTIVE] UIStandIdleAnimations
--[[
	Plays looped idle animations on the brainrots behind Map.UIStands.
]]

local Workspace = game:GetService("Workspace")

local BrainrotAnimations = require(script.Parent.Modules.BrainrotAnimations)

local STANDS = {
	{ standName = "Shop Stand", brainrotName = "TatatataSahur" },
	{ standName = "Sell Stand", brainrotName = "TricTracBarabum" },
	{ standName = "Upgrade Stand", brainrotName = "OrangutiniAnanassini" },
}

local function resolveAnimator(model: Model): Animator?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			return animator
		end
		local created = Instance.new("Animator")
		created.Parent = humanoid
		return created
	end
	local controller = model:FindFirstChildOfClass("AnimationController")
	if not controller then
		return nil
	end
	local animator = controller:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end
	local created = Instance.new("Animator")
	created.Parent = controller
	return created
end

local function findBrainrot(standFolder: Instance, brainrotName: string): Model?
	local named = standFolder:FindFirstChild(brainrotName)
	if named and named:IsA("Model") then
		return named
	end
	for _, child in standFolder:GetChildren() do
		if child:IsA("Model") and child.Name ~= "Meshes" then
			return child
		end
	end
	return nil
end

local function playIdle(model: Model, brainrotName: string)
	local anim = BrainrotAnimations.getIdleAnimation(brainrotName)
	if not anim then
		warn("[UIStandIdleAnimations] no idle for", brainrotName)
		return
	end
	local animator = resolveAnimator(model)
	if not animator then
		warn("[UIStandIdleAnimations] no animator on", model:GetFullName())
		return
	end
	local ok, trackOrErr = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not ok or typeof(trackOrErr) ~= "Instance" then
		warn("[UIStandIdleAnimations] load failed:", trackOrErr)
		return
	end
	local track = trackOrErr :: AnimationTrack
	track.Priority = Enum.AnimationPriority.Idle
	track.Looped = true
	track:Play(0.15)
end

local map = Workspace:WaitForChild("Map", 60)
if not map then
	warn("[UIStandIdleAnimations] workspace.Map missing")
	return
end

local uiStands = map:WaitForChild("UIStands", 30)
if not uiStands then
	warn("[UIStandIdleAnimations] Map.UIStands missing")
	return
end

for _, cfg in ipairs(STANDS) do
	local standFolder = uiStands:WaitForChild(cfg.standName, 15)
	if not standFolder then
		warn("[UIStandIdleAnimations] stand missing:", cfg.standName)
		continue
	end
	local model = findBrainrot(standFolder, cfg.brainrotName)
	if not model then
		warn("[UIStandIdleAnimations] brainrot missing on", cfg.standName)
		continue
	end
	playIdle(model, cfg.brainrotName)
end
