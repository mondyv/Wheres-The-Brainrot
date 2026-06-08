-- [ACTIVE] SlowWalk.client
--[[
	SlowWalkEnabled on the local player:
	• false (default) — "Slow: Off", 1.15× Humanoid.WalkSpeed at spawn
	• true — "Slow: On", 0.8× Humanoid.WalkSpeed at spawn
--]]

local Players = game:GetService("Players")

local player = Players.LocalPlayer
local FAST_WALK_MULT = 1.15
local SLOW_WALK_MULT = 0.8
local SLOW_WALK_ATTR = "SlowWalkEnabled"

local dispose: (() -> ())? = nil

local function bind(character: Model): () -> ()
	local humanoid = character:WaitForChild("Humanoid", 30) :: Humanoid?
	if not humanoid then
		return function() end
	end

	local baseWalkSpeed = humanoid.WalkSpeed
	humanoid:SetAttribute("BrainrotBaseWalkSpeed", baseWalkSpeed)

	local function applyWalkSpeed()
		if not humanoid.Parent then
			return
		end
		local slowOn = player:GetAttribute(SLOW_WALK_ATTR) == true
		humanoid.WalkSpeed = baseWalkSpeed * (if slowOn then SLOW_WALK_MULT else FAST_WALK_MULT)
	end

	applyWalkSpeed()

	local attrConn = player:GetAttributeChangedSignal(SLOW_WALK_ATTR):Connect(applyWalkSpeed)

	return function()
		attrConn:Disconnect()
	end
end

if player:GetAttribute(SLOW_WALK_ATTR) == nil then
	player:SetAttribute(SLOW_WALK_ATTR, false)
end

player.CharacterAdded:Connect(function(character)
	if dispose then
		dispose()
	end
	dispose = bind(character)
end)

if player.Character then
	if dispose then
		dispose()
	end
	dispose = bind(player.Character)
end
