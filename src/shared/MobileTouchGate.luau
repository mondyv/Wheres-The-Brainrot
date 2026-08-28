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

local HOLD_BLOCK_SEC = 0.4
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
	"LuckyBlockCutscene",
	"BushSpiderCutscene",
	"WaveWebChaseFx",
	"StandDialogueCutscene",
	"PanelModalDim",
}

function M.recoverLocomotion()
	local player = Players.LocalPlayer
	if not player then
		return
	end
	if player:GetAttribute("WaveWebDeathLock") == true then
		return
	end
	if player:GetAttribute("IsSwinging") == true then
		return
	end
	if player:GetAttribute("WorkoutActive") == true then
		return
	end

	local pg = player:FindFirstChildOfClass("PlayerGui")
	if pg then
		for _, name in MODAL_OVERLAY_NAMES do
			local gui = pg:FindFirstChild(name)
			if gui and gui:IsA("ScreenGui") and gui.Enabled then
				return
			end
		end
	end

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	hum.PlatformStand = false
	hum.AutoRotate = true
	if hum.UseJumpPower then
		if hum.JumpPower <= 0 then
			hum.JumpPower = 50
		end
	end
	if hum.JumpHeight <= 0 then
		hum.JumpHeight = 7.2
	end
end

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
	M.recoverLocomotion()

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
		-- Roblox hides JumpButton while jump stats are zeroed — always leave a usable value.
		if hum.UseJumpPower then
			if hum.JumpPower <= 0 then
				hum.JumpPower = 50
			end
		elseif hum.JumpHeight <= 0 then
			hum.JumpHeight = 7.2
		end
		if hum.JumpHeight <= 0 then
			hum.JumpHeight = 7.2
		end
	end
end

function M.ensureTouchControlsVisible(force: boolean?)
	if not UserInputService.TouchEnabled then
		return
	end

	local now = os.clock()
	if not force and now - lastEnsureClock < ENSURE_DEBOUNCE_SEC then
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

	-- Main stays above TouchGui so HUD buttons receive taps. Empty Active=false
	-- chrome lets thumbstick/jump clicks pass through to TouchGui underneath.
	if main and main:IsA("ScreenGui") and savedMainDisplayOrder ~= nil then
		main.DisplayOrder = savedMainDisplayOrder
		savedMainDisplayOrder = nil
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

local ignoreUiUntil = 0.0

function M.canTapUi(): boolean
	if not UserInputService.TouchEnabled then
		return true
	end
	local last = UserInputService:GetLastInputType()
	if last ~= Enum.UserInputType.Touch then
		return true
	end
	refreshBlockState()
	local now = os.clock()
	local n = 0
	for _ in activeTouches do
		n += 1
	end
	-- Thumb on the stick must not disable HUD / accept with the other finger.
	if n >= 2 then
		return true
	end
	if now < ignoreUiUntil then
		return false
	end
	return not blockedUntilAllReleased
end

function M.init()
	if wired then
		return
	end
	wired = true

	local player = Players.LocalPlayer
	local function recoverSoon()
		task.defer(function()
			M.recoverLocomotion()
			M.ensureTouchControlsVisible(true)
		end)
		task.delay(0.45, function()
			M.recoverLocomotion()
			M.ensureTouchControlsVisible(true)
		end)
		task.delay(1.8, function()
			M.recoverLocomotion()
			M.ensureTouchControlsVisible(true)
		end)
	end
	player.CharacterAdded:Connect(recoverSoon)
	player:GetAttributeChangedSignal("IsSwinging"):Connect(function()
		if player:GetAttribute("IsSwinging") ~= true then
			task.delay(0.12, M.recoverLocomotion)
		end
	end)
	if player.Character then
		recoverSoon()
	end

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
		local startedAt = activeTouches[input]
		activeTouches[input] = nil
		local remaining = next(activeTouches) ~= nil
		if startedAt and not remaining and (os.clock() - startedAt) >= HOLD_BLOCK_SEC then
			-- Camera-drag lift must not click whatever is under the finger.
			ignoreUiUntil = os.clock() + 0.18
		end
		if not remaining then
			blockedUntilAllReleased = false
		else
			refreshBlockState()
		end
	end)

	RunService.Heartbeat:Connect(refreshBlockState)

	local playerGui = player:WaitForChild("PlayerGui")
	playerGui.ChildAdded:Connect(function(child)
		if child.Name == "TouchGui" or child.Name == "Main" then
			task.defer(M.ensureTouchControlsVisible)
		end
	end)

	task.defer(M.ensureTouchControlsVisible)
end

return M
