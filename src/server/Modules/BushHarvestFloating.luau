-- [ACTIVE] BushHarvestFloating
--[[
	Floating bush harvest offers: brainrot bobs above the bush with accept / decline UI.
	Player accepts to carry it; decline or timeout returns the bush to normal cooldown flow.
]]

local _Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local M = {}

M.FLOAT_CLAIM_DURATION = 15
local FLOAT_CLAIM_DURATION = M.FLOAT_CLAIM_DURATION
local FLOAT_ENDS_AT_ATTR = "BrainrotFloatEndsAt"
local FLOAT_ANCHOR_ATTR = "BrainrotFloatAnchorPos"
local CLAIMING_ATTR = "BrainrotFloatClaiming"
local DECLINING_ATTR = "BrainrotFloatDeclining"
local BUSH_KEY_ATTR = "BrainrotHarvestBushKey"

local vanishTokenByClone: { [Model]: number } = {}

export type Deps = {
	pendingFloats: { [Player]: { Model } },
	floatConnByClone: { [Model]: RBXScriptConnection },
	removePendingFloat: (Player, Model) -> (),
	syncBrainrotCarryCountAttr: (Player) -> (),
	attachCarriedBrainrot: (Player, Model) -> (),
	getMainPart: (Model) -> BasePart?,
	setAllPartsPhysics: (Model, boolean, boolean) -> (),
	releaseBushAfterFloatingTimeout: ((string) -> ())?,
}

local function getBushRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "BushRemotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function ensureVanishRemote(): RemoteEvent
	local folder = getBushRemotesFolder()
	local ev = folder:FindFirstChild("FloatingClaimVanish")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "FloatingClaimVanish"
		ev.Parent = folder
	end
	return ev :: RemoteEvent
end

local function ensureDeclineFxRemote(): RemoteEvent
	local folder = getBushRemotesFolder()
	local ev = folder:FindFirstChild("FloatingClaimDeclineFX")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "FloatingClaimDeclineFX"
		ev.Parent = folder
	end
	return ev :: RemoteEvent
end

function M.ensureDecisionRemote(): RemoteEvent
	local folder = getBushRemotesFolder()
	local ev = folder:FindFirstChild("FloatingClaimDecision")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "FloatingClaimDecision"
		ev.Parent = folder
	end
	return ev :: RemoteEvent
end

local function _fireVanishFX(player: Player, clone: Model)
	local rarity = clone:GetAttribute("BrainrotRarity")
	local main = clone:FindFirstChildWhichIsA("BasePart", true)
	local pos = if main then main.Position else clone:GetPivot().Position
	ensureVanishRemote():FireClient(player, pos, if typeof(rarity) == "string" then rarity else "common")
end

local function fireDeclineFX(player: Player, clone: Model)
	local rarity = clone:GetAttribute("BrainrotRarity")
	local main = clone:FindFirstChildWhichIsA("BasePart", true)
	local pos = if main then main.Position else clone:GetPivot().Position
	ensureDeclineFxRemote():FireClient(player, pos, if typeof(rarity) == "string" then rarity else "common")
end

local function disconnectFloatConn(deps: Deps, clone: Model)
	local conn = deps.floatConnByClone[clone]
	if conn then
		conn:Disconnect()
		deps.floatConnByClone[clone] = nil
	end
end

local function validateFloatingOwner(player: Player, clone: Model): boolean
	if clone:GetAttribute("BrainrotCarryPhase") ~= "Floating" then
		return false
	end
	if clone:GetAttribute(CLAIMING_ATTR) == true or clone:GetAttribute(DECLINING_ATTR) == true then
		return false
	end
	local ownerId = clone:GetAttribute("OwnerUserId")
	return typeof(ownerId) == "number" and ownerId == player.UserId
end

