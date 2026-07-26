-- [ACTIVE] ComingSoonZoneController
--[[
	While the local player stands in ComingSoonHitbox (Last land), shows
	"Coming Soon..." beside the head (animated dots, UiFonts body).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CharacterWorldNotif = require(script.Parent.CharacterWorldNotif)

local player = Players.LocalPlayer

local MESSAGE = "Coming Soon"
local TICK_INTERVAL = 0.2
local HITBOX_PADDING = 1.5
local CLOSE_DEBOUNCE = 0.18
local ZONE_TAG = "ComingSoonZone"

local ComingSoonZoneController = {}

local hitbox: BasePart? = nil
local tickAccum = 0
local insideZone = false
local closePending: thread? = nil
local heartbeatConn: RBXScriptConnection? = nil
local findConns: { RBXScriptConnection } = {}

local function cancelClose()
	if closePending then
		task.cancel(closePending)
		closePending = nil
	end
end

local function isPointInsidePartOBB(worldPoint: Vector3, part: BasePart, padding: number): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5 + Vector3.new(padding, padding, padding)
	return math.abs(localPt.X) <= half.X and math.abs(localPt.Y) <= half.Y and math.abs(localPt.Z) <= half.Z
end

local function showComingSoon()
	CharacterWorldNotif.show(player.Character, MESSAGE, {
		offset = Vector3.new(2.6, 1.5, 0),
		color = Color3.fromRGB(255, 236, 190),
	})
end

local function hideComingSoon()
	if CharacterWorldNotif.getBaseText() == MESSAGE then
		CharacterWorldNotif.dismiss()
	end
end

local function ensureShowing()
	if not CharacterWorldNotif.isActive() or CharacterWorldNotif.getBaseText() ~= MESSAGE then
		showComingSoon()
	end
end

local function partFromInstance(inst: Instance?): BasePart?
	if not inst or not inst.Parent then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		local model = inst :: Model
		if model.PrimaryPart and model.PrimaryPart.Parent then
			return model.PrimaryPart
		end
		return model:FindFirstChildWhichIsA("BasePart", true)
	end
	return inst:FindFirstChildWhichIsA("BasePart", true)
end

local function nameMatchesHitbox(name: string): boolean
	local lower = string.lower(name)
	return lower == "comingsoonhitbox"
		or lower == "coming soon hitbox"
		or lower == "comingsoon"
end

local function findNamedHitbox(root: Instance): BasePart?
	for _, d in root:GetDescendants() do
		if nameMatchesHitbox(d.Name) then
			local part = partFromInstance(d)
			if part then
				return part
			end
		end
	end
	return nil
end

local function resolveHitbox(): BasePart?
	if hitbox and hitbox.Parent then
		return hitbox
	end
	hitbox = nil

	for _, tagged in CollectionService:GetTagged(ZONE_TAG) do
		local part = partFromInstance(tagged)
		if part then
			hitbox = part
			return part
		end
	end

	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local lands = map:FindFirstChild("Lands")
	if lands then
		local lastLand = lands:FindFirstChild("Last land") or lands:FindFirstChild("Last Land")
		if lastLand then
			local part = findNamedHitbox(lastLand)
			if part then
				hitbox = part
				return part
			end
		end
		local part = findNamedHitbox(lands)
		if part then
			hitbox = part
			return part
		end
	end

	local part = findNamedHitbox(map)
	if part then
		hitbox = part
		return part
	end
	return nil
end

local function tick()
	local part = resolveHitbox()
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not part or not hrp or not hrp:IsA("BasePart") then
		if insideZone then
			insideZone = false
			cancelClose()
			hideComingSoon()
		end
		return
	end

	local inside = isPointInsidePartOBB(hrp.Position, part, HITBOX_PADDING)
	if inside then
		cancelClose()
		insideZone = true
		ensureShowing()
	elseif insideZone and not closePending then
		closePending = task.delay(CLOSE_DEBOUNCE, function()
			closePending = nil
			insideZone = false
			hideComingSoon()
		end)
	end
end

local function disconnectFindConns()
	for _, conn in findConns do
		conn:Disconnect()
	end
	table.clear(findConns)
end

local function watchForHitbox(root: Instance)
	table.insert(
		findConns,
		root.DescendantAdded:Connect(function(inst)
			if hitbox and hitbox.Parent then
				return
			end
			if nameMatchesHitbox(inst.Name) or CollectionService:HasTag(inst, ZONE_TAG) then
				local part = partFromInstance(inst)
				if part then
					hitbox = part
				end
			end
		end)
	)
end

function ComingSoonZoneController.init()
	if heartbeatConn then
		return
	end

	task.spawn(function()
		local map = Workspace:WaitForChild("Map", 60)
		if not map then
			return
		end
		watchForHitbox(map)

		table.insert(
			findConns,
			CollectionService:GetInstanceAddedSignal(ZONE_TAG):Connect(function(inst)
				local part = partFromInstance(inst)
				if part then
					hitbox = part
				end
			end)
		)

		-- Keep resolving; streaming / late parent can delay the part.
		for _ = 1, 60 do
			if resolveHitbox() then
				return
			end
			task.wait(2)
		end
	end)

	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		tickAccum += dt
		if tickAccum < TICK_INTERVAL then
			return
		end
		tickAccum = 0
		tick()
	end)

	Players.PlayerRemoving:Connect(function(leaving)
		if leaving ~= player then
			return
		end
		if heartbeatConn then
			heartbeatConn:Disconnect()
			heartbeatConn = nil
		end
		disconnectFindConns()
		cancelClose()
		hideComingSoon()
	end)
end

return ComingSoonZoneController
