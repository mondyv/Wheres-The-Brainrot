-- [ACTIVE] GearRainbowFX
-- Smooth HSV rainbow cycle for Rainbow Dumbbell (tools + viewport clones).
local RunService = game:GetService("RunService")

local M = {}

type TrackState = {
	parts: { BasePart },
	emitters: { ParticleEmitter },
	beams: { Beam },
	trails: { Trail },
	gradients: { UIGradient },
	hue: number,
}

local tracked: { [Instance]: TrackState } = {}
local conn: RBXScriptConnection? = nil

local function ensureLoop()
	if conn then
		return
	end
	conn = RunService.RenderStepped:Connect(function(dt)
		local any = false
		for root, state in tracked do
			if not root.Parent then
				tracked[root] = nil
				continue
			end
			any = true
			state.hue = (state.hue + dt * 0.4) % 1
			local color = Color3.fromHSV(state.hue, 0.9, 1)
			local seq = ColorSequence.new(color)
			for _, p in state.parts do
				if p.Parent then
					p.Color = color
				end
			end
			for _, em in state.emitters do
				if em.Parent then
					em.Color = seq
					em.Enabled = true
				end
			end
			for _, beam in state.beams do
				if beam.Parent then
					beam.Color = seq
					beam.Enabled = true
				end
			end
			for _, trail in state.trails do
				if trail.Parent then
					trail.Color = seq
					trail.Enabled = true
				end
			end
			local offset = Vector2.new((state.hue * 2) % 1 - 0.5, 0)
			for _, grad in state.gradients do
				if grad.Parent then
					grad.Offset = offset
				end
			end
		end
		if not any and conn then
			conn:Disconnect()
			conn = nil
		end
	end)
end

function M.attach(root: Instance)
	if tracked[root] then
		return
	end
	local parts: { BasePart } = {}
	local emitters: { ParticleEmitter } = {}
	local beams: { Beam } = {}
	local trails: { Trail } = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
	end
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		elseif d:IsA("ParticleEmitter") then
			table.insert(emitters, d)
			d.Enabled = true
		elseif d:IsA("Beam") then
			table.insert(beams, d)
			d.Enabled = true
		elseif d:IsA("Trail") then
			table.insert(trails, d)
			d.Enabled = true
		end
	end
	if #parts == 0 then
		return
	end
	tracked[root] = {
		parts = parts,
		emitters = emitters,
		beams = beams,
		trails = trails,
		gradients = {},
		hue = 0,
	}
	ensureLoop()
end

local function collectEventGradients(root: Instance): { UIGradient }
	local grads: { UIGradient } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("UIGradient") and d:GetAttribute("EventGearRainbow") == true then
			table.insert(grads, d)
		end
	end
	return grads
end

-- Scroll rainbow on EVENT GEAR labels only — never recolor the mesh.
function M.attachEventLabel(root: Instance)
	local grads = collectEventGradients(root)
	if #grads == 0 then
		return
	end
	local existing = tracked[root]
	if existing then
		existing.gradients = grads
		ensureLoop()
		return
	end
	tracked[root] = {
		parts = {},
		emitters = {},
		beams = {},
		trails = {},
		gradients = grads,
		hue = 0,
	}
	ensureLoop()
end

function M.detach(root: Instance)
	tracked[root] = nil
end

return M
