--[[
	StandController
	• Hitbox detection: uses workspace:GetPartsInPart() every frame — works
	  regardless of CanCollide / CanTouch settings on the hitbox.
	• Top bar buttons: Buy → teleport to Shop stand, Sell → teleport to Sell stand.

	Workspace path:  workspace.Map.UIStands.<Stand Name>.<HitboxPart>
	Top buttons:     StarterGui.Main.SideUI.Top.Buttons.Buy / Sell
--]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

if not player.Character then
	player.CharacterAdded:Wait()
end

local HUDController = require(script.Parent.HUDController)

-- ── Stand config ──────────────────────────────────────────────────────────────

local STAND_CONFIG = {
	{ standName = "Shop Stand",    hitboxName = "ShopPadHitbox",    frameName = "Shop2"    },
	{ standName = "Sell Stand",    hitboxName = "SellPadHitbox",    frameName = "Sell"     },
	{ standName = "Upgrade Stand", hitboxName = "UpgradePadHitbox", frameName = "Upgrades" },
}

-- ── Overlap-based detection ───────────────────────────────────────────────────

-- How long the player must be outside a hitbox before the UI closes.
-- This swallows edge-of-hitbox flicker without adding noticeable delay.
local CLOSE_DEBOUNCE = 0.22

local stands: { { hitbox: BasePart, frameName: string } } = {}
local activeStandFrame: string? = nil
local closePending: thread?    = nil  -- delayed-close task

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Include

local function rebuildOverlapFilter()
	local char = player.Character
	if char then
		overlapParams.FilterDescendantsInstances = { char }
	end
end

local function cancelPendingClose()
	if closePending then
		task.cancel(closePending)
		closePending = nil
	end
end

local function scheduleClose()
	cancelPendingClose()
	closePending = task.delay(CLOSE_DEBOUNCE, function()
		closePending = nil
		activeStandFrame = nil
		HUDController.closeCurrentFrame()
	end)
end

local TICK_INTERVAL = 0.2
local tickAccum = 0

local function tick()
	local char = player.Character
	if not char then return end

	rebuildOverlapFilter()

	local insideFrame: string? = nil

	for _, stand in ipairs(stands) do
		if not stand.hitbox.Parent then continue end
		local parts = workspace:GetPartsInPart(stand.hitbox, overlapParams)
		if #parts > 0 then
			insideFrame = stand.frameName
			break
		end
	end

	if insideFrame then
		-- Cancel any pending close — player is (back) inside
		cancelPendingClose()
		if activeStandFrame ~= insideFrame then
			activeStandFrame = insideFrame
			HUDController.openFrameByName(insideFrame)
		end
	else
		-- Only schedule a close if one isn't already pending
		if activeStandFrame and not closePending then
			scheduleClose()
		end
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────

local StandController = {}

function StandController.init()
	local map = workspace:WaitForChild("Map", 20)
	if not map then
		warn("[StandController] workspace.Map not found")
		return
	end

	local uiStands = map:WaitForChild("UIStands", 15)
	if not uiStands then
		warn("[StandController] workspace.Map.UIStands not found")
		return
	end

	for _, cfg in ipairs(STAND_CONFIG) do
		local standFolder = uiStands:WaitForChild(cfg.standName, 10)
		if not standFolder then
			warn("[StandController] Stand not found: " .. cfg.standName)
			continue
		end

		local hitbox = standFolder:WaitForChild(cfg.hitboxName, 10) :: BasePart?
		if not hitbox then
			warn("[StandController] Hitbox not found: " .. cfg.hitboxName)
			continue
		end

		table.insert(stands, { hitbox = hitbox, frameName = cfg.frameName })
	end

	if #stands == 0 then
		warn("[StandController] No stands loaded – check UIStands names")
		return
	end

	-- Rebuild filter whenever the character respawns
	player.CharacterAdded:Connect(function()
		cancelPendingClose()
		activeStandFrame = nil
		task.wait()
		rebuildOverlapFilter()
	end)

	rebuildOverlapFilter()
	RunService.Heartbeat:Connect(function(dt)
		tickAccum += dt
		if tickAccum < TICK_INTERVAL then
			return
		end
		tickAccum = 0
		tick()
	end)
end

return StandController
