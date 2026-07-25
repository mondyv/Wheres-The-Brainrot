-- [ACTIVE] ComingSoonZoneController
--[[
	While the local player stands in Last land's ComingSoonHitbox, shows
	"Coming Soon..." beside the head (animated dots, UiFonts body).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CharacterWorldNotif = require(script.Parent.CharacterWorldNotif)

local player = Players.LocalPlayer

local MESSAGE = "Coming Soon"
local TICK_INTERVAL = 0.2
local HITBOX_PADDING = 1.5
local CLOSE_DEBOUNCE = 0.18

local ComingSoonZoneController = {}

local hitbox: BasePart? = nil
local tickAccum = 0
local insideZone = false
local closePending: thread? = nil
local heartbeatConn: RBXScriptConnection? = nil

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

local function resolveHitbox(): BasePart?
	if hitbox and hitbox.Parent then
		return hitbox
	end
	local map = Workspace:FindFirstChild("Map")
	local lands = map and map:FindFirstChild("Lands")
	local lastLand = lands and lands:FindFirstChild("Last land")
	if not lastLand then
		return nil
	end
	-- Hitbox lives directly under Last land (not under Models)
	local part = lastLand:FindFirstChild("ComingSoonHitbox")
	if not part then
		part = lastLand:FindFirstChild("ComingSoonHitbox", true)
	end
	if part and part:IsA("BasePart") then
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

function ComingSoonZoneController.init()
	if heartbeatConn then
		return
	end

	task.spawn(function()
		local map = Workspace:WaitForChild("Map", 30)
		if not map then
			warn("[ComingSoonZoneController] workspace.Map not found")
			return
		end
		local lands = map:WaitForChild("Lands", 20)
		if not lands then
			warn("[ComingSoonZoneController] Lands not found")
			return
		end
		local lastLand = lands:WaitForChild("Last land", 20)
		if not lastLand then
			warn("[ComingSoonZoneController] Last land not found")
			return
		end
		local part = lastLand:FindFirstChild("ComingSoonHitbox")
			or lastLand:WaitForChild("ComingSoonHitbox", 15)
		if not part or not part:IsA("BasePart") then
			warn("[ComingSoonZoneController] ComingSoonHitbox not found under Last land")
			return
		end
		hitbox = part
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
		cancelClose()
		hideComingSoon()
	end)
end

return ComingSoonZoneController
