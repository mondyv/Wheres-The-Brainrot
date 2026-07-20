-- [ACTIVE] MobileTouchGate
--[[
	After holding a touch for HOLD_BLOCK_SEC without lifting, block proximity / UI taps
	until every finger is off the screen (prevents camera-drag false activations).

	Mobile: keep Roblox TouchGui at its default DisplayOrder (do NOT raise it above
	Main — that breaks thumbstick vs camera finger split). If Main paints over the
	controls, lower Main under TouchGui instead.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local M = {}

local HOLD_BLOCK_SEC = 0.2
local activeTouches: { [InputObject]: number } = {}
local blockedUntilAllReleased = false
local wired = false
local savedMainDisplayOrder: number? = nil
local lastEnsureClock = 0.0
local ENSURE_DEBOUNCE_SEC = 0.5

local MODAL_OVERLAY_NAMES = {
	"OfflineEarningsDim",
	"OfflineEarningsHost",
	"ReviveDim",
	"LoadingScreen",
	"FloatingClaimCutscene",
	"BushSpiderCutscene",
	"StandDialogueCutscene",
}

local function hasModalOverlay(playerGui: Instance): boolean
	for _, name in MODAL_OVERLAY_NAMES do
		local gui = playerGui:FindFirstChild(name)
		if gui and gui:IsA("ScreenGui") and gui.Enabled then
			return true
		end
	end
	local main = playerGui:FindFirstChild("Main")
	if main and main:IsA("ScreenGui") then
		local frames = main:FindFirstChild("Frames")
		local revive = frames and frames:FindFirstChild("Revive PopUP")
		if revive and revive:IsA("GuiObject") and revive.Visible then
			return true
		end
	end
	return false
end

local function findJumpButton(touchGui: Instance): GuiButton?
	local frame = touchGui:FindFirstChild("TouchControlFrame", true)
	if frame then
		local jump = frame:FindFirstChild("JumpButton")
		if jump and jump:IsA("GuiButton") then
			return jump
		end
	end
	for _, d in touchGui:GetDescendants() do
		if d.Name == "JumpButton" and d:IsA("GuiButton") then
			return d :: GuiButton
		end
	end
	return nil
end

function M.restorePlayerMovement()
	if not UserInputService.TouchEnabled then
		return
	end

	local player = Players.LocalPlayer
	if not player then
		return
	end

	pcall(function()
		(GuiService :: any).TouchControlsEnabled = true
	end)

	local playerScripts = player:FindFirstChild("PlayerScripts")
	local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if playerModule then
		local ok, mod = pcall(require, playerModule)
		if ok and typeof(mod) == "table" and typeof(mod.GetControls) == "function" then
			local controlsOk, controls = pcall(function()
				return mod:GetControls()
			end)
			if controlsOk and controls and typeof(controls.Enable) == "function" then
				pcall(function()
					controls:Enable()
				end)
			end
		end
	end

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
		hum.AutoRotate = true
	end
end

function M.ensureTouchControlsVisible()
	if not UserInputService.TouchEnabled then
		return
	end

	local now = os.clock()
	if now - lastEnsureClock < ENSURE_DEBOUNCE_SEC then
		return
	end
	lastEnsureClock = now

	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	pcall(function()
		(GuiService :: any).TouchControlsEnabled = true
	end)

	local touchGui = playerGui:FindFirstChild("TouchGui")
	local main = playerGui:FindFirstChild("Main")

	if touchGui and touchGui:IsA("ScreenGui") then
		touchGui.Enabled = true
		-- Never raise TouchGui DisplayOrder — that merges walk + camera on one finger.

		local touchFrame = touchGui:FindFirstChild("TouchControlFrame", true)
		if touchFrame and touchFrame:IsA("GuiObject") then
			touchFrame.Visible = true
		end

		for _, name in { "DynamicThumbstickFrame", "DynamicThumbstickFrameManager" } do
			local thumb = touchGui:FindFirstChild(name, true)
			if thumb and thumb:IsA("GuiObject") then
				thumb.Visible = true
			end
		end

		local jumpButton = findJumpButton(touchGui)
		if jumpButton then
			jumpButton.Visible = true
		end
	end

	-- Main above TouchGui hides jump; lowering Main keeps Roblox touch routing intact.
	if main and main:IsA("ScreenGui") and touchGui and touchGui:IsA("ScreenGui") then
		if not hasModalOverlay(playerGui) and main.DisplayOrder >= touchGui.DisplayOrder then
			if savedMainDisplayOrder == nil then
				savedMainDisplayOrder = main.DisplayOrder
			end
			main.DisplayOrder = math.max(0, touchGui.DisplayOrder - 1)
		end
	end
end

local function refreshBlockState()
	if not UserInputService.TouchEnabled then
		blockedUntilAllReleased = false
		return
	end
	if next(activeTouches) == nil then
		blockedUntilAllReleased = false
		return
	end
	local now = os.clock()
	for _, startedAt in activeTouches do
		if now - startedAt >= HOLD_BLOCK_SEC then
			blockedUntilAllReleased = true
			return
		end
	end
end

function M.canTapUi(): boolean
	if not UserInputService.TouchEnabled then
		return true
	end
	local last = UserInputService:GetLastInputType()
	if last ~= Enum.UserInputType.Touch then
		return true
	end
	refreshBlockState()
	return not blockedUntilAllReleased
end

function M.init()
	if wired then
		return
	end
	wired = true

	if not UserInputService.TouchEnabled then
		return
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, _processed: boolean)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		activeTouches[input] = os.clock()
		refreshBlockState()
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		activeTouches[input] = nil
		if next(activeTouches) == nil then
			blockedUntilAllReleased = false
		else
			refreshBlockState()
		end
	end)

	RunService.Heartbeat:Connect(refreshBlockState)

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	playerGui.ChildAdded:Connect(function(child)
		if child.Name == "TouchGui" or child.Name == "Main" then
			task.defer(M.ensureTouchControlsVisible)
		end
	end)
	player.CharacterAdded:Connect(function()
		task.defer(M.ensureTouchControlsVisible)
	end)

	task.defer(M.ensureTouchControlsVisible)
end

return M
