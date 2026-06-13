-- [ACTIVE] BushHarvestFloating
--[[
	Floating bush harvest offers: brainrot bobs above the bush with a claim ProximityPrompt.
	Player must interact to carry it; unclaimed offers vanish when the timer expires.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local M = {}

local FLOAT_CLAIM_DURATION = 15
local CLAIM_PROMPT_NAME = "BrainrotFloatingClaim"
local CUSTOM_PROMPT_ATTR = "CustomPromptFX"
local FLOATING_CLAIM_ATTR = "BrainrotFloatingClaim"
local FLOAT_ENDS_AT_ATTR = "BrainrotFloatEndsAt"
local CLAIMING_ATTR = "BrainrotFloatClaiming"

local claimConnByClone: { [Model]: RBXScriptConnection } = {}
local vanishTokenByClone: { [Model]: number } = {}

export type Deps = {
	pendingFloats: { [Player]: { Model } },
	floatConnByClone: { [Model]: RBXScriptConnection },
	removePendingFloat: (Player, Model) -> (),
	syncBrainrotCarryCountAttr: (Player) -> (),
	attachCarriedBrainrot: (Player, Model) -> (),
	getMainPart: (Model) -> BasePart?,
	setAllPartsPhysics: (Model, boolean, boolean) -> (),
}

local function getVanishRemote(): RemoteEvent?
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	if not folder then
		return nil
	end
	local ev = folder:FindFirstChild("FloatingClaimVanish")
	if ev and ev:IsA("RemoteEvent") then
		return ev
	end
	return nil
end

local function ensureVanishRemote(): RemoteEvent
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "BushRemotes"
		folder.Parent = ReplicatedStorage
	end
	local ev = folder:FindFirstChild("FloatingClaimVanish")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "FloatingClaimVanish"
		ev.Parent = folder
	end
	return ev :: RemoteEvent
end

local function fireVanishFX(player: Player, clone: Model)
	local rarity = clone:GetAttribute("BrainrotRarity")
	local main = clone:FindFirstChildWhichIsA("BasePart", true)
	local pos = if main then main.Position else clone:GetPivot().Position
	local remote = ensureVanishRemote()
	remote:FireClient(player, pos, if typeof(rarity) == "string" then rarity else "common")
end

local function disconnectClaimConn(clone: Model)
	local conn = claimConnByClone[clone]
	if conn then
		conn:Disconnect()
		claimConnByClone[clone] = nil
	end
end

local function disconnectFloatConn(deps: Deps, clone: Model)
	local conn = deps.floatConnByClone[clone]
	if conn then
		conn:Disconnect()
		deps.floatConnByClone[clone] = nil
	end
end

local function destroyClaimPrompt(clone: Model)
	local prompt = clone:FindFirstChild(CLAIM_PROMPT_NAME, true)
	if prompt then
		prompt:Destroy()
	end
end

local function tweenModelVanish(clone: Model, onDone: (() -> ())?)
	local parts: { BasePart } = {}
	for _, desc in clone:GetDescendants() do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	if #parts == 0 then
		if onDone then
			onDone()
		end
		return
	end

	local token = (vanishTokenByClone[clone] or 0) + 1
	vanishTokenByClone[clone] = token
	local tweenInfo = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local remaining = #parts
	for _, part in parts do
		TweenService:Create(part, tweenInfo, {
			Transparency = 1,
			Size = part.Size * 0.2,
		}):Play()
	end
	task.delay(0.48, function()
		if vanishTokenByClone[clone] ~= token then
			return
		end
		if onDone then
			onDone()
		end
	end)
end

function M.destroyFloatingOffer(deps: Deps, player: Player?, clone: Model, playVanish: boolean)
	disconnectFloatConn(deps, clone)
	disconnectClaimConn(clone)
	destroyClaimPrompt(clone)

	if not clone.Parent then
		return
	end

	if player then
		deps.removePendingFloat(player, clone)
	end

	if playVanish then
		if player then
			fireVanishFX(player, clone)
		end
		tweenModelVanish(clone, function()
			if clone.Parent then
				clone:Destroy()
			end
		end)
	else
		clone:Destroy()
	end
end

local function playClaimTween(clone: Model, char: Model, onDone: (() -> ())?)
	local main = clone:FindFirstChildWhichIsA("BasePart", true)
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not main or not hrp or not hrp:IsA("BasePart") then
		if onDone then
			onDone()
		end
		return
	end

	local startCf = clone:GetPivot()
	local goalPos = hrp.Position + Vector3.new(0, 2.8, 0)
	local mid = (startCf.Position + goalPos) * 0.5 + Vector3.new(0, 2.5, 0)
	local duration = 0.38
	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if not clone.Parent or not char.Parent then
			conn:Disconnect()
			if onDone then
				onDone()
			end
			return
		end
		local alpha = math.clamp((os.clock() - t0) / duration, 0, 1)
		local eased = 1 - (1 - alpha) ^ 3
		local a = startCf.Position:Lerp(mid, eased)
		local b = mid:Lerp(goalPos, eased)
		local pos = a:Lerp(b, eased)
		local spin = eased * math.pi * 2
		clone:PivotTo(CFrame.new(pos) * CFrame.Angles(0, spin, 0))
		if alpha >= 1 then
			conn:Disconnect()
			if onDone then
				onDone()
			end
		end
	end)
end

function M.claimFloatingBrainrot(deps: Deps, player: Player, clone: Model): boolean
	if clone:GetAttribute("BrainrotCarryPhase") ~= "Floating" then
		return false
	end
	if clone:GetAttribute(CLAIMING_ATTR) == true then
		return false
	end
	local ownerId = clone:GetAttribute("OwnerUserId")
	if typeof(ownerId) ~= "number" or ownerId ~= player.UserId then
		return false
	end

	local char = player.Character
	if not char then
		return false
	end

	clone:SetAttribute(CLAIMING_ATTR, true)
	disconnectFloatConn(deps, clone)
	disconnectClaimConn(clone)
	destroyClaimPrompt(clone)
	deps.removePendingFloat(player, clone)
	deps.syncBrainrotCarryCountAttr(player)

	playClaimTween(clone, char, function()
		if not clone.Parent then
			return
		end
		clone:SetAttribute(CLAIMING_ATTR, nil)
		deps.attachCarriedBrainrot(player, clone)
	end)
	return true
end

local function destroyAllProximityPrompts(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			d:Destroy()
		end
	end
end

local function attachClaimPrompt(deps: Deps, player: Player, clone: Model)
	local main = deps.getMainPart(clone)
	if not main then
		return
	end

	local existing = main:FindFirstChild(CLAIM_PROMPT_NAME)
	if existing then
		existing:Destroy()
	end

	local brainrotName = clone:GetAttribute("BrainrotName")
	local anchor = main:FindFirstChild("FloatingClaimPromptAnchor")
	if not anchor or not anchor:IsA("Attachment") then
		if anchor then
			anchor:Destroy()
		end
		anchor = Instance.new("Attachment")
		anchor.Name = "FloatingClaimPromptAnchor"
		anchor.Parent = main
	end
	anchor.Position = main.CFrame:PointToObjectSpace(clone:GetPivot().Position)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = CLAIM_PROMPT_NAME
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = "Catch"
	prompt.ObjectText = if typeof(brainrotName) == "string" and brainrotName ~= "" then brainrotName else "Brainrot"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.Enabled = true
	prompt:SetAttribute(CUSTOM_PROMPT_ATTR, true)
	prompt:SetAttribute(FLOATING_CLAIM_ATTR, true)
	prompt.Parent = anchor

	claimConnByClone[clone] = prompt.Triggered:Connect(function(plr: Player)
		if plr ~= player then
			return
		end
		M.claimFloatingBrainrot(deps, player, clone)
	end)
end

function M.startOffer(deps: Deps, player: Player, char: Model, clone: Model, anchorPos: Vector3, baseYaw: number)
	local plist = deps.pendingFloats[player]
	if not plist then
		plist = {}
		deps.pendingFloats[player] = plist
	end
	table.insert(plist, clone)
	deps.syncBrainrotCarryCountAttr(player)

	clone:SetAttribute(FLOAT_ENDS_AT_ATTR, Workspace:GetServerTimeNow() + FLOAT_CLAIM_DURATION)
	destroyAllProximityPrompts(clone)
	attachClaimPrompt(deps, player, clone)

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if not clone.Parent then
			conn:Disconnect()
			deps.floatConnByClone[clone] = nil
			disconnectClaimConn(clone)
			if player then
				deps.removePendingFloat(player, clone)
			end
			return
		end
		if player.Character ~= char then
			conn:Disconnect()
			deps.floatConnByClone[clone] = nil
			M.destroyFloatingOffer(deps, player, clone, true)
			return
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			conn:Disconnect()
			deps.floatConnByClone[clone] = nil
			M.destroyFloatingOffer(deps, player, clone, true)
			return
		end

		if clone:GetAttribute("BrainrotCarryPhase") ~= "Floating" then
			conn:Disconnect()
			deps.floatConnByClone[clone] = nil
			return
		end

		local elapsed = os.clock() - t0
		if elapsed >= FLOAT_CLAIM_DURATION then
			conn:Disconnect()
			deps.floatConnByClone[clone] = nil
			M.destroyFloatingOffer(deps, player, clone, true)
			return
		end

		local urgency = math.clamp(elapsed / FLOAT_CLAIM_DURATION, 0, 1)
		local bobAmp = 0.32 + urgency * 0.12
		local spinSpeed = 0.42 + urgency * 0.35
		local t = elapsed
		local bob = math.sin(t * 2.8) * bobAmp
		local panX = math.sin(t * 0.75) * 0.55
		local panZ = math.cos(t * 0.62) * 0.55
		local yaw = baseYaw + t * spinSpeed
		local tilt = math.sin(t * 1.9) * (0.07 + urgency * 0.05)
		local pos = anchorPos + Vector3.new(panX, math.max(0.15, bob), panZ)
		clone:PivotTo(CFrame.new(pos) * CFrame.Angles(tilt * 0.35, yaw, tilt))
	end)
	deps.floatConnByClone[clone] = conn
end

function M.cleanupAllForPlayer(deps: Deps, player: Player, clones: { Model })
	for _, clone in clones do
		M.destroyFloatingOffer(deps, player, clone, false)
	end
end

return M
