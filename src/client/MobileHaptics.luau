-- [ACTIVE] MobileHaptics
--[[
	Mobile / gamepad haptic pulses for real UI decisions (accept, decline, confirm).
	Not for hover, close, or every sidebar tap.
]]

local HapticService = game:GetService("HapticService")
local UserInputService = game:GetService("UserInputService")

local M = {}

local lastPulseAt = 0.0
local MIN_GAP = 0.05

local INPUT_TYPES = {
	Enum.UserInputType.Gamepad1,
	Enum.UserInputType.Touch,
}

local function motorSupported(inputType: Enum.UserInputType, motor: Enum.VibrationMotor): boolean
	local supported = false
	local ok = pcall(function()
		supported = HapticService:IsMotorSupported(inputType, motor)
	end)
	return ok and supported
end

local function setMotor(inputType: Enum.UserInputType, motor: Enum.VibrationMotor, strength: number)
	pcall(function()
		HapticService:SetMotor(inputType, motor, strength)
	end)
end

local function burst(specs: { { motor: Enum.VibrationMotor, strength: number } }, duration: number)
	if not UserInputService.TouchEnabled and not UserInputService.GamepadEnabled then
		return
	end
	local now = os.clock()
	if now - lastPulseAt < MIN_GAP then
		return
	end
	lastPulseAt = now

	local used: { { inputType: Enum.UserInputType, motor: Enum.VibrationMotor } } = {}
	for _, spec in specs do
		for _, inputType in INPUT_TYPES do
			if motorSupported(inputType, spec.motor) then
				setMotor(inputType, spec.motor, spec.strength)
				table.insert(used, { inputType = inputType, motor = spec.motor })
			end
		end
	end
	if #used == 0 then
		return
	end
	task.delay(duration, function()
		for _, entry in used do
			setMotor(entry.inputType, entry.motor, 0)
		end
	end)
end

function M.tap()
	burst({
		{ motor = Enum.VibrationMotor.Small, strength = 0.58 },
		{ motor = Enum.VibrationMotor.Large, strength = 0.22 },
	}, 0.08)
end

function M.select()
	burst({
		{ motor = Enum.VibrationMotor.Small, strength = 0.48 },
	}, 0.06)
end

function M.confirm()
	burst({
		{ motor = Enum.VibrationMotor.Large, strength = 0.78 },
		{ motor = Enum.VibrationMotor.Small, strength = 0.52 },
	}, 0.12)
end

function M.error()
	burst({
		{ motor = Enum.VibrationMotor.Large, strength = 0.55 },
		{ motor = Enum.VibrationMotor.Small, strength = 0.7 },
	}, 0.1)
end

return M
