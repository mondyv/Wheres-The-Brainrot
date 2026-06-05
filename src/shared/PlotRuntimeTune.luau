-- [ACTIVE] PlotRuntimeTune
--[[
	One-pass performance tuning for cloned plot bases (Templates.Base).
	Called once when a full plot is spawned — not every visibility refresh.
--]]

local M = {}

function M.tune(plot: Instance)
	for _, d in ipairs(plot:GetDescendants()) do
		if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
			(d :: any).Enabled = false
		elseif d:IsA("BasePart") then
			local p = d :: BasePart
			p.CastShadow = false
			if p.Size.Y < 0.25 and (p.Size.X * p.Size.Z) < 120 then
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
			end
		elseif d:IsA("BillboardGui") then
			local parent = d.Parent
			if parent and parent.Name == "Cash" then
				(d :: BillboardGui).Enabled = false
			end
		elseif d:IsA("SurfaceGui") then
			local x: Instance? = d.Parent
			while x and x ~= plot do
				if x.Name == "Cash" then
					(d :: SurfaceGui).Enabled = false
					break
				end
				x = x.Parent
			end
		elseif d:IsA("ProximityPrompt") then
			local x: Instance? = d.Parent
			local underStands = false
			while x and x ~= plot do
				if x.Name == "Stands" or x.Name == "stands" then
					underStands = true
					break
				end
				x = x.Parent
			end
			if underStands then
				d:Destroy()
			end
		end
	end
end

return M
