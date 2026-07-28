-- [ACTIVE] SafeZoneBeaconController
--[[
	Distance label near the local character's head showing meters from the spawn safe zone edge.
	Always shown while the player is outside the safe zone (any land / distance).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local M = {}

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
local lastMeters: number? = nil

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

	local pos = (hrp :: BasePart).Position
	if SafezoneUtil.isWorldPointInSafezone(pos) then
		if billboard then
			billboard.Enabled = false
		end
		lastMeters = nil
		return
	end

	local horiz = SafezoneUtil.getHorizontalDistanceFromSafezone(pos)
	if horiz == nil then
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
