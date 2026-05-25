--[[
	Index UI — mutation tabs, catalog grid, golden quest, unlock toast.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local HUDController = require(script.Parent.HUDController)
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local IndexConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("IndexConfig"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local OPEN_PANEL = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OPEN_NOTIF = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_NOTIF = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TILT_HOVER = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TILT_CLICK = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TILT_RESET = TweenInfo.new(0.2, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local QUEST_BAR_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ROW_HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local LOCKED_NAME_COLOR = Color3.fromRGB(0, 0, 0)

local indexFrame: Frame? = nil
local headerTitle: TextLabel? = nil
local container: ScrollingFrame? = nil
local rowTemplate: Frame? = nil
local questsFrame: Frame? = nil
local progressBar: Frame? = nil
local progressAmount: TextLabel? = nil
local indexNotif: GuiObject? = nil
local indexNotifLabel: TextLabel? = nil
local tooltipLabel: TextLabel? = nil
local tooltipGui: ScreenGui? = nil

local selectedMutation = "normal"
local catalogRows: { Frame } = {}
local getStateRF: RemoteFunction? = nil
local unlockedRE: RemoteEvent? = nil
local questBarTween: Tween? = nil
local rowHoverConns: { RBXScriptConnection } = {}
local selectMutation: (mutationId: string) -> ()

local function getOrAddUIScale(obj: GuiObject): UIScale
	local s = obj:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Scale = 1
	s.Parent = obj
	return s
end

local function waitMain(): ScreenGui?
	if not player.Character then
		player.CharacterAdded:Wait()
	end
	return playerGui:WaitForChild("Main", 120) :: ScreenGui?
end

local function findLabel(root: Instance, names: { string }): TextLabel?
	for _, n in names do
		local inst = root:FindFirstChild(n, true)
		if inst and inst:IsA("TextLabel") then
			return inst
		end
	end
	return nil
end

local function setGradientEnabled(root: Instance, enabled: boolean)
	if root:IsA("UIGradient") then
		root.Enabled = enabled
	end
	for _, d in root:GetDescendants() do
		if d:IsA("UIGradient") then
			d.Enabled = enabled
		end
	end
end

local function applyTabVisual(tabBtn: Instance, selected: boolean)
	local selectedGrad = tabBtn:FindFirstChild("Selected", true)
	local notSelectedGrad = tabBtn:FindFirstChild("NotSelected", true)

	if selectedGrad then
		if selectedGrad:IsA("UIGradient") then
			selectedGrad.Enabled = selected
		elseif selectedGrad:IsA("GuiObject") then
			(selectedGrad :: GuiObject).Visible = selected
			setGradientEnabled(selectedGrad, selected)
		else
			setGradientEnabled(selectedGrad, selected)
		end
	end

	if notSelectedGrad then
		if notSelectedGrad:IsA("UIGradient") then
			notSelectedGrad.Enabled = not selected
		elseif notSelectedGrad:IsA("GuiObject") then
			(notSelectedGrad :: GuiObject).Visible = not selected
			setGradientEnabled(notSelectedGrad, not selected)
		else
			setGradientEnabled(notSelectedGrad, not selected)
		end
	end
end

local function resolveTabButton(tabRoot: Instance): GuiButton?
	if tabRoot:IsA("GuiButton") then
		return tabRoot
	end
	local btn = tabRoot:FindFirstChildWhichIsA("GuiButton", true)
	if btn then
		return btn
	end
	return nil
end

local function resolveTabTiltTarget(tabRoot: Instance, btn: GuiButton): GuiObject
	local nameLbl = tabRoot:FindFirstChild("Name", true)
	if nameLbl and nameLbl:IsA("GuiObject") then
		return nameLbl :: GuiObject
	end
	local icon = btn:FindFirstChild("Icon", true)
	if icon and icon:IsA("GuiObject") then
		return icon :: GuiObject
	end
	return btn
end

local function wireTabInteractions(tabRoot: Instance, mutationId: string)
	local btn = resolveTabButton(tabRoot)
	if not btn then
		return
	end
	local tiltTarget = resolveTabTiltTarget(tabRoot, btn)
	local scale = getOrAddUIScale(btn)

	btn.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.06 }):Play()
		TweenService:Create(tiltTarget, TILT_HOVER, { Rotation = -4 }):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
		TweenService:Create(tiltTarget, TILT_RESET, { Rotation = 0 }):Play()
	end)
	btn.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.94 }):Play()
		TweenService:Create(tiltTarget, TILT_CLICK, { Rotation = 2.5 }):Play()
	end)
	btn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.06 }):Play()
		TweenService:Create(tiltTarget, TILT_HOVER, { Rotation = -4 }):Play()
	end)
	btn.Activated:Connect(function()
		selectMutation(mutationId)
	end)
