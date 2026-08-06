-- [ACTIVE] UIStandIdleAnimations
--[[
	Plays looped idle animations on the brainrots behind Map.UIStands.
	Also marks stand models Persistent so Shop / Sell / Upgrade pads stay
	available under streaming (Shop Stand was often missing at client boot).
]]

local Workspace = game:GetService("Workspace")

local BrainrotAnimations = require(script.Parent.Modules.BrainrotAnimations)

local STANDS = {
	{
		standName = "Shop Stand",
		aliases = { "Shop Stand", "Dealer Stand", "Brainrot Dealer", "Shop", "Dealer" },
		brainrotName = "TatatataSahur",
		hitboxName = "ShopPadHitbox",
	},
	{
		standName = "Sell Stand",
		aliases = { "Sell Stand", "Sell" },
		brainrotName = "TricTracBarabum",
		hitboxName = "SellPadHitbox",
	},
	{
		standName = "Upgrade Stand",
		aliases = { "Upgrade Stand", "Upgrade" },
		brainrotName = "OrangutiniAnanassini",
		hitboxName = "UpgradePadHitbox",
	},
}

local wiredFolders: { [Instance]: boolean } = {}

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

local function normalizeKey(name: string): string
	return string.lower((string.gsub(name, "%s+", "")))
end

local function markPersistent(inst: Instance)
	if inst:IsA("Model") then
		pcall(function()
			(inst :: Model).ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		end)
		return
	end
	-- Folder stands: persist each child Model so pads/NPCs stay streamed.
	for _, child in inst:GetChildren() do
		if child:IsA("Model") then
			pcall(function()
				(child :: Model).ModelStreamingMode = Enum.ModelStreamingMode.Persistent
			end)
		end
	end
end

local function findStandFolder(uiStands: Instance, cfg: any): Instance?
	for _, alias in ipairs(cfg.aliases or { cfg.standName }) do
		local direct = uiStands:FindFirstChild(alias)
		if direct then
			return direct
		end
	end
	local wanted = normalizeKey(cfg.standName)
	for _, child in uiStands:GetChildren() do
		if normalizeKey(child.Name) == wanted then
			return child
		end
		for _, alias in ipairs(cfg.aliases or {}) do
			if normalizeKey(child.Name) == normalizeKey(alias) then
				return child
			end
		end
	end
	if typeof(cfg.hitboxName) == "string" then
		for _, child in uiStands:GetChildren() do
			local hit = child:FindFirstChild(cfg.hitboxName, true)
			if hit and hit:IsA("BasePart") then
				return child
			end
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

local function wireStand(standFolder: Instance, cfg: any)
	if wiredFolders[standFolder] then
		return
	end
	wiredFolders[standFolder] = true
	markPersistent(standFolder)
	local model = findBrainrot(standFolder, cfg.brainrotName)
	if not model then
		warn("[UIStandIdleAnimations] brainrot missing on", standFolder.Name)
		return
	end
	playIdle(model, cfg.brainrotName)
end

local function tryWireAll(uiStands: Instance)
	for _, cfg in ipairs(STANDS) do
		local standFolder = findStandFolder(uiStands, cfg)
		if standFolder then
			wireStand(standFolder, cfg)
		end
	end
end

local map = Workspace:WaitForChild("Map", 60)
if not map then
	warn("[UIStandIdleAnimations] workspace.Map missing")
	return
end

local uiStands = map:WaitForChild("UIStands", 60)
if not uiStands then
	warn("[UIStandIdleAnimations] Map.UIStands missing")
	return
end

-- Persist the UIStands container itself when it is a Model.
if uiStands:IsA("Model") then
	pcall(function()
		(uiStands :: Model).ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
end

tryWireAll(uiStands)
uiStands.ChildAdded:Connect(function()
	task.defer(function()
		tryWireAll(uiStands)
	end)
end)

task.spawn(function()
	for _ = 1, 30 do
		tryWireAll(uiStands)
		task.wait(2)
	end
end)
