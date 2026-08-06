-- [ACTIVE] BushHarvestEmptyMessage
--[[
	Empty-bush billboard / flash / error-shake helpers extracted from BushHarvest.server
	so the main script stays under Luau's 200 local register limit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local BrainrotCarryVisual = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotCarryVisual"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local M = {}

local EMPTY_BUSH_MESSAGE = "No brainrots hiding!"
local EMPTY_BUSH_MESSAGE_LIFETIME = 4
local EMPTY_BUSH_FADE_DURATION = 1
local EMPTY_BUSH_HOLD_DURATION = EMPTY_BUSH_MESSAGE_LIFETIME - EMPTY_BUSH_FADE_DURATION
local EMPTY_BUSH_BILLBOARD_NAME = "BushEmptyMessage"
local BUSH_EMPTY_MESSAGE_ANCHOR_NAME = "_BushEmptyMessageAnchor"
local BUSH_PROMPT_LIFT_SCALE = 0.66
local BUSH_MESSAGE_FLOAT_ABOVE_PROMPT = 2.75
local BUSH_FLASH_RED = Color3.fromRGB(225, 48, 48)
local BUSH_FLASH_RESTORE_DURATION = 1.0
local BUSH_ERROR_SHAKE_DURATION = 0.5

export type Api = {
	FlashBushColor: (Instance, Color3, number?) -> (),
	clearEmptyBushMessageState: (Instance) -> (),
	showEmptyBushMessage: (Instance) -> (),
}

export type Deps = {
	bushTopWorldY: (Model?, number) -> number,
}

function M.create(deps: Deps): Api
	local emptyBushMessageHideToken: { [Instance]: number } = {}
	local bushFlashToken: { [Instance]: number } = {}
	local bushFlashTweens: { [Instance]: { Tween } } = {}
	local bushFlashOriginalColors: { [Instance]: { [BasePart]: Color3 } } = {}
	local bushErrorShakeToken: { [Instance]: number } = {}

	local function bushWorldTopY(bush: Instance, fallbackY: number): number
		if bush:IsA("Model") then
			return deps.bushTopWorldY(bush :: Model, fallbackY)
		end
		if bush:IsA("BasePart") then
			local part = bush :: BasePart
			return part.Position.Y + part.Size.Y * 0.5
		end
		return fallbackY
	end

	local function findBushPromptCenterWorld(bush: Instance): Vector3?
		for _, desc in bush:GetDescendants() do
			if desc:IsA("Attachment") and desc.Name == "_BushPromptCenter" then
				return desc.WorldPosition
			end
		end
		return nil
	end

	local function bushAlertFloatWorldPosition(bush: Instance): Vector3?
		local promptCenter = findBushPromptCenterWorld(bush)
		if promptCenter then
			local topY = bushWorldTopY(bush, promptCenter.Y)
			return Vector3.new(
				promptCenter.X,
				math.max(promptCenter.Y + BUSH_MESSAGE_FLOAT_ABOVE_PROMPT, topY + 3.5),
				promptCenter.Z
			)
		end

		if bush:IsA("Model") then
			local minV, maxV = BrainrotCarryVisual.getWorldAabb(bush :: Model)
			if minV and maxV then
				local center = (minV + maxV) * 0.5
				local height = math.max(0.5, maxV.Y - minV.Y)
				local promptY = center.Y + height * BUSH_PROMPT_LIFT_SCALE
				return Vector3.new(
					center.X,
					math.max(promptY + BUSH_MESSAGE_FLOAT_ABOVE_PROMPT, maxV.Y + 3.5),
					center.Z
				)
			end
		elseif bush:IsA("BasePart") then
			local part = bush :: BasePart
			local topY = part.Position.Y + part.Size.Y * 0.5
			local promptY = part.Position.Y + part.Size.Y * BUSH_PROMPT_LIFT_SCALE + 1
			return Vector3.new(
				part.Position.X,
				math.max(promptY + BUSH_MESSAGE_FLOAT_ABOVE_PROMPT, topY + 3.5),
				part.Position.Z
			)
		end

		return nil
	end

	local function ensureEmptyBushBillboardAnchor(bush: Instance): BasePart?
		local worldPos = bushAlertFloatWorldPosition(bush)
		if not worldPos then
			if bush:IsA("BasePart") then
				return bush
			end
			if bush:IsA("Model") then
				local model = bush :: Model
				if model.PrimaryPart then
					return model.PrimaryPart
				end
				return model:FindFirstChildWhichIsA("BasePart", true)
			end
			return nil
		end

		local existing = bush:FindFirstChild(BUSH_EMPTY_MESSAGE_ANCHOR_NAME)
		if existing and existing:IsA("BasePart") then
			existing.CFrame = CFrame.new(worldPos)
			return existing
		end

		local anchor = Instance.new("Part")
		anchor.Name = BUSH_EMPTY_MESSAGE_ANCHOR_NAME
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(0.15, 0.15, 0.15)
		anchor.CFrame = CFrame.new(worldPos)
		anchor.Parent = bush
		return anchor
	end

	local function isVisibleBushPart(part: BasePart): boolean
		if part.Name == BUSH_EMPTY_MESSAGE_ANCHOR_NAME or part.Name == "_BushPromptAnchor" then
			return false
		end
		if part.Transparency >= 1 then
			return false
		end
		local lowerName = string.lower(part.Name)
		if string.find(lowerName, "hitbox", 1, true) or string.find(lowerName, "collision", 1, true) then
			return false
		end
		return true
	end

	local function collectVisibleBushParts(bush: Instance): { BasePart }
		local parts: { BasePart } = {}
		if bush:IsA("BasePart") and isVisibleBushPart(bush) then
			table.insert(parts, bush)
		end
		for _, desc in bush:GetDescendants() do
			if desc:IsA("BasePart") and isVisibleBushPart(desc) then
				table.insert(parts, desc)
			end
		end
		return parts
	end

	local function cancelBushFlashTweens(bush: Instance)
		local tweens = bushFlashTweens[bush]
		if not tweens then
			return
		end
		for _, tween in tweens do
			tween:Cancel()
		end
		bushFlashTweens[bush] = nil
	end

	local function captureBushTransform(bush: Instance): CFrame?
		if bush:IsA("Model") then
			return bush:GetPivot()
		end
		if bush:IsA("BasePart") then
			return bush.CFrame
		end
		return nil
	end

	local function applyBushTransform(bush: Instance, cf: CFrame)
		if bush:IsA("Model") then
			bush:PivotTo(cf)
		elseif bush:IsA("BasePart") then
			bush.CFrame = cf
		end
	end

	local function flashBushColor(bush: Instance, flashColor: Color3, restoreDuration: number?)
		local duration = restoreDuration or BUSH_FLASH_RESTORE_DURATION
		local token = (bushFlashToken[bush] or 0) + 1
		bushFlashToken[bush] = token
		cancelBushFlashTweens(bush)

		local parts = collectVisibleBushParts(bush)
		if #parts == 0 then
			return
		end

		local originals = bushFlashOriginalColors[bush]
		if not originals then
			originals = {}
			bushFlashOriginalColors[bush] = originals
		end

		for _, part in parts do
			if not originals[part] then
				originals[part] = part.Color
			end
			part.Color = flashColor
		end

		local tweens: { Tween } = {}
		bushFlashTweens[bush] = tweens
		local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		for _, part in parts do
			local originalColor = originals[part]
			if originalColor then
				local tween = TweenService:Create(part, tweenInfo, { Color = originalColor })
				tween:Play()
				table.insert(tweens, tween)
			end
		end
	end

	local function ErrorShakeBush(bush: Instance, duration: number?)
		local shakeDuration = duration or BUSH_ERROR_SHAKE_DURATION
		local token = (bushErrorShakeToken[bush] or 0) + 1
		bushErrorShakeToken[bush] = token

		task.spawn(function()
			local base = captureBushTransform(bush)
			if not base then
				return
			end

			local start = os.clock()
			local endAt = start + shakeDuration
			local step = 1 / 40
			local posAmp = 0.035
			local rotAmp = math.rad(2.2)

			while bush.Parent and token == bushErrorShakeToken[bush] and os.clock() < endAt do
				local elapsed = os.clock() - start
				local fade = 1 - math.clamp(elapsed / shakeDuration, 0, 1)
				local side = if math.floor(elapsed * 16) % 2 == 0 then 1 else -1
				local offset = CFrame.new(side * posAmp * fade, 0, 0) * CFrame.Angles(0, 0, side * rotAmp * fade)
				applyBushTransform(bush, base * offset)
				task.wait(step)
			end

			if token == bushErrorShakeToken[bush] and bush.Parent then
				applyBushTransform(bush, base)
			end
		end)
	end

	local function resetEmptyBushMessageVisuals(billboard: BillboardGui)
		local label = billboard:FindFirstChild("Text")
		if not label or not label:IsA("TextLabel") then
			return
		end
		label.TextTransparency = 0
		local textStroke = label:FindFirstChildOfClass("UIStroke")
		if textStroke then
			textStroke.Transparency = 0
		end
	end

	local function createEmptyBushBillboard(bush: Instance, anchor: BasePart): BillboardGui
		local billboard = Instance.new("BillboardGui")
		billboard.Name = EMPTY_BUSH_BILLBOARD_NAME
		billboard.Adornee = anchor
		billboard.AlwaysOnTop = true
		billboard.LightInfluence = 0
		billboard.Size = UDim2.fromOffset(300, 44)
		billboard.StudsOffset = Vector3.zero
		billboard.MaxDistance = 80
		billboard.Parent = bush

		local label = Instance.new("TextLabel")
		label.Name = "Text"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = EMPTY_BUSH_MESSAGE
		label.TextWrapped = true
		label.TextColor3 = Color3.fromRGB(240, 255, 244)
		UiFonts.applyBodyLabel(label, 20, 14)
		label.Parent = billboard

		local textStroke = Instance.new("UIStroke")
		textStroke.Color = Color3.fromRGB(0, 0, 0)
		textStroke.Thickness = 2
		textStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		textStroke.Transparency = 0
		textStroke.Parent = label

		return billboard
	end

	local function destroyEmptyBushMessageArtifacts(bush: Instance)
		local billboard = bush:FindFirstChild(EMPTY_BUSH_BILLBOARD_NAME)
		if billboard and billboard:IsA("BillboardGui") then
			billboard:Destroy()
		end
		local anchor = bush:FindFirstChild(BUSH_EMPTY_MESSAGE_ANCHOR_NAME)
		if anchor and anchor:IsA("BasePart") then
			anchor:Destroy()
		end
	end

	local function clearEmptyBushMessageState(bush: Instance)
		emptyBushMessageHideToken[bush] = (emptyBushMessageHideToken[bush] or 0) + 1
		destroyEmptyBushMessageArtifacts(bush)
	end

	local function fadeOutAndDestroyEmptyBushMessage(bush: Instance, token: number)
		task.delay(EMPTY_BUSH_HOLD_DURATION, function()
			if not bush.Parent or emptyBushMessageHideToken[bush] ~= token then
				return
			end

			local billboard = bush:FindFirstChild(EMPTY_BUSH_BILLBOARD_NAME)
			if not billboard or not billboard:IsA("BillboardGui") then
				emptyBushMessageHideToken[bush] = nil
				return
			end

			local fadeInfo = TweenInfo.new(EMPTY_BUSH_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local label = billboard:FindFirstChild("Text")
			if label and label:IsA("TextLabel") then
				TweenService:Create(label, fadeInfo, { TextTransparency = 1 }):Play()
				local textStroke = label:FindFirstChildOfClass("UIStroke")
				if textStroke then
					TweenService:Create(textStroke, fadeInfo, { Transparency = 1 }):Play()
				end
			end

			task.delay(EMPTY_BUSH_FADE_DURATION, function()
				if not bush.Parent or emptyBushMessageHideToken[bush] ~= token then
					return
				end
				destroyEmptyBushMessageArtifacts(bush)
				emptyBushMessageHideToken[bush] = nil
			end)
		end)
	end

	local function showEmptyBushMessage(bush: Instance)
		flashBushColor(bush, BUSH_FLASH_RED, BUSH_FLASH_RESTORE_DURATION)
		ErrorShakeBush(bush, BUSH_ERROR_SHAKE_DURATION)

		local anchor = ensureEmptyBushBillboardAnchor(bush)
		if not anchor then
			return
		end

		local token = (emptyBushMessageHideToken[bush] or 0) + 1
		emptyBushMessageHideToken[bush] = token

		local existing = bush:FindFirstChild(EMPTY_BUSH_BILLBOARD_NAME)
		if existing and existing:IsA("BillboardGui") then
			existing.Adornee = anchor
			existing.StudsOffset = Vector3.zero
			resetEmptyBushMessageVisuals(existing)
		else
			createEmptyBushBillboard(bush, anchor)
		end

		fadeOutAndDestroyEmptyBushMessage(bush, token)
	end

	return {
		FlashBushColor = flashBushColor,
		clearEmptyBushMessageState = clearEmptyBushMessageState,
		showEmptyBushMessage = showEmptyBushMessage,
	}
end

return M
