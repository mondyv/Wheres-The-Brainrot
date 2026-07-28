-- [ACTIVE] AutoCollectController
--[[
	Client presentation for the plot Autocollect gamepass pad.
	• Hides Price (+ Discount) on the world billboard once the pass is owned.
	• Mirrors accumulated cash from server attributes on the autocollect pad.
	• Plays collect VFX + sound when all stand cash is claimed at once.
--]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AutoCollectConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AutoCollectConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local GameSoundEffects = require(script.Parent.GameSoundEffects)

local player = Players.LocalPlayer

local STAND_TAG = "BrainrotStand"
local STAND_ACCUMULATED_ATTR = "StandAccumulatedCash"

local M = {}

type PadView = {
	thing: Instance,
	totalLabel: (TextLabel | TextButton)?,
	priceLabel: GuiObject?,
	discountLabel: GuiObject?,
	accumulatedConn: RBXScriptConnection?,
}

local padViews: { [Instance]: PadView } = {}
local wiredThings: { [Instance]: boolean } = {}
local ownershipConns: { RBXScriptConnection } = {}
local plotCashRefreshScheduled = false
local watchedPlot: Instance? = nil
local plotWatchConns: { RBXScriptConnection } = {}
-- Cached set of this plot's stand models so the per-second cash refresh never has to
-- GetDescendants() the whole plot (that scan was running several times a second).
local trackedStands: { [Model]: boolean } = {}

local wirePadView: (Instance) -> ()

local CASH_FLOAT_TEXT_SIZE = 28
local FLOAT_STROKE_SCALE = 1
local CASH_FLOAT_START_Y_DROP = 0.35

local function playerOwnsAutoCollect(): boolean
	if player:GetAttribute(StoreConfig.ATTR.AUTOCOLLECT_OWNED) == true then
		return true
	end
	if player:GetAttribute(StoreConfig.ATTR.GIFTED_AUTOCOLLECT) == true then
		return true
	end
	return player:GetAttribute(StoreConfig.ATTR.PURCHASED_AUTOCOLLECT) == true
end

local function findGamepassInfo(thing: Instance): Instance?
	local btn = thing:FindFirstChild("Button")
	if not btn then
		return nil
	end
	local gpText = btn:FindFirstChild("GamepassText")
	if not gpText then
		return nil
	end
	local bb = gpText:FindFirstChild("BillboardGui")
	if not bb then
		return nil
	end
	return bb:FindFirstChild("Info")
end

local function findTotalLabel(thing: Instance): (TextLabel | TextButton)?
	local btn = thing:FindFirstChild("Button")
	if not btn then
		return nil
	end
	local bp = btn:FindFirstChild("ButtonPart")
	if bp then
		local total = bp:FindFirstChild("Total", true)
		if total and (total:IsA("TextLabel") or total:IsA("TextButton")) then
			return total
		end
	end
	local cash = btn:FindFirstChild("Cash")
	if cash then
		local total = cash:FindFirstChild("Total", true)
		if total and (total:IsA("TextLabel") or total:IsA("TextButton")) then
			return total
		end
	end
	return nil
end

local function applyCashPadText(view: PadView, amount: number)
	local label = view.totalLabel
	if not label or not label.Parent then
		label = findTotalLabel(view.thing)
		view.totalLabel = label
	end
	if not label then
		return
	end
	local text = BrainrotEconomy.formatCashAccumulated(amount)
	if label:IsA("TextLabel") then
		label.AutoLocalize = false
		label.TextTruncate = Enum.TextTruncate.None
		label.Text = text
	elseif label:IsA("TextButton") then
		label.AutoLocalize = false
		label.TextTruncate = Enum.TextTruncate.None
		label.Text = text
	end
end

local function syncGamepassBillboard(view: PadView)
	local owned = playerOwnsAutoCollect()
	if view.priceLabel and view.priceLabel.Parent then
		view.priceLabel.Visible = not owned
		if not owned and view.priceLabel:IsA("TextLabel") then
			view.priceLabel.Text = tostring(AutoCollectConfig.GAMEPASS_PRICE_ROBUX) .. " Robux"
		end
	end
	if view.discountLabel and view.discountLabel.Parent then
		view.discountLabel.Visible = not owned
	end
end

local function syncAllGamepassBillboards()
	for _, view in pairs(padViews) do
		syncGamepassBillboard(view)
	end
end

local function syncCashFromAttribute(view: PadView)
	local amount = view.thing:GetAttribute(AutoCollectConfig.ACCUMULATED_ATTR)
	if typeof(amount) ~= "number" then
		return
	end
	applyCashPadText(view, amount)
end

local function pulsePart(part: BasePart)
	local originalColor = part.Color
	local originalSize = part.Size
	part.Color = originalColor:Lerp(Color3.new(1, 1, 1), 0.35)
	part.Size = originalSize * 1.06
	TweenService:Create(part, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Color = originalColor,
		Size = originalSize,
	}):Play()
