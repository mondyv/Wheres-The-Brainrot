-- [ACTIVE] MobileHaptics
--[[
	Mobile / gamepad haptic pulses for UI taps and selection changes.
]]

local HapticService = game:GetService("HapticService")
local UserInputService = game:GetService("UserInputService")

local M = {}

local lastPulseAt = 0.0
local MIN_GAP = 0.04

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
	local supported = false
	local ok = pcall(function()
		supported = HapticService:IsMotorSupported(inputType, motor)
	end)
	if not ok or not supported then
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
	pulse(Enum.VibrationMotor.Small, 0.62, 0.09)
	pulse(Enum.VibrationMotor.Large, 0.28, 0.07)
end

function M.select()
	pulse(Enum.VibrationMotor.Small, 0.5, 0.07)
end

function M.confirm()
	pulse(Enum.VibrationMotor.Large, 0.72, 0.12)
	pulse(Enum.VibrationMotor.Small, 0.55, 0.1)
end

return M
