-- [ACTIVE] BrainrotHeaderController
--[[
	Client-side BrainrotHeader billboards.
	Server fires BrainrotRemotes.HeaderRefresh with the brainrot model after placement/harvest.
--]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local BrainrotGradientAnimator = require(script.Parent.BrainrotGradientAnimator)

local HEADER_NAME = "BrainrotInfoBillboard"
local HEADER_MAX_DISTANCE = 90
local HEADER_TAG = "BrainrotHeaderTarget"
local ACTIVE_ATTR = "BrainrotHeaderActive"
local STAND_DISPLAY_ATTR = "BrainrotStandDisplay"
local DEFAULT_BB_SIZE = UDim2.fromOffset(280, 130)

local templateCache: BillboardGui? = nil
local headersByModel: { [Model]: BillboardGui } = {}
local watchedModels: { [Model]: boolean } = {}
local watchConns: { [Model]: { RBXScriptConnection } } = {}

local function disconnectWatchConns(model: Model)
	local conns = watchConns[model]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		watchConns[model] = nil
	end
end

local function formatCash(n: number): string
	if n >= 1e15 then
		return string.format("$%.2fQa", n / 1e15)
	elseif n >= 1e12 then
		return string.format("$%.2fT", n / 1e12)
	elseif n >= 1e9 then
		return string.format("$%.2fB", n / 1e9)
	elseif n >= 1e6 then
		return string.format("$%.2fM", n / 1e6)
	elseif n >= 1e3 then
		return string.format("$%.2fK", n / 1e3)
	end
	return string.format("$%d", math.floor(n + 0.5))
end

local function formatRate(n: number): string
	return formatCash(n) .. "/s"
end

local function buildFallbackTemplate(): BillboardGui
	local bb = Instance.new("BillboardGui")
	bb.Name = "BillboardGui"
	bb.Size = DEFAULT_BB_SIZE
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.ResetOnSpawn = false

	local info = Instance.new("Frame")
	info.Name = "Info"
	info.BackgroundTransparency = 1
	info.Size = UDim2.fromScale(1, 1)
	info.Parent = bb

	local function makeLabel(name: string, y: number, size: number): TextLabel
		local tl = Instance.new("TextLabel")
		tl.Name = name
		tl.BackgroundTransparency = 1
		tl.Size = UDim2.new(1, 0, 0, size)
		tl.Position = UDim2.new(0, 0, 0, y)
		tl.Font = Enum.Font.GothamBold
		tl.TextSize = size - 2
		tl.TextColor3 = Color3.new(1, 1, 1)
		tl.TextStrokeTransparency = 0.4
		tl.Text = ""
		tl.Parent = info
		return tl
	end

	makeLabel("Name", 0, 28)
	makeLabel("Rarity", 28, 22)
	makeLabel("Type", 50, 20)
	makeLabel("Level", 70, 20)
	makeLabel("Rate", 90, 22)
	return bb
end

local function getTemplate(): BillboardGui?
	if templateCache and templateCache.Parent then
		return templateCache
	end
	local templates = ReplicatedStorage:FindFirstChild("Templates")
	if not templates then
		templates = ReplicatedStorage:WaitForChild("Templates", 30)
	end
	if templates then
		local header = templates:FindFirstChild("BrainrotHeader") or templates:WaitForChild("BrainrotHeader", 15)
		if header then
			local direct = header:FindFirstChild("BillboardGui")
			if direct and direct:IsA("BillboardGui") then
				templateCache = direct
				return direct
			end
			local any = header:FindFirstChildWhichIsA("BillboardGui", true)
			if any and any:IsA("BillboardGui") then
				templateCache = any
				return any
			end
		end
	end

	warn("[BrainrotHeaderController] BrainrotHeader BillboardGui missing — using fallback template")
	local fallbackFolder = ReplicatedStorage:FindFirstChild("Templates")
	if not fallbackFolder then
		fallbackFolder = Instance.new("Folder")
		fallbackFolder.Name = "Templates"
		fallbackFolder.Parent = ReplicatedStorage
	end
	local headerFolder = fallbackFolder:FindFirstChild("BrainrotHeader")
	if not headerFolder then
		headerFolder = Instance.new("Folder")
		headerFolder.Name = "BrainrotHeader"
		headerFolder.Parent = fallbackFolder
	end
	local existing = headerFolder:FindFirstChild("BillboardGui")
	if existing and existing:IsA("BillboardGui") then
		templateCache = existing
		return existing
	end
	local built = buildFallbackTemplate()
	built.Parent = headerFolder
	templateCache = built
	return built
end

local function pickPrimaryPart(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

-- Prefer a true "over the head" anchor when rigs use standard names; otherwise PrimaryPart / any part.
local function pickBillboardAdornee(model: Model): BasePart?
	local head = model:FindFirstChild("Head", true)
	if head and head:IsA("BasePart") then
		return head
	end
	local upper = model:FindFirstChild("UpperTorso", true)
	if upper and upper:IsA("BasePart") then
		return upper
	end
	return pickPrimaryPart(model)
end

local function applyToInfoFrame(infoFrame: Instance, data: {
	name: string,
	rarity: string,
	rarityDisplay: string,
	mutation: string,
	mutationDisplay: string,
	level: number,
	incomePerSecond: number,
})
	BrainrotHeaderStyle.applyInfoFrame(infoFrame, {
		name = data.name,
		rarity = data.rarity,
		mutation = data.mutation,
		level = data.level,
		rateText = formatRate(data.incomePerSecond),
	})
end

local function readHeaderData(model: Model): any?
	local isStand = model:GetAttribute(STAND_DISPLAY_ATTR) == true
	local active = model:GetAttribute(ACTIVE_ATTR) == true
	local tagged = CollectionService:HasTag(model, HEADER_TAG)
	if not active and not tagged and not isStand then
		return nil
	end

	local name = model:GetAttribute("BrainrotHeaderName") or model:GetAttribute("BrainrotName")
	if typeof(name) ~= "string" or name == "" then
		return nil
	end

	local rarity = model:GetAttribute("BrainrotHeaderRarity") or model:GetAttribute("BrainrotRarity")
	local mutation = model:GetAttribute("BrainrotHeaderMutation") or model:GetAttribute("BrainrotMutation")
	local level = model:GetAttribute("BrainrotHeaderLevel") or model:GetAttribute("BrainrotLevel")
	local income = model:GetAttribute("BrainrotHeaderIncome") or model:GetAttribute("BrainrotBaseIncome")

	return {
		name = name,
		rarity = if typeof(rarity) == "string" then rarity else "common",
		rarityDisplay = if typeof(model:GetAttribute("BrainrotHeaderRarityDisplay")) == "string"
			then model:GetAttribute("BrainrotHeaderRarityDisplay")
			else string.upper(tostring(rarity)),
		mutation = if typeof(mutation) == "string" then mutation else "normal",
		mutationDisplay = if typeof(model:GetAttribute("BrainrotHeaderMutationDisplay")) == "string"
			then model:GetAttribute("BrainrotHeaderMutationDisplay")
			else tostring(mutation),
		level = if typeof(level) == "number" then math.max(1, math.floor(level)) else 1,
		incomePerSecond = if typeof(income) == "number" then income else 0,
		alwaysOnTop = true,
	}
end

local function removeHeader(model: Model)
	local existing = headersByModel[model]
	if existing then
		BrainrotGradientAnimator.unregister(existing)
		existing:Destroy()
		headersByModel[model] = nil
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BillboardGui") and d.Name == HEADER_NAME then
			d:Destroy()
		end
	end
end

local function syncHeader(model: Model): boolean
	if not model.Parent then
		removeHeader(model)
		return false
	end

	local data = readHeaderData(model)
	if not data then
		removeHeader(model)
		return false
	end

	local adornee = pickBillboardAdornee(model)
	if not adornee then
		return false
	end

	local template = getTemplate()
	if not template then
		return false
	end

	removeHeader(model)

	local bb = template:Clone() :: BillboardGui
	bb.Name = HEADER_NAME
	bb.Enabled = true
	bb.ResetOnSpawn = false
	bb.AlwaysOnTop = true
	bb.Active = false
	bb.LightInfluence = 0
	bb.MaxDistance = HEADER_MAX_DISTANCE
	bb.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	if template.Size.Y.Offset > 4 then
		bb.Size = template.Size
	else
		bb.Size = DEFAULT_BB_SIZE
	end
	if UserInputService.TouchEnabled then
		local w = if bb.Size.X.Offset > 4 then bb.Size.X.Offset else DEFAULT_BB_SIZE.X.Offset
		local h = if bb.Size.Y.Offset > 4 then bb.Size.Y.Offset else DEFAULT_BB_SIZE.Y.Offset
		bb.Size = UDim2.fromOffset(math.floor(w * 0.62), math.floor(h * 0.62))
	end

	-- ExtentsOffset stays on the adornee top as the model scales (raw Size.Y StudsOffset flies up).
	pcall(function()
		bb.ExtentsOffset = Vector3.new(0, 1, 0)
	end)
	bb.StudsOffset = Vector3.new(0, 0.45, 0)

	local infoFrame = bb:FindFirstChild("Info", true)
	if infoFrame and infoFrame:IsA("GuiObject") then
		applyToInfoFrame(infoFrame, data)
		BrainrotGradientAnimator.register(bb)
	end

	-- Parent to Workspace + Adornee (same pattern as SwingSystem): parenting the gui under an
	-- anchored stand sub-assembly can prevent the billboard from rendering for some clients.
	bb.Adornee = adornee
	bb.Parent = Workspace
	headersByModel[model] = bb
	return true
end

local HEADER_ATTRS = {
	ACTIVE_ATTR,
	STAND_DISPLAY_ATTR,
	"BrainrotHeaderName",
	"BrainrotName",
	"BrainrotHeaderRarity",
	"BrainrotRarity",
	"BrainrotHeaderMutation",
	"BrainrotMutation",
	"BrainrotHeaderLevel",
	"BrainrotLevel",
	"BrainrotHeaderIncome",
	"BrainrotBaseIncome",
	"BrainrotHeaderRarityDisplay",
	"BrainrotHeaderMutationDisplay",
}

local function watchModel(model: Model)
	if watchedModels[model] then
		syncHeader(model)
		return
	end
	watchedModels[model] = true
	local conns: { RBXScriptConnection } = {}
	watchConns[model] = conns

	for _, attrName in HEADER_ATTRS do
		table.insert(
			conns,
			model:GetAttributeChangedSignal(attrName):Connect(function()
				syncHeader(model)
			end)
		)
	end

	table.insert(
		conns,
		model.AncestryChanged:Connect(function(_, parent)
			if not parent then
				removeHeader(model)
				watchedModels[model] = nil
				disconnectWatchConns(model)
			end
		end)
	)

	-- Retry while attributes / template stream in.
	task.spawn(function()
		for _ = 1, 24 do
			if not model.Parent then
				break
			end
			if syncHeader(model) then
				break
			end
			task.wait(0.2)
		end
	end)
end

local function onHeaderTarget(inst: Instance)
	if inst:IsA("Model") then
		watchModel(inst)
	end
end

local function hookStandDisplayModel(model: Model)
	if not model:IsA("Model") then
		return
	end
	model:GetAttributeChangedSignal(STAND_DISPLAY_ATTR):Connect(function()
		if model:GetAttribute(STAND_DISPLAY_ATTR) == true then
			watchModel(model)
		else
			removeHeader(model)
		end
	end)
	if model:GetAttribute(STAND_DISPLAY_ATTR) == true then
		watchModel(model)
	end
end

local function clearStandHeaders(stand: Model)
	for model, bb in headersByModel do
		local adornee = bb.Adornee
		if model:IsDescendantOf(stand) or (adornee and adornee:IsDescendantOf(stand)) then
			removeHeader(model)
			watchedModels[model] = nil
			disconnectWatchConns(model)
		end
	end
	for _, child in Workspace:GetChildren() do
		if child:IsA("BillboardGui") and child.Name == HEADER_NAME then
			local adornee = child.Adornee
			if adornee and adornee:IsDescendantOf(stand) then
				child:Destroy()
			end
		end
	end
end

local function hookStandHeaderCleanup(stand: Model)
	stand:GetAttributeChangedSignal("BrainrotName"):Connect(function()
		if stand:GetAttribute("BrainrotName") == nil then
			clearStandHeaders(stand)
		end
	end)
end

local BrainrotHeaderController = {}

local function hookHeaderRefreshRemote()
	local remotes = ReplicatedStorage:WaitForChild("BrainrotRemotes", 120)
	if not remotes then
		return
	end
	local refresh = remotes:WaitForChild("HeaderRefresh", 60)
	if refresh and refresh:IsA("RemoteEvent") then
		(refresh :: RemoteEvent).OnClientEvent:Connect(function(model: Instance)
			if not (typeof(model) == "Instance" and model:IsA("Model")) then
				return
			end
			-- Instance can arrive before parenting / streaming finishes; retry briefly.
			task.spawn(function()
				local m = model :: Model
				for _ = 1, 24 do
					if m.Parent then
						watchModel(m)
						return
					end
					task.wait(0.05)
				end
			end)
		end)
	end
end

function BrainrotHeaderController.init()
	task.spawn(function()
		if not getTemplate() then
			warn("[BrainrotHeaderController] Failed to create header template")
		end
	end)

	task.spawn(hookHeaderRefreshRemote)

	local function clampHeaderDistances()
		for _, bb in headersByModel do
			if bb.Parent then
				bb.MaxDistance = HEADER_MAX_DISTANCE
			end
		end
		-- Never Workspace:GetDescendants() — that sync-builds the whole map tree and times out Studio.
		local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
		if pg then
			local scanned = 0
			for _, d in pg:GetDescendants() do
				scanned += 1
				if scanned % 400 == 0 then
					task.wait()
				end
				if d:IsA("BillboardGui") and d.Name == HEADER_NAME then
					d.MaxDistance = HEADER_MAX_DISTANCE
				end
			end
		end
	end

	CollectionService:GetInstanceAddedSignal(HEADER_TAG):Connect(onHeaderTarget)
	CollectionService:GetInstanceRemovedSignal(HEADER_TAG):Connect(function(inst)
		if inst:IsA("Model") then
			removeHeader(inst)
			watchedModels[inst] = nil
		end
	end)

	for _, inst in CollectionService:GetTagged(HEADER_TAG) do
		onHeaderTarget(inst)
	end

	task.defer(clampHeaderDistances)
	task.spawn(function()
		task.wait(3)
		clampHeaderDistances()
	end)

	for _, inst in CollectionService:GetTagged("BrainrotStand") do
		if inst:IsA("Model") then
			hookStandHeaderCleanup(inst :: Model)
			task.defer(function()
				for _, desc in ipairs(inst:GetDescendants()) do
					if desc:IsA("Model") and desc:GetAttribute(STAND_DISPLAY_ATTR) == true then
						hookStandDisplayModel(desc :: Model)
					end
				end
			end)
		end
	end

	CollectionService:GetInstanceAddedSignal("BrainrotStand"):Connect(function(inst)
		if inst:IsA("Model") then
			hookStandHeaderCleanup(inst :: Model)
		end
	end)

	-- Streaming / late stand rebuilds: rescan a few times after join.
	task.spawn(function()
		for _ = 1, 8 do
			task.wait(1.25)
			for _, inst in CollectionService:GetTagged(HEADER_TAG) do
				onHeaderTarget(inst)
			end
			for _, inst in CollectionService:GetTagged("BrainrotStand") do
				if inst:IsA("Model") then
					for _, desc in ipairs(inst:GetDescendants()) do
						if desc:IsA("Model") and desc:GetAttribute(STAND_DISPLAY_ATTR) == true then
							hookStandDisplayModel(desc :: Model)
						end
					end
				end
			end
		end
	end)
end

return BrainrotHeaderController