end

local function findMoneyVFXTemplate(): Instance?
	local vfxFolder = ReplicatedStorage:FindFirstChild("VFX")
	local plot = vfxFolder and vfxFolder:FindFirstChild("PlotVFX")
	return plot and plot:FindFirstChild("Money")
end

local function playMoneyBurst(anchor: BasePart, amount: number)
	local template = findMoneyVFXTemplate()
	local att = anchor:FindFirstChild("AutoCollectMoneyVFX")
	if not att or not att:IsA("Attachment") then
		if att then
			att:Destroy()
		end
		att = Instance.new("Attachment")
		att.Name = "AutoCollectMoneyVFX"
		att.Parent = anchor
		att.Position = Vector3.new(0, anchor.Size.Y * 0.22, 0)
		if template then
			if template:IsA("Attachment") then
				for _, c in ipairs(template:GetChildren()) do
					c:Clone().Parent = att
				end
			else
				for _, c in ipairs(template:GetDescendants()) do
					if c:IsA("ParticleEmitter") then
						c:Clone().Parent = att
					end
				end
			end
		end
	end
	local emitCount = math.clamp(4 + math.floor(math.max(amount, 0) / 25000), 3, 8)
	local emitted = 0
	for _, e in ipairs((att :: Attachment):GetDescendants()) do
		if e:IsA("ParticleEmitter") then
			e.Enabled = false
			pcall(function()
				e:Emit(emitCount)
			end)
			emitted += 1
			if emitted >= 3 then
				break
			end
		end
	end
end

local function playCollectFloat(anchor: BasePart, amount: number)
	local styleSource = BrainrotHeaderStyle.getHeaderInfoChild("Rate")
	if not styleSource then
		return
	end
	local part = Instance.new("Part")
	part.Name = "AutoCollectFloatText"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.CFrame = CFrame.new(anchor.Position - Vector3.new(0, CASH_FLOAT_START_Y_DROP, 0))
	part.Parent = Workspace

	local billboard = Instance.new("BillboardGui")
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Size = UDim2.fromOffset(220, 48)
	billboard.StudsOffset = Vector3.new(0, 0.75, 0)
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = billboard
	BrainrotHeaderStyle.prepareFloatTextLabel(label, styleSource, CASH_FLOAT_TEXT_SIZE)
	label.Text = "+" .. BrainrotEconomy.formatCashAccumulated(amount)
	BrainrotHeaderStyle.applyRateGradient(label)
	BrainrotHeaderStyle.copyStrokeFromSource(styleSource, label, FLOAT_STROKE_SCALE)

	local rise = TweenService:Create(part, TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = part.CFrame + Vector3.new(0, 2.4, 0),
	})
	local fade = TweenService:Create(label, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
	})
	rise:Play()
	rise.Completed:Connect(function()
		fade:Play()
		fade.Completed:Connect(function()
			part:Destroy()
		end)
	end)
end

