-- [ACTIVE] BaseReturnGuideController
--[[
	After accepting a brainrot onto your head, pulse-highlight your plot so new players
	know where to go. Only for the first N career accepts (PlayerDataSchema.BASE_RETURN_GUIDE_ACCEPTS).
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))

local BushFloatingClaimController = require(script.Parent:WaitForChild("BushFloatingClaimController"))

local player = Players.LocalPlayer

local GUIDE_SEC = 14
local NEAR_CLEAR_STUDS = 22
local FILL = Color3.fromRGB(255, 220, 60)
local OUTLINE = Color3.fromRGB(255, 245, 120)

local BaseReturnGuideController = {}

local hostFolder: Folder? = nil
local proxyModel: Model? = nil
local highlight: Highlight? = nil
local pulseConn: RBXScriptConnection? = nil
local nearConn: RBXScriptConnection? = nil
local clearToken = 0
local wired = false

local function getHost(): Folder
	if hostFolder and hostFolder.Parent then
		return hostFolder
	end
	local existing = Workspace:FindFirstChild("BaseReturnGuideProxies")
	if existing and existing:IsA("Folder") then
		hostFolder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "BaseReturnGuideProxies"
	folder.Parent = Workspace
	hostFolder = folder
	return folder
end

local function clearGuide()
	clearToken += 1
	if pulseConn then
		pulseConn:Disconnect()
		pulseConn = nil
	end
	if nearConn then
		nearConn:Disconnect()
		nearConn = nil
	end
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	if proxyModel then
		proxyModel:Destroy()
		proxyModel = nil
	end
end

local function acceptCount(): number
	local n = player:GetAttribute(PlayerDataSchema.BRAINROT_ACCEPT_COUNT_ATTR)
	if typeof(n) == "number" then
		return math.max(0, math.floor(n))
	end
	return 0
end

local function stillEligible(): boolean
	return acceptCount() < PlayerDataSchema.BASE_RETURN_GUIDE_ACCEPTS
end

local function showGuide()
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot then
		return
	end
	clearGuide()
	local token = clearToken

	local proxy = PlotSpawnUtil.buildInvisibleOutlineProxy(plot, getHost())
	if not proxy then
		return
	end
	proxy.Name = "BaseReturnGuideProxy"
	proxyModel = proxy

	local hl = Instance.new("Highlight")
	hl.Name = "BaseReturnGuideHighlight"
	hl.FillColor = FILL
	hl.OutlineColor = OUTLINE
	hl.FillTransparency = 0.55
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Adornee = proxy
	hl.Parent = getHost()
	highlight = hl

	local center = Vector3.zero
	if plot:IsA("Model") then
		center = plot:GetPivot().Position
	elseif plot:IsA("BasePart") then
		center = plot.Position
	end
	local reach = NEAR_CLEAR_STUDS
	local minV, maxV = PlotSpawnUtil.getPlotOutlineBounds(plot)
	if minV and maxV then
		center = (minV + maxV) * 0.5
		reach = math.max(NEAR_CLEAR_STUDS, math.max(maxV.X - minV.X, maxV.Z - minV.Z) * 0.28)
	end

	pulseConn = RunService.RenderStepped:Connect(function()
		if token ~= clearToken or not hl.Parent then
			return
		end
		local wave = (math.sin(os.clock() * 5.2) + 1) * 0.5
		hl.FillTransparency = 0.42 + wave * 0.28
		hl.OutlineTransparency = wave * 0.15
	end)

	nearConn = RunService.Heartbeat:Connect(function()
		if token ~= clearToken then
			return
		end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not (hrp and hrp:IsA("BasePart")) then
			return
		end
		local flat = Vector3.new(hrp.Position.X - center.X, 0, hrp.Position.Z - center.Z)
		if flat.Magnitude <= reach then
			clearGuide()
		end
	end)

	task.delay(GUIDE_SEC, function()
		if token == clearToken then
			clearGuide()
		end
	end)
	Debris:AddItem(proxy, GUIDE_SEC + 1)
end

local function tryShowFromAccept()
	-- Attribute may still be pre-increment on the client frame of accept.
	if not stillEligible() then
		return
	end
	showGuide()
end

function BaseReturnGuideController.init()
	if wired then
		return
	end
	wired = true

	BushFloatingClaimController.registerAcceptHook(function(_model: Model)
		tryShowFromAccept()
	end)

	player:GetAttributeChangedSignal(PlayerDataSchema.BRAINROT_ACCEPT_COUNT_ATTR):Connect(function()
		local n = acceptCount()
		-- Show when server confirms an accept within the first N.
		if n < 1 or n > PlayerDataSchema.BASE_RETURN_GUIDE_ACCEPTS then
			return
		end
		local carry = player:GetAttribute("BrainrotCarryCount")
		if typeof(carry) ~= "number" or carry < 1 then
			return
		end
		showGuide()
	end)

	Players.PlayerRemoving:Connect(function(leaving)
		if leaving == player then
			clearGuide()
		end
	end)
end

return BaseReturnGuideController