end

local function playPanelOpenAnim()
	if not indexFrame then
		return
	end
	local scale = getOrAddUIScale(indexFrame)
	scale.Scale = 0.82
	TweenService:Create(scale, OPEN_PANEL, { Scale = 1 }):Play()
end

local function incomeForCatalog(entry: { name: string, rarity: string, baseIncome: number }, mutationId: string): number
	return BrainrotEconomy.incomePerSecond({
		name = entry.name,
		rarity = entry.rarity,
		mutation = mutationId,
		level = 1,
		baseIncome = entry.baseIncome,
	})
end

local function sortCatalog(
	catalog: { { name: string, rarity: string, baseIncome: number } },
	mutationId: string
)
	table.sort(catalog, function(a, b)
		local ia = incomeForCatalog(a, mutationId)
		local ib = incomeForCatalog(b, mutationId)
		if ia ~= ib then
			return ia < ib
		end
		local ra = IndexConfig.RARITY_SORT[a.rarity] or 99
		local rb = IndexConfig.RARITY_SORT[b.rarity] or 99
		if ra ~= rb then
			return ra < rb
		end
		return a.name < b.name
	end)
end

local function setBlackoutOnIcon(iconHost: Instance, locked: boolean)
	local blackout = iconHost:FindFirstChild("Blackout", true)
	if blackout then
		for _, d in blackout:GetDescendants() do
			if d:IsA("UIGradient") then
				d.Enabled = locked
			end
		end
		if blackout:IsA("UIGradient") then
			blackout.Enabled = locked
		end
	end
end

