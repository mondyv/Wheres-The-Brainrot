-- [ACTIVE] BrainrotGradientAnimator
--[[
	Animates UIGradient children on brainrot header billboards (rainbow scroll,
	godly/secret/high-tier shimmer). Static rarities are left unchanged.
]]

local RunService = game:GetService("RunService")

local BrainrotGradientAnimator = {}

type AnimSpec = {
	rotateSpeed: number?,
	scrollSpeed: number?,
}

local ANIMATED_BY_NAME: { [string]: AnimSpec } = {
	Rainbow = { rotateSpeed = 110, scrollSpeed = 0.55 },
	Galaxy = { rotateSpeed = 42, scrollSpeed = 0.28 },
	GODLY = { rotateSpeed = 52, scrollSpeed = 0.32 },
	BrainrotGod = { rotateSpeed = 52, scrollSpeed = 0.32 },
	SECRET = { rotateSpeed = 36, scrollSpeed = 0.22 },
	Secret = { rotateSpeed = 36, scrollSpeed = 0.22 },
	LEGENDARY = { rotateSpeed = 28, scrollSpeed = 0.18 },
	MYTHICAL = { rotateSpeed = 34, scrollSpeed = 0.24 },
	MYTHIC = { rotateSpeed = 34, scrollSpeed = 0.24 },
	["90-100"] = { rotateSpeed = 46, scrollSpeed = 0.26 },
	["70-89"] = { rotateSpeed = 32, scrollSpeed = 0.18 },
}

local tracked: { [UIGradient]: AnimSpec } = {}
local heartbeatConn: RBXScriptConnection? = nil
local phaseSeed = math.random() * 1000

local function specForGradient(gradient: UIGradient): AnimSpec?
	return ANIMATED_BY_NAME[gradient.Name]
end

local function ensureHeartbeat()
	if heartbeatConn then
		return
	end
	heartbeatConn = RunService.Heartbeat:Connect(function()
		if not next(tracked) then
			if heartbeatConn then
				heartbeatConn:Disconnect()
				heartbeatConn = nil
			end
			return
		end

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
				gradient.Offset = Vector2.new((now * spec.scrollSpeed) % 1, 0)
			end
		end
	end)
end

function BrainrotGradientAnimator.register(root: Instance)
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
