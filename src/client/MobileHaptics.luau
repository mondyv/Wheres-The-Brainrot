-- [ACTIVE] MobileHaptics
--[[
	Light mobile / gamepad haptic pulses for UI taps and selection changes.
]]

local HapticService = game:GetService("HapticService")
local UserInputService = game:GetService("UserInputService")

local M = {}

local lastPulseAt = 0.0
local MIN_GAP = 0.05

local function pulse(motor: Enum.VibrationMotor, strength: number, duration: number)
	if not UserInputService.TouchEnabled and not UserInputService.GamepadEnabled then
		return
	end
	local now = os.clock()
	if now - lastPulseAt < MIN_GAP then
		return
	end
	lastPulseAt = now

	local inputType = Enum.UserInputType.Gamepad1
	local okSupported = pcall(function()
		return HapticService:IsMotorSupported(inputType, motor)
	end)
	if not okSupported then
		return
	end
	local supported = false
	pcall(function()
		supported = HapticService:IsMotorSupported(inputType, motor)
	end)
	if not supported then
		return
	end
	pcall(function()
		HapticService:SetMotor(inputType, motor, strength)
	end)
	task.delay(duration, function()
		pcall(function()
			HapticService:SetMotor(inputType, motor, 0)
		end)
	end)
end

function M.tap()
	pulse(Enum.VibrationMotor.Small, 0.35, 0.06)
end

function M.select()
	pulse(Enum.VibrationMotor.Small, 0.22, 0.04)
end

function M.confirm()
	pulse(Enum.VibrationMotor.Large, 0.45, 0.09)
end

return M