local function tweenModelVanish(clone: Model, sink: boolean?, onDone: (() -> ())?)
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
	local tweenInfo = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, part in parts do
		local goal: { [string]: any } = {
			Transparency = 1,
			Size = part.Size * 0.15,
		}
		if sink then
			goal.CFrame = part.CFrame * CFrame.new(0, -1.8, 0)
		end
		TweenService:Create(part, tweenInfo, goal):Play()
	end
	task.delay(0.44, function()
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

	if not clone.Parent then
		return
	end

	if player then
		deps.removePendingFloat(player, clone)
	end

	if
		playVanish
		and clone:GetAttribute(DECLINING_ATTR) ~= true
		and clone:GetAttribute(CLAIMING_ATTR) ~= true
		and deps.releaseBushAfterFloatingTimeout
	then
		local bushKey = clone:GetAttribute(BUSH_KEY_ATTR)
		if typeof(bushKey) == "string" and bushKey ~= "" then
			deps.releaseBushAfterFloatingTimeout(bushKey)
		end
	end

	if playVanish then
		if player then
			fireDeclineFX(player, clone)
		end
		tweenModelVanish(clone, true, function()
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

	local startPos = clone:GetPivot().Position
	local startCf = clone:GetPivot()
	local _, startYaw, _ = startCf:ToEulerAnglesYXZ()
	local duration = 0.58
	local t0 = os.clock()
	local startScale = 1
	pcall(function()
		startScale = clone:GetScale()
	end)

	local function easeOutCubic(x: number): number
		return 1 - (1 - x) ^ 3
	end

	local function liveGoal(): Vector3
		local head = char:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			return head.Position + Vector3.new(0, head.Size.Y * 0.55 + 0.35, 0)
		end
		local root = char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root.Position + Vector3.new(0, 2.85, 0)
		end
		return hrp.Position + Vector3.new(0, 2.85, 0)
	end

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
		local e = easeOutCubic(alpha)
		local goalPos = liveGoal()
		-- Always chase the player's *current* head; hop is relative to that path.
		local along = startPos:Lerp(goalPos, e)
		local hopY = math.sin(alpha * math.pi) * 4.2
		local pos = along + Vector3.new(0, hopY, 0)

		local scaleMul
		if alpha < 0.4 then
			scaleMul = 1 - (alpha / 0.4) * 0.28
		else
			local s = (alpha - 0.4) / 0.6
			scaleMul = 0.72 + (1 - (1 - s) ^ 2) * 0.28
		end
		pcall(function()
			clone:ScaleTo(startScale * scaleMul)
		end)

		local spin = startYaw + alpha * math.pi * 1.25
		clone:PivotTo(CFrame.new(pos) * CFrame.Angles(0, spin, math.sin(alpha * math.pi) * 0.12))

		if alpha >= 1 then
			conn:Disconnect()
			pcall(function()
				clone:ScaleTo(startScale)
			end)
			-- Snap to live head right before weld so a moving player never gets a stale slot.
			clone:PivotTo(CFrame.new(liveGoal()))
			if onDone then
				onDone()
			end
		end
	end)
end

function M.claimFloatingBrainrot(deps: Deps, player: Player, clone: Model): boolean
	if not validateFloatingOwner(player, clone) then
		return false
	end

	local char = player.Character
	if not char then
		return false
	end

	clone:SetAttribute(CLAIMING_ATTR, true)
	disconnectFloatConn(deps, clone)
	deps.removePendingFloat(player, clone)
	deps.syncBrainrotCarryCountAttr(player)

	task.spawn(function()
		local ok, PDS = pcall(function()
			return require(script.Parent:WaitForChild("PlayerDataService"))
		end)
		if ok and PDS and typeof(PDS.incrementBrainrotAcceptCount) == "function" then
			local okInc, errInc = pcall(PDS.incrementBrainrotAcceptCount, player)
			if not okInc then
				warn("[BushHarvestFloating] incrementBrainrotAcceptCount error:", errInc)
			end
		elseif not ok then
			warn("[BushHarvestFloating] PlayerDataService require failed:", PDS)
		end
	end)

	playClaimTween(clone, char, function()
		if not clone.Parent then
			return
		end
		clone:SetAttribute(CLAIMING_ATTR, nil)
		deps.attachCarriedBrainrot(player, clone)
	end)
	return true
end

function M.declineFloatingBrainrot(deps: Deps, player: Player, clone: Model): boolean
	if not validateFloatingOwner(player, clone) then
		return false
	end

	clone:SetAttribute(DECLINING_ATTR, true)
	disconnectFloatConn(deps, clone)
	deps.removePendingFloat(player, clone)
	deps.syncBrainrotCarryCountAttr(player)

	fireDeclineFX(player, clone)
	tweenModelVanish(clone, true, function()
		if clone.Parent then
			clone:Destroy()
		end
	end)
	return true
end

function M.handleDecision(deps: Deps, player: Player, clone: Model, decision: string): boolean
	if decision == "accept" then
		return M.claimFloatingBrainrot(deps, player, clone)
	end
	if decision == "decline" then
		return M.declineFloatingBrainrot(deps, player, clone)
	end
	return false
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
	clone:SetAttribute(FLOAT_ANCHOR_ATTR, anchorPos)

	-- Match pop handoff pose (lift 0.22, pans at 0) then ease into orbit — no snap.
	local HANDOFF_LIFT = 0.22
	local ORBIT_BLEND_SEC = 0.55
	local startPivot = clone:GetPivot()
	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if not clone.Parent then
			conn:Disconnect()
			deps.floatConnByClone[clone] = nil
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
		local orbitT = math.clamp(elapsed / ORBIT_BLEND_SEC, 0, 1)
		local orbitEase = 1 - (1 - orbitT) ^ 2
		local bobAmp = 0.32 + urgency * 0.12
		local spinSpeed = 0.42 + urgency * 0.35
		local t = elapsed
		-- sin(0)=0 so pans/bob start centered; ease amplitude in for a smooth handoff.
		local bob = math.sin(t * 2.8) * bobAmp * orbitEase
		local panX = math.sin(t * 0.75) * 0.55 * orbitEase
		local panZ = math.sin(t * 0.62) * 0.55 * orbitEase
		local yaw = baseYaw + t * spinSpeed * orbitEase
		local tilt = math.sin(t * 1.9) * (0.07 + urgency * 0.05) * orbitEase
		local pos = anchorPos + Vector3.new(panX, HANDOFF_LIFT + bob, panZ)
		local goalCf = CFrame.new(pos) * CFrame.Angles(tilt * 0.35, yaw, tilt)
		if orbitT < 1 then
			clone:PivotTo(startPivot:Lerp(goalCf, orbitEase))
		else
			clone:PivotTo(goalCf)
		end
	end)
	deps.floatConnByClone[clone] = conn
end

function M.cleanupAllForPlayer(deps: Deps, player: Player, clones: { Model })
	for _, clone in clones do
		M.destroyFloatingOffer(deps, player, clone, false)
	end
end

function M.wireDecisionRemote(deps: Deps)
	local ev = M.ensureDecisionRemote()
	ev.OnServerEvent:Connect(function(player: Player, clone: any, decision: any)
		if typeof(clone) ~= "Instance" or not clone:IsA("Model") then
			return
		end
		if typeof(decision) ~= "string" then
			return
		end
		if not clone:IsDescendantOf(Workspace) then
			return
		end
		local ok = M.handleDecision(deps, player, clone, decision)
		if not ok then
			warn("[BushHarvestFloating] FloatingClaimDecision rejected for", player.Name, decision)
		end
	end)
end

return M
