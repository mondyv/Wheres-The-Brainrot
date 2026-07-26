-- [ACTIVE] SafeZoneBeaconController
--[[
	Shield icon billboard at the center of the spawn safe zone.
	Only shown when the local player is on land 2+ (and not already in the safe zone),
	so explorers can see which way home is.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local M = {}

local SHIELD_IMAGE = "rbxassetid://127281421187767"
local MIN_LAND_TO_SHOW = 2
local POLL_SEC = 0.2
local BILLBOARD_SIZE = UDim2.fromOffset(72, 72)
local STUDS_OFFSET = Vector3.new(0, 10, 0)
local MAX_DISTANCE = 5000
local BEACON_FOLDER_NAME = "SafeZoneBeacon"

local localPlayer = Players.LocalPlayer
local anchor: BasePart? = nil
local billboard: BillboardGui? = nil
local heartbeatConn: RBXScriptConnection? = nil
local pollAccum = 0
local centerRefreshAt = 0
local CENTER_REFRESH_SEC = 4

local function destroyBeacon()
	if billboard then
		billboard:Destroy()
		billboard = nil
	end
	if anchor then
		anchor:Destroy()
		anchor = nil
	end
end

local function ensureBeacon(center: Vector3): BillboardGui?
	if anchor and anchor.Parent and billboard and billboard.Parent then
		anchor.CFrame = CFrame.new(center)
		return billboard
	end
	destroyBeacon()

	local folder = Workspace:FindFirstChild(BEACON_FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = BEACON_FOLDER_NAME
		folder.Parent = Workspace
	end

	local part = Instance.new("Part")
	part.Name = "SafeZoneBeaconAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.new(center)
	part.Parent = folder
	anchor = part

	local bb = Instance.new("BillboardGui")
	bb.Name = "SafeZoneShield"
	bb.Adornee = part
	bb.Size = BILLBOARD_SIZE
	bb.StudsOffset = STUDS_OFFSET
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = MAX_DISTANCE
	bb.Enabled = false

	local icon = Instance.new("ImageLabel")
	icon.Name = "Shield"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromScale(1, 1)
	icon.Image = SHIELD_IMAGE
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = bb

	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	bb.Parent = playerGui or Workspace.CurrentCamera
	billboard = bb
	return bb
end

local function shouldShowBeacon(character: Model?, hrp: BasePart): boolean
	if SafezoneUtil.isWorldPointInSafezone(hrp.Position) then
		return false
	end
	local land = LandResolver.resolveLandAtPosition(hrp.Position)
	return typeof(land) == "number" and land >= MIN_LAND_TO_SHOW
end

local function tick(_dt: number)
	local character = localPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		if billboard then
			billboard.Enabled = false
		end
		return
	end

	local now = os.clock()
	local center: Vector3? = nil
	if now - centerRefreshAt >= CENTER_REFRESH_SEC or not anchor then
		centerRefreshAt = now
		SafezoneUtil.warmCacheAsync()
		center = SafezoneUtil.getSafezoneCenter()
	elseif anchor and anchor.Parent then
		center = anchor.Position
	end

	if not center then
		if billboard then
			billboard.Enabled = false
		end
		return
	end

	local bb = ensureBeacon(center)
	if not bb then
		return
	end
	bb.Enabled = shouldShowBeacon(character, hrp :: BasePart)
end

function M.init()
	if heartbeatConn then
		return
	end

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
		SafezoneUtil.awaitCacheReady(8)
	end)

	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		pollAccum += dt
		if pollAccum < POLL_SEC then
			return
		end
		pollAccum = 0
		local ok, err = pcall(tick, dt)
		if not ok then
			warn("[SafeZoneBeaconController] error:", err)
		end
	end)

	localPlayer.CharacterRemoving:Connect(function()
		if billboard then
			billboard.Enabled = false
		end
	end)
end

return M