local function playAutoCollectPresentation(thing: Instance, amount: number)
	local btn = thing:FindFirstChild("Button")
	if not btn then
		return
	end
	local buttonPart = btn:FindFirstChild("ButtonPart")
	local cash = btn:FindFirstChild("Cash")
	if buttonPart and buttonPart:IsA("BasePart") then
		pulsePart(buttonPart)
	end
	if cash and cash:IsA("BasePart") then
		pulsePart(cash)
		playMoneyBurst(cash, amount)
		playCollectFloat(cash, amount)
	elseif buttonPart and buttonPart:IsA("BasePart") then
		playMoneyBurst(buttonPart, amount)
		playCollectFloat(buttonPart, amount)
	end
end

local function sumTrackedStandCash(): number
	local total = 0
	for stand in trackedStands do
		if not stand.Parent then
			trackedStands[stand] = nil
			continue
		end
		local acc = stand:GetAttribute(STAND_ACCUMULATED_ATTR)
		if typeof(acc) == "number" then
			total += acc
		end
	end
	return total
end

local function refreshAutocollectPadOnPlot(plot: Instance)
	local story = PlotPaths.firstStoryFolder(plot)
	if not story then
		return
	end
	local thing = story:FindFirstChild(AutoCollectConfig.MODEL_NAME)
	if not thing then
		return
	end
	local view = padViews[thing]
	if not view then
		wirePadView(thing)
		view = padViews[thing]
	end
	if view then
		applyCashPadText(view, sumTrackedStandCash())
	end
end

local function schedulePlotCashRefresh()
	if plotCashRefreshScheduled then
		return
	end
	plotCashRefreshScheduled = true
	task.defer(function()
		plotCashRefreshScheduled = false
		local plot = PlotPaths.findPlotForAssignedSlot(player)
		if plot then
			refreshAutocollectPadOnPlot(plot)
		end
	end)
end

local function clearPlotWatch()
	for _, conn in plotWatchConns do
		conn:Disconnect()
	end
	table.clear(plotWatchConns)
	table.clear(trackedStands)
	watchedPlot = nil
end

local function watchStandCashOnPlot(plot: Instance)
	if watchedPlot == plot then
		return
	end
	clearPlotWatch()
	watchedPlot = plot

	local function hookStandModel(stand: Model)
		if trackedStands[stand] then
			return
		end
		trackedStands[stand] = true
		table.insert(
			plotWatchConns,
			stand:GetAttributeChangedSignal(STAND_ACCUMULATED_ATTR):Connect(schedulePlotCashRefresh)
		)
	end

	for _, stand in CollectionService:GetTagged(STAND_TAG) do
		if stand:IsA("Model") and stand:IsDescendantOf(plot) then
			hookStandModel(stand :: Model)
		end
	end

	table.insert(
		plotWatchConns,
		plot.DescendantAdded:Connect(function(desc)
			if desc:IsA("Model") and CollectionService:HasTag(desc, STAND_TAG) then
				hookStandModel(desc :: Model)
				schedulePlotCashRefresh()
			end
		end)
	)

	table.insert(
		plotWatchConns,
		CollectionService:GetInstanceAddedSignal(STAND_TAG):Connect(function(inst)
			if inst:IsA("Model") and inst:IsDescendantOf(plot) then
				hookStandModel(inst :: Model)
				schedulePlotCashRefresh()
			end
		end)
	)

	table.insert(
		plotWatchConns,
		CollectionService:GetInstanceRemovedSignal(STAND_TAG):Connect(function(inst)
			if trackedStands[inst] then
				trackedStands[inst] = nil
				schedulePlotCashRefresh()
			end
		end)
	)

	schedulePlotCashRefresh()
end

local function refreshAssignedPlotWatch()
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if plot then
		watchStandCashOnPlot(plot)
	else
		clearPlotWatch()
	end
end