local function populateRow(
	row: Frame,
	entry: { name: string, rarity: string, baseIncome: number, icon: string },
	mutationId: string,
	unlocked: boolean
)
	local frame = row:FindFirstChild("Frame") or row
	local icon = frame:FindFirstChild("Icon", true)
	if icon and icon:IsA("ImageLabel") then
		if entry.icon ~= "" then
			icon.Image = entry.icon
		end
		setBlackoutOnIcon(icon, not unlocked)
	end

	local nameLabel = frame:FindFirstChild("Name", true)
	if nameLabel and nameLabel:IsA("TextLabel") then
		if unlocked then
			BrainrotHeaderStyle.setTextOnNode(nameLabel, entry.name)
			nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		else
			nameLabel.Text = "???"
			nameLabel.TextColor3 = LOCKED_NAME_COLOR
			BrainrotHeaderStyle.selectGradient(nameLabel, nil)
		end
	end

	local info = frame:FindFirstChild("Info", true)
	if info then
		local rarityNode = info:FindFirstChild("Rarity", true)
		if rarityNode then
			if unlocked then
				BrainrotHeaderStyle.applyRarityLabel(rarityNode, entry.rarity)
			else
				BrainrotHeaderStyle.setTextOnNode(rarityNode, "???")
				BrainrotHeaderStyle.selectGradient(rarityNode, nil)
			end
		end
		local typeNode = info:FindFirstChild("Type", true)
		if typeNode then
			if unlocked then
				BrainrotHeaderStyle.applyMutationLabel(typeNode, mutationId)
			else
				BrainrotHeaderStyle.setTextOnNode(typeNode, "???")
				BrainrotHeaderStyle.selectGradient(typeNode, nil)
			end
		end
	end

	local decor = frame:FindFirstChild("Decor", true)
	if decor then
		local strokeHost = decor:FindFirstChild("Highlight", true)
		if strokeHost then
			local rs = strokeHost:FindFirstChild("RarityStroke", true) or strokeHost
			BrainrotHeaderStyle.applyRarityStroke(rs, entry.rarity)
		end
	end

	local rowHost = if frame:IsA("GuiObject") then frame :: GuiObject else row
	local rowScale = getOrAddUIScale(rowHost)
	rowScale.Scale = 0.94
	TweenService:Create(rowScale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	if icon and icon:IsA("GuiObject") then
		table.insert(
			rowHoverConns,
			icon.MouseEnter:Connect(function()
				if not tooltipLabel then
					return
				end
				local rate = incomeForCatalog(entry, mutationId)
				tooltipLabel.Text = BrainrotEconomy.formatCashShort(rate) .. "/s"
				tooltipLabel.Visible = true
				TweenService:Create(rowScale, ROW_HOVER_TWEEN, { Scale = 1.03 }):Play()
			end)
		)
		table.insert(
			rowHoverConns,
			icon.MouseLeave:Connect(function()
				if tooltipLabel then
					tooltipLabel.Visible = false
				end
				TweenService:Create(rowScale, ROW_HOVER_TWEEN, { Scale = 1 }):Play()
			end)
		)
	end
end

local function refreshQuest(goldenCount: number, questComplete: boolean)
	if not questsFrame then
		return
	end
	local amount = progressAmount
		or findLabel(questsFrame, { "Amount", "Collected", "ProgressText", "TextLabel" })
	if amount then
		if questComplete then
			amount.Text = "Completed!"
		else
			amount.Text = string.format("%d/%d Collected", goldenCount, IndexConfig.GOLDEN_QUEST_TARGET)
		end
	end
	if progressBar then
		local show = goldenCount > 0 and not questComplete
		progressBar.Visible = show
		if show then
			local frac = math.clamp(goldenCount / IndexConfig.GOLDEN_QUEST_TARGET, 0, 1)
			local goal = UDim2.new(frac, 0, progressBar.Size.Y.Scale, progressBar.Size.Y.Offset)
			if questBarTween then
				questBarTween:Cancel()
			end
			questBarTween = TweenService:Create(progressBar, QUEST_BAR_TWEEN, { Size = goal })
			questBarTween:Play()
		end
	end
end

local function clearGrid()
	for _, conn in rowHoverConns do
		conn:Disconnect()
	end
	table.clear(rowHoverConns)
	for _, row in catalogRows do
		row:Destroy()
	end
	table.clear(catalogRows)
	if not container or not rowTemplate then
		return
	end
	for _, c in container:GetChildren() do
		if c:IsA("Frame") and c ~= rowTemplate and c.Name ~= "UIListLayout" and c.Name ~= "UIPadding" and c.Name ~= "ScrollBarAdjuster" then
			c:Destroy()
		end
	end
end

local function rebuildGrid(state: any)
	if not container or not rowTemplate then
		return
	end
	clearGrid()
	local catalog = state.catalog
	if typeof(catalog) ~= "table" then
		return
	end
	local unlocked = state.unlocked
	if typeof(unlocked) ~= "table" then
		unlocked = {}
	end

	local list = {}
	for _, e in catalog do
		if typeof(e) == "table" then
			table.insert(list, e)
		end
	end
	sortCatalog(list, selectedMutation)

	local order = 0
	for _, entry in list do
		order += 1
		local row = rowTemplate:Clone()
		row.Name = "Entry_" .. entry.name
		row.Visible = true
		row.LayoutOrder = order
		row.Parent = container
		local key = IndexConfig.unlockKey(entry.name, selectedMutation)
		local isUnlocked = unlocked[key] == true
		populateRow(row, entry, selectedMutation, isUnlocked)
		table.insert(catalogRows, row)
	end

	refreshQuest(
		if typeof(state.goldenCount) == "number" then math.floor(state.goldenCount) else 0,
		state.questComplete == true
	)
end

local function fetchState(): any?
	if not getStateRF then
		return nil
	end
	local ok, result = pcall(function()
		return getStateRF:InvokeServer(selectedMutation)
	end)
	if ok then
		return result
	end
	return nil
end

local function updateHeader()
	if headerTitle then
		local tabName = IndexConfig.TAB_DISPLAY_NAME[selectedMutation] or selectedMutation
		headerTitle.Text = "Index: " .. tabName
	end
end

selectMutation = function(mutationId: string)
	if not IndexConfig.TAB_DISPLAY_NAME[mutationId] then
		return
	end
	selectedMutation = mutationId
	updateHeader()
	local typeButtons = indexFrame and indexFrame:FindFirstChild("TypeButtons")
	if typeButtons then
		for mutId, btnName in IndexConfig.TAB_BUTTON_NAME do
			local btn = typeButtons:FindFirstChild(btnName)
			if btn then
				applyTabVisual(btn, mutId == selectedMutation)
			end
		end
	end
	local state = fetchState()
	if state then
		rebuildGrid(state)
	end
end

local function hideIndexNotif()
	if not indexNotif then
		return
	end
	local host = indexNotif:FindFirstChildWhichIsA("Frame") or indexNotif
	local scale = getOrAddUIScale(host :: GuiObject)
	local tween = TweenService:Create(scale, CLOSE_NOTIF, { Scale = 0.01 })
	tween.Completed:Once(function()
		indexNotif.Visible = false
	end)
	tween:Play()
end

local function showIndexNotif(name: string, mutationId: string)
	if not indexNotif or not indexNotifLabel then
		return
	end
	local typeName = IndexConfig.TAB_DISPLAY_NAME[mutationId] or mutationId
	indexNotifLabel.Text = string.format("%s %s Has been added to index!", typeName, name)
	indexNotifLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	BrainrotHeaderStyle.selectGradient(indexNotifLabel, BrainrotHeaderStyle.MUTATION_GRADIENT_NAME[mutationId])

	local host = indexNotif:FindFirstChildWhichIsA("Frame") or indexNotif
	local scale = getOrAddUIScale(host :: GuiObject)
	indexNotif.Visible = true
	scale.Scale = 0.01
	TweenService:Create(scale, OPEN_NOTIF, { Scale = 1 }):Play()
	UIInteractionSounds.playNotif()
	task.delay(3.2, hideIndexNotif)
end

local function ensureTooltip()
	if tooltipGui and tooltipGui.Parent then
		return
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "IndexIncomeTooltip"
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 200
	sg.IgnoreGuiInset = true
	sg.Parent = playerGui
	tooltipGui = sg

	local lbl = Instance.new("TextLabel")
	lbl.Name = "Tip"
	lbl.BackgroundTransparency = 0.35
	lbl.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
	lbl.TextColor3 = Color3.fromRGB(220, 255, 230)
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 14
	lbl.AutomaticSize = Enum.AutomaticSize.XY
	lbl.Visible = false
	lbl.Parent = sg
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = lbl
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = lbl
	tooltipLabel = lbl

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement or not tooltipLabel.Visible then
			return
		end
		local pos = input.Position
		tooltipLabel.Position = UDim2.fromOffset(pos.X + 4, pos.Y + 4)
	end)
