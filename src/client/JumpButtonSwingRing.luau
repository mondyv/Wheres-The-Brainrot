-- [ACTIVE] JumpButtonSwingRing
--[[
	Green ring on the mobile JumpButton while latched on a swing.
	Tutorial can request a yellow coach ring (+ optional click icon) when not swinging.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local TutorialConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("TutorialConfig"))

local player = Players.LocalPlayer

local RING_NAME = "SwingJumpRing"
local CLICK_NAME = "SwingJumpRingClick"
local GREEN = Color3.fromRGB(72, 220, 110)
local YELLOW = Color3.fromRGB(255, 226, 70)

local M = {}

local ringHost: GuiButton? = nil
local ringFrame: Frame? = nil
local ringStroke: UIStroke? = nil
local clickLabel: ImageLabel? = nil
local pulseTween: Tween? = nil
local coachMode: string? = nil -- "press" | "lite" | nil
local attrConns: { RBXScriptConnection } = {}
local jumpScanAt = 0

local function findJumpButton(): GuiButton?
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	local touchGui = pg:FindFirstChild("TouchGui")
	if not touchGui then
		return nil
	end
	local frame = touchGui:FindFirstChild("TouchControlFrame")
	local jump = frame and frame:FindFirstChild("JumpButton")
	if jump and jump:IsA("GuiButton") then
		return jump
	end
	for _, d in touchGui:GetDescendants() do
		if d.Name == "JumpButton" and d:IsA("GuiButton") then
			return d
		end
	end
	return nil
end

local function stopPulse()
	if pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
	end
end

local function clearClick()
	if clickLabel then
		clickLabel:Destroy()
		clickLabel = nil
	end
end

local function clearRing()
	stopPulse()
	clearClick()
	if ringFrame then
		ringFrame:Destroy()
		ringFrame = nil
	end
	ringStroke = nil
	ringHost = nil
end

local function ensureRing(host: GuiButton, color: Color3)
	if ringHost ~= host or not ringFrame or not ringFrame.Parent then
		clearRing()
		ringHost = host
		local frame = Instance.new("Frame")
		frame.Name = RING_NAME
		frame.BackgroundTransparency = 1
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.5)
		frame.Size = UDim2.fromScale(1.18, 1.18)
		frame.ZIndex = host.ZIndex + 6
		frame.Active = false
		frame.Parent = host
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = frame
		local stroke = Instance.new("UIStroke")
		stroke.Name = "RingStroke"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.Thickness = 4.2
		stroke.Transparency = 0.05
		stroke.Parent = frame
		ringFrame = frame
		ringStroke = stroke
	end
	if ringStroke then
		ringStroke.Color = color
	end
end

local function ensureClick(host: GuiButton)
	if clickLabel and clickLabel.Parent == host then
		return
	end
	clearClick()
	local pointer = Instance.new("ImageLabel")
	pointer.Name = CLICK_NAME
	pointer.BackgroundTransparency = 1
	pointer.Image = TutorialConfig.UI_CLICK_IMAGE
	pointer.ScaleType = Enum.ScaleType.Fit
	pointer.AnchorPoint = Vector2.new(0.5, 0.5)
	pointer.Position = UDim2.fromScale(0.55, 0.55)
	pointer.Size = UDim2.fromOffset(TutorialConfig.UI_CLICK_SIZE, TutorialConfig.UI_CLICK_SIZE)
	pointer.ZIndex = host.ZIndex + 8
	pointer.Active = false
	pointer.Parent = host
	clickLabel = pointer
	task.spawn(function()
		while clickLabel == pointer and pointer.Parent do
			local up = TweenService:Create(pointer, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.fromOffset(TutorialConfig.UI_CLICK_SIZE + 6, TutorialConfig.UI_CLICK_SIZE + 6),
			})
			up:Play()
			up.Completed:Wait()
			if clickLabel ~= pointer or not pointer.Parent then
				break
			end
			local down = TweenService:Create(pointer, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Size = UDim2.fromOffset(TutorialConfig.UI_CLICK_SIZE, TutorialConfig.UI_CLICK_SIZE),
			})
			down:Play()
			down.Completed:Wait()
		end
	end)
end

local function startPulse()
	if not ringStroke then
		return
	end
	stopPulse()
	ringStroke.Thickness = 3.4
	local tw = TweenService:Create(
		ringStroke,
		TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Thickness = 5.2, Transparency = 0.22 }
	)
	pulseTween = tw
	tw:Play()
end

local function refresh()
	if not UserInputService.TouchEnabled then
		clearRing()
		return
	end

	local swinging = player:GetAttribute("IsSwinging") == true
	local jump = findJumpButton()
	if not jump then
		-- TouchGui can appear late — retry briefly.
		if os.clock() - jumpScanAt > 0.75 then
			jumpScanAt = os.clock()
		end
		clearRing()
		return
	end

	if swinging then
		ensureRing(jump, GREEN)
		clearClick()
		startPulse()
		return
	end

	if coachMode == "press" then
		ensureRing(jump, YELLOW)
		ensureClick(jump)
		startPulse()
		return
	end

	if coachMode == "lite" then
		ensureRing(jump, YELLOW)
		clearClick()
		startPulse()
		return
	end

	clearRing()
end

function M.setTutorialCoach(mode: string?)
	if mode ~= "press" and mode ~= "lite" and mode ~= nil then
		mode = nil
	end
	coachMode = mode
	refresh()
end

function M.refresh()
	refresh()
end

function M.init()
	table.insert(attrConns, player:GetAttributeChangedSignal("IsSwinging"):Connect(refresh))
	task.spawn(function()
		while player.Parent do
			refresh()
			task.wait(0.35)
		end
	end)
	refresh()
end

return M