wirePadView = function(thing: Instance)
	if wiredThings[thing] then
		return
	end
	wiredThings[thing] = true

	local info = findGamepassInfo(thing)
	local view: PadView = {
		thing = thing,
		totalLabel = findTotalLabel(thing),
		priceLabel = if info then info:FindFirstChild("Price") :: GuiObject? else nil,
		discountLabel = if info then info:FindFirstChild("Discount") :: GuiObject? else nil,
	}
	padViews[thing] = view

	syncGamepassBillboard(view)
	syncCashFromAttribute(view)

	if view.accumulatedConn then
		view.accumulatedConn:Disconnect()
	end
	view.accumulatedConn = thing:GetAttributeChangedSignal(AutoCollectConfig.ACCUMULATED_ATTR):Connect(function()
		syncCashFromAttribute(view)
	end)
end

local function tryWireThing(inst: Instance)
	if inst.Name == AutoCollectConfig.MODEL_NAME and (inst:IsA("Model") or inst:IsA("Folder")) then
		wirePadView(inst)
	end
end

local function hookPlot(plot: Instance)
	tryWireThing(plot)
	for _, desc in ipairs(plot:GetDescendants()) do
		tryWireThing(desc)
	end
	plot.DescendantAdded:Connect(function(desc)
		tryWireThing(desc)
	end)
end

local function hookSpawnFolder(folder: Instance)
	for _, ch in folder:GetChildren() do
		if PlotPaths.isPlotRoot(ch) then
			hookPlot(ch)
		end
	end
	folder.ChildAdded:Connect(function(ch)
		if PlotPaths.isPlotRoot(ch) then
			hookPlot(ch)
		end
	end)
	folder.DescendantAdded:Connect(function(desc)
		tryWireThing(desc)
	end)
end

function M.init()
	table.insert(
		ownershipConns,
		player:GetAttributeChangedSignal(StoreConfig.ATTR.AUTOCOLLECT_OWNED):Connect(syncAllGamepassBillboards)
	)
	table.insert(
		ownershipConns,
		player:GetAttributeChangedSignal(StoreConfig.ATTR.GIFTED_AUTOCOLLECT):Connect(syncAllGamepassBillboards)
	)
	table.insert(
		ownershipConns,
		player:GetAttributeChangedSignal(StoreConfig.ATTR.PURCHASED_AUTOCOLLECT):Connect(syncAllGamepassBillboards)
	)
	task.defer(syncAllGamepassBillboards)
	task.defer(refreshAssignedPlotWatch)

	-- Pre-owned Autocollect: ask server to verify + unlock if Roblox already granted it.
	task.spawn(function()
		if playerOwnsAutoCollect() then
			return
		end
		local MarketplaceService = game:GetService("MarketplaceService")
		local ok, owned = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, StoreConfig.GAMEPASS.AUTOCOLLECT)
		end)
		if not ok or owned ~= true then
			return
		end
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 20)
		local claim = remotes and remotes:WaitForChild("ClaimOwnedGamepass", 10)
		if claim and claim:IsA("RemoteEvent") then
			claim:FireServer(StoreConfig.GAMEPASS.AUTOCOLLECT)
		end
	end)

	local remotes = ReplicatedStorage:WaitForChild("StandRemotes", 60)
	if remotes then
		local ev = remotes:WaitForChild("AutoCollectCashCollectedFX", 30)
		if ev and ev:IsA("RemoteEvent") then
			ev.OnClientEvent:Connect(function(thing: any, total: any)
				GameSoundEffects.playCashGrab()
				if typeof(thing) ~= "Instance" then
					return
				end
				local amount = if typeof(total) == "number" then total else 0
				playAutoCollectPresentation(thing, amount)
			end)
		end
	end

	task.spawn(function()
		local folder = PlotPaths.waitForSpawnAndBasesFolder(45)
		if folder then
			hookSpawnFolder(folder)
		end
	end)

	player:GetAttributeChangedSignal("AssignedPlotSlot"):Connect(function()
		task.defer(syncAllGamepassBillboards)
		task.defer(refreshAssignedPlotWatch)
	end)
end

return M
