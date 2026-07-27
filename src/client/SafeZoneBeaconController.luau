-- [ACTIVE] SafeZoneBeaconController
--[[
	Distance label near the local character's head showing meters from the spawn safe zone.
	Only shown when the local player is on land 2+ (and not already in the safe zone).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local M = {}

local MIN_LAND_TO_SHOW = 2
-- If land folders/hitboxes aren't streamed yet, still show once this far from spawn.
local FALLBACK_SHOW_DISTANCE = 180
local POLL_SEC = 0.35
local BILLBOARD_SIZE = UDim2.fromOffset(48, 18)
-- A bit right of the head, smaller label.
local STUDS_OFFSET = Vector3.new(2.15, 0.2, 0)
local TEXT_SIZE = 12
local GUI_NAME = "SafeZoneDistance"
local LEGACY_FOLDER_NAME = "SafeZoneBeacon"

local localPlayer = Players.LocalPlayer
local billboard: BillboardGui? = nil
local distanceLabel: TextLabel? = nil
local heartbeatConn: RBXScriptConnection? = nil
local pollAccum = 0
local centerRefreshAt = 0
local cachedCenter: Vector3? = nil
local CENTER_REFRESH_SEC = 4
local lastMeters: number? = nil
local cachedLand = 1
local landRefreshAt = 0
local LAND_REFRESH_SEC = 0.75
local lastLandPos: Vector3? = nil

local function destroyGui()
	if billboard then
		billboard:Destroy()
		billboard = nil
	end
	distanceLabel = nil
	lastMeters = nil
end

local function clearLegacyBeacon()
	local folder = Workspace:FindFirstChild(LEGACY_FOLDER_NAME)
	if folder then
		folder:Destroy()
	end
end

local function resolveAdornee(character: Model): BasePart?
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function ensureGui(character: Model): TextLabel?
	local adornee = resolveAdornee(character)
	if not adornee then
		return nil
	end
	if billboard and billboard.Parent and distanceLabel and billboard.Adornee == adornee then
		return distanceLabel
	end
	destroyGui()

	local bb = Instance.new("BillboardGui")
	bb.Name = GUI_NAME
	bb.Adornee = adornee
	bb.Size = BILLBOARD_SIZE
	bb.StudsOffset = STUDS_OFFSET
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	-- 0 = no camera-distance cutoff (far lands / zoomed camera still show meters).
	bb.MaxDistance = 0
	bb.Enabled = false

	local label = Instance.new("TextLabel")
	label.Name = "Meters"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	UiFonts.applyBodyLabel(label, TEXT_SIZE, 8)
	label.TextColor3 = Color3.fromRGB(245, 250, 255)
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0.35
	label.Text = ""
	label.Parent = bb

	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	bb.Parent = playerGui or Workspace.CurrentCamera
	billboard = bb
	distanceLabel = label
	return label
end

local function shouldShow(character: Model?, hrp: BasePart): boolean
	if SafezoneUtil.isWorldPointInSafezone(hrp.Position) then
		return false
	end
	local now = os.clock()
	local movedFar = not lastLandPos or (hrp.Position - lastLandPos).Magnitude > 18
	if movedFar or now - landRefreshAt >= LAND_REFRESH_SEC then
		landRefreshAt = now
		lastLandPos = hrp.Position
		cachedLand = LandResolver.resolveLandAtPosition(hrp.Position)
	end
	if cachedLand >= MIN_LAND_TO_SHOW then
		return true
	end
	-- Streaming may not have far-land hitboxes yet; distance fallback keeps meters on Land 9+.
	local center = cachedCenter
	if not center then
		return false
	end
	local delta = hrp.Position - center
	local horiz = Vector3.new(delta.X, 0, delta.Z).Magnitude
	return horiz >= FALLBACK_SHOW_DISTANCE
end

local function formatMeters(distance: number): string
	local meters = math.max(0, math.floor(distance + 0.5))
	return string.format("%dm", meters)
end

local function tick(_dt: number)
	local character = localPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not hrp or not hrp:IsA("BasePart") then
		if billboard then
			billboard.Enabled = false
		end
		return
	end

	local now = os.clock()
	if now - centerRefreshAt >= CENTER_REFRESH_SEC or not cachedCenter then
		centerRefreshAt = now
		SafezoneUtil.warmCacheAsync()
		cachedCenter = SafezoneUtil.getSafezoneCenter()
	end

	local center = cachedCenter
	if not center then
		if billboard then
			billboard.Enabled = false
		end
		return
	end

	local label = ensureGui(character)
	local bb = billboard
	if not label or not bb then
		return
	end

	if not shouldShow(character, hrp :: BasePart) then
		bb.Enabled = false
		return
	end

	local delta = (hrp :: BasePart).Position - center
	local horiz = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local meters = math.max(0, math.floor(horiz + 0.5))
	if lastMeters ~= meters then
		lastMeters = meters
		label.Text = formatMeters(horiz)
	end
	bb.Enabled = true
end

function M.init()
	if heartbeatConn then
		return
	end

	clearLegacyBeacon()

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
		SafezoneUtil.awaitCacheReady(8)
		cachedCenter = SafezoneUtil.getSafezoneCenter()
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

	localPlayer.CharacterAdded:Connect(function()
		destroyGui()
		lastMeters = nil
	end)

	localPlayer.CharacterRemoving:Connect(function()
		if billboard then
			billboard.Enabled = false
		end
	end)
end

return M
