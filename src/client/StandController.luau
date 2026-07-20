-- [ACTIVE] StandController
--[[
	StandController
	• Hitbox detection for UIStands pads
	• Undertale-style dialogue cutscene before opening Shop / Sell / Upgrades
	• Ensures stand brainrot idle animations play

	Workspace path:  workspace.Map.UIStands.<Stand Name>.<HitboxPart>
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local HUDController = require(script.Parent.HUDController)
local StandDialogueCutscene = require(script.Parent.StandDialogueCutscene)

local player = Players.LocalPlayer

if not player.Character then
	player.CharacterAdded:Wait()
end

-- ── Stand config ──────────────────────────────────────────────────────────────

local STAND_CONFIG = {
	{
		standName = "Shop Stand",
		hitboxName = "ShopPadHitbox",
		frameName = "Shop",
		brainrotName = "TatatataSahur",
		enterLabel = "SHOP",
		lines = {
			"HEY!! WELCOME TO MY SHOP!!",
			"WANT TO BUY SOME STUFF??",
		},
	},
	{
		standName = "Sell Stand",
		hitboxName = "SellPadHitbox",
		frameName = "Sell",
		brainrotName = "TricTracBarabum",
		enterLabel = "SELL",
		lines = {
			"GOT BRAINROTS?? I'LL BUY EM!!",
			"CASH FOR YOUR JUNK!!",
		},
	},
	{
		standName = "Upgrade Stand",
		hitboxName = "UpgradePadHitbox",
		frameName = "Upgrades",
		brainrotName = "OrangutiniAnanassini",
		enterLabel = "UPGRADE",
		lines = {
			"FEELING WEAK??",
			"LET ME UPGRADE YOUR SWING!!",
		},
	},
}

type StandEntry = {
	hitbox: BasePart,
	standFolder: Instance,
	brainrot: Model?,
	frameName: string,
	brainrotName: string,
	enterLabel: string,
	lines: { string },
	standName: string,
}

-- How long the player must be outside a hitbox before the UI closes.
local CLOSE_DEBOUNCE = 0.22

local stands: { StandEntry } = {}
local activeStandFrame: string? = nil
local closePending: thread? = nil
local dialogueBusy = false
-- After Exit (or cancel), ignore this pad until the player leaves it.
local dismissedStandKey: string? = nil

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

local function isPointInsidePartOBB(worldPoint: Vector3, part: BasePart, padding: number): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5 + Vector3.new(padding, padding, padding)
	return math.abs(localPt.X) <= half.X and math.abs(localPt.Y) <= half.Y and math.abs(localPt.Z) <= half.Z
end

local function findBrainrotModel(standFolder: Instance, brainrotName: string): Model?
	local child = standFolder:FindFirstChild(brainrotName)
	if child and child:IsA("Model") then
		return child
	end
	for _, desc in standFolder:GetChildren() do
		if desc:IsA("Model") and desc.Name ~= "Meshes" then
			return desc
		end
	end
	return nil
end

local function beginDialogue(stand: StandEntry)
	if dialogueBusy or StandDialogueCutscene.isActive() then
		return
	end
	local brainrot = stand.brainrot
	if not brainrot or not brainrot.Parent then
		brainrot = findBrainrotModel(stand.standFolder, stand.brainrotName)
		stand.brainrot = brainrot
	end
	if not brainrot then
		-- Fallback: open panel directly if brainrot missing
		activeStandFrame = stand.frameName
		HUDController.openFrameByName(stand.frameName)
		return
	end

	dialogueBusy = true
	task.spawn(function()
		local choseEnter = StandDialogueCutscene.play({
			standName = stand.standName,
			frameName = stand.frameName,
			brainrotName = stand.brainrotName,
			enterLabel = stand.enterLabel,
			lines = stand.lines,
		}, brainrot)

		dialogueBusy = false

		if choseEnter then
			dismissedStandKey = nil
			activeStandFrame = stand.frameName
			HUDController.openFrameByName(stand.frameName)
		else
			-- Stay in pad without reopening until they leave
			dismissedStandKey = stand.standName
			activeStandFrame = nil
		end
	end)
end

local function tick()
	local char = player.Character
	if not char then
		return
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end
	local hrpPos = (hrp :: BasePart).Position

	if dialogueBusy or StandDialogueCutscene.isActive() then
		-- If player somehow leaves while dialoguing, cancel
		local stillInside = false
		for _, stand in ipairs(stands) do
			if stand.hitbox.Parent and isPointInsidePartOBB(hrpPos, stand.hitbox, 2.75) then
				stillInside = true
				break
			end
		end
		if not stillInside then
			StandDialogueCutscene.cancel()
			dialogueBusy = false
		end
		return
	end

	local insideStand: StandEntry? = nil

	for _, stand in ipairs(stands) do
		if not stand.hitbox.Parent then
			continue
		end
		if isPointInsidePartOBB(hrpPos, stand.hitbox, 2.75) then
			insideStand = stand
			break
		end
	end

	if insideStand then
		cancelPendingClose()
		if dismissedStandKey == insideStand.standName then
			-- Chose Exit; wait until they leave the pad
			return
		end
		if activeStandFrame == insideStand.frameName then
			-- Already in the shop UI from this pad
			return
		end
		if activeStandFrame then
			-- Switched pads
			HUDController.closeCurrentFrame()
			activeStandFrame = nil
		end
		beginDialogue(insideStand)
	else
		dismissedStandKey = nil
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

		local brainrot = findBrainrotModel(standFolder, cfg.brainrotName)
		if brainrot then
			StandDialogueCutscene.ensureIdleAnimation(brainrot, cfg.brainrotName)
		else
			warn("[StandController] Brainrot model missing on " .. cfg.standName)
		end

		table.insert(stands, {
			hitbox = hitbox,
			standFolder = standFolder,
			brainrot = brainrot,
			frameName = cfg.frameName,
			brainrotName = cfg.brainrotName,
			enterLabel = cfg.enterLabel,
			lines = cfg.lines,
			standName = cfg.standName,
		})
	end

	if #stands == 0 then
		warn("[StandController] No stands loaded – check UIStands names")
		return
	end

	player.CharacterAdded:Connect(function()
		cancelPendingClose()
		activeStandFrame = nil
		dismissedStandKey = nil
		if StandDialogueCutscene.isActive() then
			StandDialogueCutscene.cancel()
		end
		dialogueBusy = false
	end)

	local heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		tickAccum += dt
		if tickAccum < TICK_INTERVAL then
			return
		end
		tickAccum = 0
		tick()
	end)
	-- Keep reference so connection is not GC'd; disconnect on leave is N/A for local forever loop
	player.AncestryChanged:Connect(function(_, parent)
		if not parent and heartbeatConn then
			heartbeatConn:Disconnect()
		end
	end)
end

return StandController
