-- [ACTIVE] BrainrotGradientAnimator
--[[
	Animates UIGradient children on brainrot header billboards (rainbow scroll,
	godly/secret/high-tier shimmer). Static rarities are left unchanged.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local BrainrotGradientAnimator = {}

type AnimSpec = {
	rotateSpeed: number?,
	scrollSpeed: number?,
}

local ANIMATED_BY_NAME: { [string]: AnimSpec } = {
	Rainbow = { rotateSpeed = 48, scrollSpeed = 0.9 },
	Galaxy = { rotateSpeed = 28, scrollSpeed = 0.55 },
	GODLY = { rotateSpeed = 36, scrollSpeed = 0.65 },
	BrainrotGod = { rotateSpeed = 36, scrollSpeed = 0.65 },
	SECRET = { rotateSpeed = 24, scrollSpeed = 0.45 },
	Secret = { rotateSpeed = 24, scrollSpeed = 0.45 },
	LEGENDARY = { rotateSpeed = 20, scrollSpeed = 0.4 },
	MYTHICAL = { rotateSpeed = 26, scrollSpeed = 0.5 },
	MYTHIC = { rotateSpeed = 26, scrollSpeed = 0.5 },
	["90-100"] = { rotateSpeed = 32, scrollSpeed = 0.55 },
	["70-89"] = { rotateSpeed = 22, scrollSpeed = 0.4 },
}

local tracked: { [UIGradient]: AnimSpec } = {}
local heartbeatConn: RBXScriptConnection? = nil
local phaseSeed = math.random() * 1000
local animAccum = 0.0

local function specForGradient(gradient: UIGradient): AnimSpec?
	return ANIMATED_BY_NAME[gradient.Name]
end

local function ensureHeartbeat()
	if heartbeatConn then
		return
	end
	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		if not next(tracked) then
			if heartbeatConn then
				heartbeatConn:Disconnect()
				heartbeatConn = nil
			end
			return
		end
		animAccum += dt
		if animAccum < 0.08 then
			return
		end
		animAccum = 0

		local now = os.clock() + phaseSeed
		for gradient, spec in pairs(tracked) do
			if not gradient.Parent or not gradient.Enabled then
				tracked[gradient] = nil
				continue
			end
			if spec.rotateSpeed then
				gradient.Rotation = (now * spec.rotateSpeed) % 360
			end
			if spec.scrollSpeed then
				-- Soft ping-pong offset (no hard % wrap) — wrap made rainbow text snap/flicker.
				local wave = math.sin(now * spec.scrollSpeed)
				gradient.Offset = Vector2.new(wave * 0.42, 0)
			end
		end
	end)
end

function BrainrotGradientAnimator.register(root: Instance)
	if UserInputService.TouchEnabled then
		return
	end
	for _, desc in root:GetDescendants() do
		if desc:IsA("UIGradient") and desc.Enabled then
			local spec = specForGradient(desc)
			if spec then
				tracked[desc] = spec
			end
		end
	end
	ensureHeartbeat()
end

function BrainrotGradientAnimator.unregister(root: Instance)
	for _, desc in root:GetDescendants() do
		if desc:IsA("UIGradient") then
			tracked[desc] = nil
		end
	end
end

return BrainrotGradientAnimator
