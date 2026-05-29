--[[
	Billboard "No Brainrots Hiding" above a bush when the server rolls empty (30%).
]]

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local M = {}

local MESSAGE_TEXT = "No Brainrots Hiding"
local OUTLINE_GREEN = Color3.fromRGB(72, 255, 120)
local STAY_SEC = 2.5
local FADE_IN_SEC = 0.2
local FADE_OUT_SEC = 0.35
local LIFT_SCALE = 0.66

local function anchorPartFor(bush: Instance): BasePart?
	if bush:IsA("BasePart") then
		return bush
	end
	if bush:IsA("Model") then
		local m = bush :: Model
		if m.PrimaryPart then
			return m.PrimaryPart
		end
		return m:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function labelWorldPosition(bush: Instance): Vector3?
	if bush:IsA("BasePart") then
		local p = bush :: BasePart
		return p.Position + Vector3.new(0, p.Size.Y * LIFT_SCALE, 0)
	end
	if bush:IsA("Model") then
		local minX, minY, minZ = math.huge, math.huge, math.huge
		local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
		local found = false
		for _, desc in bush:GetDescendants() do
			if desc:IsA("BasePart") then
				found = true
				local cf = desc.CFrame
				local h = desc.Size * 0.5
				for sx = -1, 1, 2 do
					for sy = -1, 1, 2 do
						for sz = -1, 1, 2 do
							local wp = cf:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
							minX = math.min(minX, wp.X)
							minY = math.min(minY, wp.Y)
							minZ = math.min(minZ, wp.Z)
							maxX = math.max(maxX, wp.X)
							maxY = math.max(maxY, wp.Y)
							maxZ = math.max(maxZ, wp.Z)
						end
					end
				end
			end
		end
		if found then
			local center = Vector3.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
			return center + Vector3.new(0, math.max(0.5, maxY - minY) * LIFT_SCALE, 0)
		end
		local ok, cf, size = pcall(function()
			return (bush :: Model):GetBoundingBox()
		end)
		if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
			return cf.Position + Vector3.new(0, size.Y * LIFT_SCALE, 0)
		end
	end
	return nil
end

function M.findBushSCRIPTNearPosition(worldPos: Vector3, maxDist: number): Instance?
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local best: Instance? = nil
	local bestD = math.huge
	for _, desc in map:GetDescendants() do
		if desc.Name ~= "BushSCRIPT" then
			continue
		end
		if not desc:IsA("Model") and not desc:IsA("BasePart") then
			continue
		end
		local anchor = anchorPartFor(desc)
		if not anchor then
			continue
		end
		local d = (anchor.Position - worldPos).Magnitude
		if d <= maxDist and d < bestD then
			bestD = d
			best = desc
		end
	end
	return best
end

function M.show(bush: Instance)
	if not bush.Parent then
		return
	end
	task.spawn(function()
		local anchor = anchorPartFor(bush)
		if not anchor or not anchor.Parent then
			return
		end

		local existing = anchor:FindFirstChild("BushEmptyMessage")
		if existing then
			existing:Destroy()
		end

		local worldLabelPos = labelWorldPosition(bush) or (anchor.Position + Vector3.new(0, 3, 0))
		local studsOffset = anchor.CFrame:PointToObjectSpace(worldLabelPos)

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "BushEmptyMessage"
		billboard.Adornee = anchor
		billboard.AlwaysOnTop = true
		billboard.LightInfluence = 0
		billboard.MaxDistance = 120
		billboard.Size = UDim2.fromOffset(340, 76)
		billboard.StudsOffset = studsOffset
		billboard.Enabled = true
		billboard.ResetOnSpawn = false
		billboard.Parent = anchor

		local frame = Instance.new("Frame")
		frame.Name = "Panel"
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.5)
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.fromRGB(16, 28, 20)
		frame.BackgroundTransparency = 0.15
		frame.BorderSizePixel = 0
		frame.Parent = billboard

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 14)
		corner.Parent = frame

		local frameStroke = Instance.new("UIStroke")
		frameStroke.Color = OUTLINE_GREEN
		frameStroke.Thickness = 3
		frameStroke.Transparency = 0
		frameStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		frameStroke.Parent = frame

		local label = Instance.new("TextLabel")
		label.Name = "Message"
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Size = UDim2.new(1, -20, 1, -12)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.Text = MESSAGE_TEXT
		label.TextColor3 = Color3.fromRGB(240, 255, 245)
		label.TextScaled = true
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.TextStrokeColor3 = OUTLINE_GREEN
		label.TextStrokeTransparency = 0
		label.Parent = frame

		local textStroke = Instance.new("UIStroke")
		textStroke.Color = OUTLINE_GREEN
		textStroke.Thickness = 2
		textStroke.Parent = label

		task.wait(STAY_SEC)

		local fadeOut = TweenInfo.new(FADE_OUT_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(label, fadeOut, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		TweenService:Create(frame, fadeOut, { BackgroundTransparency = 1 }):Play()
		local tStroke = TweenService:Create(frameStroke, fadeOut, { Transparency = 1 })
		local tTextStroke = TweenService:Create(textStroke, fadeOut, { Transparency = 1 })
		tStroke:Play()
		tTextStroke:Play()
		tTextStroke.Completed:Wait()
		if billboard.Parent then
			billboard:Destroy()
		end
	end)
end

return M
