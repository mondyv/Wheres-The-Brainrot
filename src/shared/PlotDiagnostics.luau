--[[
	PlotDiagnostics — temporary verbose logging for plot / stand / perf issues.
	Filter Output with: PlotDiag
--]]

local RunService = game:GetService("RunService")

local M = {}

M.ENABLED = false

function M.log(source: string, message: string)
	if not M.ENABLED then
		return
	end
	print(string.format("[PlotDiag:%s] %s", source, message))
end

function M.warn(source: string, message: string)
	if not M.ENABLED then
		return
	end
	warn(string.format("[PlotDiag:%s] %s", source, message))
end

function M.isServer(): boolean
	return RunService:IsServer()
end

function M.partSummary(part: BasePart): string
	return string.format(
		"%s T=%.2f size=%s",
		part:GetFullName(),
		part.Transparency,
		tostring(part.Size)
	)
end

function M.modelSummary(model: Model): string
	local parts = 0
	local visible = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			parts += 1
			if d.Transparency < 0.95 then
				visible += 1
			end
		end
	end
	return string.format(
		"%s parent=%s parts=%d visible=%d",
		model:GetFullName(),
		tostring(model.Parent and model.Parent:GetFullName() or "nil"),
		parts,
		visible
	)
end

return M