end

local IndexController = {}

function IndexController.init()
	local main = waitMain()
	if not main then
		warn("[IndexController] Main missing")
		return
	end

	local frames = main:WaitForChild("Frames", 30)
	indexFrame = if frames then frames:FindFirstChild("Index") :: Frame? else nil
	if not indexFrame then
		warn("[IndexController] Main.Frames.Index missing")
		return
	end

	headerTitle = findLabel(indexFrame, { "Title", "HeaderTitle", "Name" })
		or (indexFrame:FindFirstChild("Header") and findLabel(indexFrame.Header, { "Title", "Name" }))
	container = indexFrame:FindFirstChild("Container", true) :: ScrollingFrame?
	if container then
		rowTemplate = container:FindFirstChild("1") :: Frame?
		if rowTemplate then
			rowTemplate.Visible = false
		end
	end

	questsFrame = indexFrame:FindFirstChild("Quests", true) :: Frame?
	if questsFrame then
		local progress = questsFrame:FindFirstChild("Progress", true)
		if progress then
			progressBar = progress:FindFirstChild("Bar", true) :: Frame?
		end
		progressAmount = findLabel(questsFrame, { "Amount", "Collected", "ProgressText" })
	end

	local top = main:FindFirstChild("SideUI")
	if top then
		top = top:FindFirstChild("Top")
	end
	if top then
		indexNotif = top:FindFirstChild("IndexNotif") :: GuiObject?
		if indexNotif then
			indexNotif.Visible = false
			indexNotifLabel = findLabel(indexNotif, { "Text", "TextLabel", "Message", "Name" })
		end
	end

	ensureTooltip()

	local typeButtons = indexFrame:FindFirstChild("TypeButtons")
	if typeButtons then
		for mutationId, btnName in IndexConfig.TAB_BUTTON_NAME do
			local tabRoot = typeButtons:FindFirstChild(btnName)
			if tabRoot then
				wireTabInteractions(tabRoot, mutationId)
				applyTabVisual(tabRoot, mutationId == selectedMutation)
			end
		end
	end

	local header = indexFrame:FindFirstChild("Header", true)
	local closeBtn = if header then header:FindFirstChild("Close", true) or header:FindFirstChild("X", true) else nil
	if closeBtn and closeBtn:IsA("GuiButton") then
		local closeScale = getOrAddUIScale(closeBtn)
		closeBtn.MouseEnter:Connect(function()
			UIInteractionSounds.playHover()
			TweenService:Create(closeScale, HOVER_TWEEN, { Scale = 1.08 }):Play()
		end)
		closeBtn.MouseLeave:Connect(function()
			TweenService:Create(closeScale, HOVER_TWEEN, { Scale = 1 }):Play()
		end)
		closeBtn.Activated:Connect(function()
			UIInteractionSounds.playClick()
			HUDController.closeCurrentFrame()
		end)
	end

	local wasVisible = indexFrame.Visible
	indexFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if indexFrame.Visible then
			if not wasVisible and HUDController.getCurrentFrame() ~= indexFrame then
				playPanelOpenAnim()
			end
			wasVisible = true
			local state = fetchState()
			if state then
				rebuildGrid(state)
			end
		else
			wasVisible = false
			if tooltipLabel then
				tooltipLabel.Visible = false
			end
		end
	end)

	selectMutation("normal")

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("IndexRemotes", 60)
		if remotes then
			local rf = remotes:WaitForChild("GetIndexState", 30)
			local re = remotes:WaitForChild("IndexUnlocked", 30)
			if rf and rf:IsA("RemoteFunction") then
				getStateRF = rf
			end
			if re and re:IsA("RemoteEvent") then
				unlockedRE = re
				unlockedRE.OnClientEvent:Connect(function(payload)
					if typeof(payload) ~= "table" then
						return
					end
					local name = payload.name
					local mutation = payload.mutation
					if typeof(name) == "string" and typeof(mutation) == "string" then
						showIndexNotif(name, mutation)
					end
					if indexFrame and indexFrame.Visible then
						local state = fetchState()
						if state then
							rebuildGrid(state)
						end
					end
					refreshQuest(
						if typeof(payload.goldenCount) == "number" then math.floor(payload.goldenCount) else 0,
						payload.questComplete == true
					)
				end)
			end
		end

		local state = fetchState()
		if state then
			rebuildGrid(state)
		end
	end)
end

return IndexController
