-- [ACTIVE] SellController
--[[
	Sell UI — inventory rows, per-item sell, Sell All; SellInfo confirm is its own panel.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local HUDController = require(script.Parent.HUDController)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local MobileHaptics = require(script.Parent.MobileHaptics)
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local MobileTouchGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))

local player = Players.LocalPlayer

type InvEntry = BrainrotEconomy.InvEntry

local sellFrame: Frame? = nil
local sellInfoFrame: Frame? = nil
local container: Frame? = nil
local rowTemplate: Frame? = nil
local nothingLabel: TextLabel? = nil
local sellAllBtn: GuiButton? = nil
local busy = false
local refreshSerial = 0
type PendingConfirm =
	{ kind: "one", idx: number, entry: InvEntry, price: number }
	| { kind: "all", count: number, totalPrice: number }
local pendingConfirm: PendingConfirm? = nil

local sellOneRF: RemoteFunction? = nil
local sellAllRF: RemoteFunction? = nil
local refreshSellList: () -> ()

local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function waitMain(): ScreenGui?
	if not player.Character then
		player.CharacterAdded:Wait()
	end
	return player:WaitForChild("PlayerGui"):FindFirstChild("Main") :: ScreenGui?
end

local function findGuiButton(root: Instance, names: { string }): GuiButton?
	for _, n in names do
		local inst = root:FindFirstChild(n, true)
		if inst and inst:IsA("GuiButton") then
			return inst
		end
	end
	return nil
end

local SELL_OVERLAY_NAME = "__SellRowOverlay"
local SELL_PRICE_TEXT_COLOR = Color3.new(1, 1, 1)
local CONTAINER_SKIP_DESTROY = {
	UIListLayout = true,
	UIPadding = true,
	ScrollBarAdjuster = true,
	SPACE = true,
}

local function configureSellContainer()
	if not container then
		return
	end
	container.Active = true
	if container:IsA("ScrollingFrame") then
		(container :: ScrollingFrame).Active = true
	end
	if rowTemplate then
		rowTemplate.Visible = false
	end
	for _, ch in container:GetChildren() do
		if ch.Name == "ScrollBarAdjuster" and ch:IsA("GuiObject") then
			ch.Active = false
			ch.ZIndex = 1
		end
	end
end

local function isPriceLikeText(text: string): boolean
	return string.find(text, "$", 1, true) ~= nil or string.find(text, "+", 1, true) ~= nil
end

local function ensureRowInputChain(leaf: GuiObject)
	local w: Instance? = leaf
	while w do
		if w:IsA("GuiObject") then
			(w :: GuiObject).Active = true
		end
		if w:IsA("ScrollingFrame") then
			(w :: ScrollingFrame).Active = true
		end
		if w:IsA("SurfaceGui") then
			(w :: SurfaceGui).Active = true
		end
		if w == sellFrame or w == sellInfoFrame or w:IsA("ScreenGui") then
			break
		end
		w = w.Parent
	end
end

local function mutePassiveGui(root: Instance, except: Instance?)
	for _, d in root:GetDescendants() do
		if d == except then
			continue
		end
		if d:IsA("Frame") or d:IsA("ImageLabel") or d:IsA("TextLabel") then
			(d :: GuiObject).Active = false
		end
	end
end

local function ensureSellFrameInput()
	if not sellFrame then
		return
	end
	sellFrame.Active = true
	ensureRowInputChain(sellFrame)
	if sellInfoFrame then
		sellInfoFrame.Active = true
		ensureRowInputChain(sellInfoFrame)
	end
end

local function wireSellButton(clickBtn: GuiButton, handler: () -> ())
	local lastAt = 0
	local function fire()
		if not MobileTouchGate.canTapUi() then
			return
		end
		local now = os.clock()
		if now - lastAt < 0.15 then
			return
		end
		lastAt = now
		UIInteractionSounds.playClick()
		MobileHaptics.confirm()
		handler()
	end
	mutePassiveGui(clickBtn)
	clickBtn.Active = true
	clickBtn.Selectable = true
	ensureRowInputChain(clickBtn)
	clickBtn.MouseButton1Down:Connect(fire)
	clickBtn.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			fire()
		end
	end)
end

local function resolveSellFace(row: Frame): Instance?
	local host = row:FindFirstChild("SellButton")
	if host then
		return host:FindFirstChild("Sell")
	end
	return row:FindFirstChild("Sell", true)
end

local function resolveSellPriceNode(row: Frame): Instance?
	local face = resolveSellFace(row)
	if face then
		local amount = face:FindFirstChild("Amount", true)
		if amount then
			return amount
		end
	end
	local host = row:FindFirstChild("SellButton")
	if host then
		for _, name in { "Amount", "Price", "Value", "SellPrice", "SellAmount" } do
			local node = host:FindFirstChild(name, true)
			if node then
				return node
			end
		end
	end
	for _, name in { "Amount", "Price", "Value", "SellPrice", "SellAmount", "Cash" } do
		local node = row:FindFirstChild(name, true)
		if node then
			return node
		end
	end
	return nil
end

local function ensureSellClickTarget(row: Frame): (GuiButton?, GuiObject?, Instance?)
	local host = row:FindFirstChild("SellButton")
	local face = resolveSellFace(row)

	-- Prefer the inner Sell TextButton — overlay on SellButton breaks under UIListLayout.
	if face and face:IsA("GuiButton") then
		local clickBtn = face :: GuiButton
		local animTarget = if face:IsA("GuiObject") then face :: GuiObject else clickBtn
		mutePassiveGui(clickBtn)
		clickBtn.Active = true
		clickBtn.Selectable = true
		ensureRowInputChain(clickBtn)
		return clickBtn, animTarget, resolveSellPriceNode(row)
	end

	if not host or not host:IsA("GuiObject") then
		local fallback = findGuiButton(row, { "Sell", "SellButton" })
		if fallback then
			mutePassiveGui(fallback)
			fallback.Active = true
			ensureRowInputChain(fallback)
		end
		return fallback, if fallback then fallback :: GuiObject else row, resolveSellPriceNode(row)
	end

	local hostGui = host :: GuiObject
	local animTarget: GuiObject = hostGui
	mutePassiveGui(hostGui)
	hostGui.Active = true
	ensureRowInputChain(hostGui)

	local existing = host:FindFirstChild(SELL_OVERLAY_NAME)
	local clickBtn: TextButton
	if existing and existing:IsA("TextButton") then
		clickBtn = existing
	else
		if existing then
			existing:Destroy()
		end
		clickBtn = Instance.new("TextButton")
		clickBtn.Name = SELL_OVERLAY_NAME
		clickBtn.AnchorPoint = Vector2.new(0.5, 0.5)
		clickBtn.Position = UDim2.fromScale(0.5, 0.5)
		clickBtn.Size = UDim2.fromScale(1, 1)
		clickBtn.BackgroundTransparency = 1
		clickBtn.Text = ""
		clickBtn.TextTransparency = 1
		clickBtn.AutoButtonColor = false
		clickBtn.BorderSizePixel = 0
		clickBtn.ZIndex = 1000
		clickBtn.Parent = hostGui
	end

	clickBtn.Active = true
	clickBtn.Selectable = true
	clickBtn.ZIndex = 1000

	return clickBtn, animTarget, resolveSellPriceNode(row)
end

local function _resolveSellButton(row: Frame): GuiButton?
	return select(1, ensureSellClickTarget(row))
end

local function getOrAddUIScale(parent: Instance): UIScale
	local s = parent:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Parent = parent
	return s
end

local function bindButtonMicroAnim(clickBtn: GuiButton, animTarget: Instance, hoverPeak: number?, downPeak: number?)
	local hoverTo = hoverPeak or 1.06
	local downTo = downPeak or 0.94
	local scale = getOrAddUIScale(animTarget)
	clickBtn.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = hoverTo }):Play()
	end)
	clickBtn.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.0 }):Play()
	end)
	clickBtn.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = downTo }):Play()
	end)
	clickBtn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = hoverTo }):Play()
	end)
end

local wiredSellButtons: { [GuiButton]: boolean } = {}

local function wireButtonAnim(clickBtn: GuiButton?, animTarget: Instance?)
	if not clickBtn or wiredSellButtons[clickBtn] then
		return
	end
	wiredSellButtons[clickBtn] = true
	bindButtonMicroAnim(clickBtn, animTarget or clickBtn)
end

local function headerButtonsOf(frame: Frame): Instance?
	local header = frame:FindFirstChild("Header")
	return header and header:FindFirstChild("Buttons")
end

local function disableTextGradients(node: Instance)
	for _, c in node:GetDescendants() do
		if c:IsA("UIGradient") then
			c.Enabled = false
		end
	end
	if node:IsA("UIGradient") then
		node.Enabled = false
	end
end

local function applySellPriceLabel(node: Instance, priceText: string)
	if node:IsA("TextLabel") or node:IsA("TextButton") then
		disableTextGradients(node)
		local label = node :: TextLabel
		label.Text = priceText
		label.TextColor3 = SELL_PRICE_TEXT_COLOR
		label.TextTransparency = 0
		return
	end
	local tl = BrainrotHeaderStyle.resolveTextLabel(node)
	if not tl then
		return
	end
	disableTextGradients(tl)
	tl.Text = priceText
	tl.TextColor3 = SELL_PRICE_TEXT_COLOR
	tl.TextTransparency = 0
end

local function applySellPriceToRow(row: Frame, priceText: string)
	local host = row:FindFirstChild("SellButton")
	local face = resolveSellFace(row)
	local updated = false

	local function tryUpdate(node: Instance?)
		if not node then
			return
		end
		if node:IsA("TextLabel") or node:IsA("TextButton") then
			if node.Name == "Amount" or isPriceLikeText((node :: TextLabel).Text) then
				applySellPriceLabel(node, priceText)
				updated = true
			end
			return
		end
		if node.Name == "Amount" then
			applySellPriceLabel(node, priceText)
			updated = true
		end
	end

	tryUpdate(face and face:FindFirstChild("Amount"))
	if host then
		for _, desc in host:GetDescendants() do
			if desc:IsA("TextLabel") or desc:IsA("TextButton") then
				if desc.Name == "Amount" or isPriceLikeText(desc.Text) then
					applySellPriceLabel(desc, priceText)
					updated = true
				end
			end
		end
	end
	if not updated then
		for _, desc in row:GetDescendants() do
			if desc:IsA("TextLabel") or desc:IsA("TextButton") then
				if desc.Name == "Amount" or isPriceLikeText(desc.Text) then
					applySellPriceLabel(desc, priceText)
					updated = true
				end
			end
		end
	end

	local clickBtn = select(1, ensureSellClickTarget(row))
	if clickBtn and clickBtn:IsA("TextButton") and clickBtn.Name ~= SELL_OVERLAY_NAME then
		clickBtn.Text = ""
	end
end

local function getRemotes()
	if sellOneRF and sellAllRF then
		return sellOneRF, sellAllRF
	end
	local folder = ReplicatedStorage:WaitForChild("BushRemotes", 30)
	if not folder then
		return nil, nil
	end
	local one = folder:WaitForChild("SellBrainrot", 15)
	local all = folder:WaitForChild("SellAllBrainrot", 15)
	if one and one:IsA("RemoteFunction") and all and all:IsA("RemoteFunction") then
		sellOneRF = one
		sellAllRF = all
		return sellOneRF, sellAllRF
	end
	return nil, nil
end

local function clearSellRows()
	if not container then
		return
	end
	for _, c in container:GetChildren() do
		if c == rowTemplate or CONTAINER_SKIP_DESTROY[c.Name] then
			continue
		end
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	if rowTemplate then
		rowTemplate.Visible = false
	end
end

local function setSellInfoVisible(on: boolean)
	if not sellInfoFrame then
		return
	end
	if on then
		-- Own panel (not stacked on Sell) — keep HUD blur/chrome via replaceOpenFrame.
		HUDController.replaceOpenFrame(sellInfoFrame)
		return
	end
	if HUDController.getCurrentFrame() == sellInfoFrame then
		if sellFrame then
			HUDController.replaceOpenFrame(sellFrame)
		else
			sellInfoFrame.Visible = false
			HUDController.forceClearPanelModal()
		end
		return
	end
	sellInfoFrame.Visible = false
end

local function formatSellConfirmMessage(entry: InvEntry, price: number): string
	local detailParts: { string } = {}
	local mut = entry.mutation
	if typeof(mut) == "string" and mut ~= "" and mut ~= "normal" then
		local display = BrainrotHeaderStyle.MUTATION_DISPLAY_NAME[mut] or mut
		table.insert(detailParts, display)
	end
	local lv = math.max(1, math.floor(entry.level))
	if lv > 1 then
		table.insert(detailParts, "Lvl " .. tostring(lv))
	end
	local suffix = ""
	if #detailParts > 0 then
		suffix = " (" .. table.concat(detailParts, ", ") .. ")"
	end
	return string.format(
		"Are you sure you want to sell %s%s for %s?",
		entry.name,
		suffix,
		BrainrotEconomy.formatCashShort(price)
	)
end

local function setSellInfoTitle(text: string)
	if not sellInfoFrame then
		return
	end
	local titleRoot = sellInfoFrame:FindFirstChild("Title", true)
		or sellInfoFrame:FindFirstChild("Header", true)
		or sellInfoFrame:FindFirstChild("Top", true)
	if titleRoot then
		local titleLabel = titleRoot:FindFirstChild("Title", true)
			or titleRoot:FindFirstChild("Name", true)
			or titleRoot
		if titleLabel and (titleLabel:IsA("TextLabel") or titleLabel:IsA("TextButton") or titleLabel:FindFirstChildWhichIsA("TextLabel")) then
			BrainrotHeaderStyle.setTextOnNode(titleLabel, text)
		end
	end
end

local function setSellInfoMessage(message: string)
	if not sellInfoFrame then
		return
	end
	local notice = sellInfoFrame:FindFirstChild("Notice", true)
	if notice then
		BrainrotHeaderStyle.setTextOnNode(notice, message)
	end
	for _, name in { "Message", "Body", "Description", "ConfirmText", "Amount", "Prompt", "Text" } do
		local node = sellInfoFrame:FindFirstChild(name, true)
		if node then
			BrainrotHeaderStyle.setTextOnNode(node, message)
		end
	end
	for _, desc in ipairs(sellInfoFrame:GetDescendants()) do
		if desc:IsA("TextLabel") or desc:IsA("TextButton") then
			local text = desc.Text
			if string.find(text, "Are you sure", 1, true)
				or (string.find(text, "sell", 1, true) and string.find(text, "$", 1, true))
			then
				BrainrotHeaderStyle.setTextOnNode(desc, message)
			end
		end
	end
end

local function populateSellInfoConfirm(entry: InvEntry, price: number)
	if not sellInfoFrame then
		return
	end
	local message = formatSellConfirmMessage(entry, price)
	setSellInfoTitle(string.format("Sell %s?", entry.name))
	setSellInfoMessage(message)

	local info = sellInfoFrame:FindFirstChild("Info", true) or sellInfoFrame:FindFirstChild("BrainrotInfo", true)
	if info and info:IsA("GuiObject") then
		(info :: GuiObject).Visible = true
	end
	local icon = sellInfoFrame:FindFirstChild("Icon", true)
	if icon and icon:IsA("GuiObject") then
		(icon :: GuiObject).Visible = true
	end
	if info then
		BrainrotHeaderStyle.applyInfoFrame(info, {
			name = entry.name,
			rarity = entry.rarity,
			mutation = entry.mutation,
			level = entry.level,
			rateText = BrainrotEconomy.formatCashShort(BrainrotEconomy.incomePerSecond(entry)) .. "/s",
		})
	end

	if icon and icon:IsA("ImageLabel") and entry.icon ~= "" then
		icon.Image = entry.icon
	end
end

local function fetchInventoryEntries(): { InvEntry }
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	local getFn = folder and folder:FindFirstChild("GetBrainrotInventory")
	if not getFn or not getFn:IsA("RemoteFunction") then
		return {}
	end
	local ok, pack = pcall(function()
		return getFn:InvokeServer()
	end)
	if not ok then
		warn("[SellController] fetchInventoryEntries failed:", pack)
		return {}
	end
	if typeof(pack) ~= "table" then
		return {}
	end
	local entries = pack.entries
	if typeof(entries) ~= "table" then
		return {}
	end
	local out: { InvEntry } = {}
	for _, entry in ipairs(entries) do
		if typeof(entry) == "table" then
			table.insert(out, entry :: InvEntry)
		end
	end
	return out
end

local function populateSellAllConfirm(count: number, totalPrice: number)
	if not sellInfoFrame then
		return
	end
	local message = string.format(
		"Are you sure you want to sell all %d brainrot%s for %s?",
		count,
		if count == 1 then "" else "s",
		BrainrotEconomy.formatCashShort(totalPrice)
	)
	setSellInfoTitle("Sell All?")
	setSellInfoMessage(message)

	local info = sellInfoFrame:FindFirstChild("Info", true) or sellInfoFrame:FindFirstChild("BrainrotInfo", true)
	if info and info:IsA("GuiObject") then
		(info :: GuiObject).Visible = false
	end
	local icon = sellInfoFrame:FindFirstChild("Icon", true)
	if icon and icon:IsA("GuiObject") then
		(icon :: GuiObject).Visible = false
	end
end

local function populateRow(row: Frame, entry: InvEntry, idx: number)
	local icon = row:FindFirstChild("Icon", true)
	if icon and icon:IsA("ImageLabel") then
		if entry.icon ~= "" then
			icon.Image = entry.icon
		end
	end
	local nameNode = row:FindFirstChild("Name", true) or row:FindFirstChild("BrainrotName", true)
	if nameNode then
		BrainrotHeaderStyle.setTextOnNode(nameNode, entry.name)
	end
	local rarityNode = row:FindFirstChild("Rarity", true)
	if rarityNode then
		BrainrotHeaderStyle.applyRarityLabel(rarityNode, entry.rarity)
	end
	local typeNode = row:FindFirstChild("Type", true) or row:FindFirstChild("Mutation", true)
	if typeNode then
		if entry.mutation == "normal" then
			(typeNode :: GuiObject).Visible = false
		else
			(typeNode :: GuiObject).Visible = true
			BrainrotHeaderStyle.applyMutationLabel(typeNode, entry.mutation)
		end
	end
	local levelNode = row:FindFirstChild("Level", true)
	if levelNode then
		BrainrotHeaderStyle.setTextOnNode(levelNode, "Lvl " .. tostring(math.floor(entry.level)))
	end
	local rateNode = row:FindFirstChild("Rate", true) or row:FindFirstChild("Income", true)
	if rateNode then
		BrainrotHeaderStyle.setTextOnNode(rateNode, BrainrotEconomy.formatCashShort(BrainrotEconomy.incomePerSecond(entry)) .. "/s")
	end
	local price = BrainrotEconomy.sellPrice(entry)
	local priceText = BrainrotEconomy.formatSellButton(price)
	applySellPriceToRow(row, priceText)
	local clickBtn, animTarget = ensureSellClickTarget(row)
	if not clickBtn then
		return
	end
	if row:GetAttribute("SellRowWired") then
		return
	end
	row:SetAttribute("SellRowWired", true)
	wireButtonAnim(clickBtn, animTarget)
	local function onSellClick()
		if busy then
			return
		end
		if not sellInfoFrame then
			task.spawn(function()
				local rf = getRemotes()
				if not rf then
					return
				end
				busy = true
				local invokeOk, invokeErr = pcall(function()
					(rf :: RemoteFunction):InvokeServer(idx)
				end)
				if not invokeOk then
					warn("[SellController] sell invoke failed:", invokeErr)
				end
				busy = false
				task.defer(refreshSellList)
			end)
			return
		end
		pendingConfirm = { kind = "one", idx = idx, entry = entry, price = price }
		populateSellInfoConfirm(entry, price)
		setSellInfoVisible(true)
	end
	wireSellButton(clickBtn, onSellClick)
end

refreshSellList = function()
	if not container or not rowTemplate then
		warn("[SellController] Sell list refresh skipped — Container or row template missing")
		return
	end
	refreshSerial += 1
	local mySerial = refreshSerial
	configureSellContainer()
	clearSellRows()
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	local getFn = folder and folder:FindFirstChild("GetBrainrotInventory")
	if not getFn or not getFn:IsA("RemoteFunction") then
		return
	end
	local ok, pack = pcall(function()
		return getFn:InvokeServer()
	end)
	if mySerial ~= refreshSerial then
		return
	end
	if not ok then
		warn("[SellController] GetBrainrotInventory failed:", pack)
		return
	end
	if typeof(pack) ~= "table" then
		return
	end
	local entries = pack.entries
	if typeof(entries) ~= "table" then
		entries = {}
	end
	-- InvokeServer yields — clear again so a concurrent refresh cannot leave doubles.
	clearSellRows()
	if mySerial ~= refreshSerial then
		return
	end
	if nothingLabel then
		nothingLabel.Visible = (#entries == 0)
	end
	for i, entry in ipairs(entries) do
		if typeof(entry) == "table" then
			local row = rowTemplate:Clone()
			row.Name = "Row_" .. tostring(i)
			row.Visible = true
			row.LayoutOrder = i
			row:SetAttribute("SellGeneratedRow", true)
			row.Parent = container
			populateRow(row, entry :: InvEntry, i)
		end
	end
end

local function confirmSell()
	if not pendingConfirm then
		return
	end
	local confirm = pendingConfirm
	pendingConfirm = nil
	setSellInfoVisible(false)

	if confirm.kind == "all" then
		local _, allRf = getRemotes()
		if not allRf or busy then
			return
		end
		busy = true
		local allOk, allErr = pcall(function()
			allRf:InvokeServer()
		end)
		if not allOk then
			warn("[SellController] sell all failed:", allErr)
		end
		busy = false
		refreshSellList()
		return
	end

	local idx = confirm.idx
	local rf = select(1, getRemotes())
	if not rf or busy then
		return
	end
	busy = true
	local oneOk, oneErr = pcall(function()
		rf:InvokeServer(idx)
	end)
	if not oneOk then
		warn("[SellController] sell one failed:", oneErr)
	end
	busy = false
	refreshSellList()
end

local function cancelSell()
	pendingConfirm = nil
	setSellInfoVisible(false)
end

local SellController = {}

function SellController.init()
	task.spawn(function()
		local main = waitMain()
		if not main then
			warn("[SellController] Main ScreenGui missing")
			return
		end
		local frames = main:WaitForChild("Frames", 30)
		if not frames then
			return
		end
		sellFrame = frames:FindFirstChild("Sell") :: Frame?
		if not sellFrame then
			warn("[SellController] Main.Frames.Sell missing in Studio")
			return
		end
		sellInfoFrame = frames:FindFirstChild("SellInfo") :: Frame?
		ensureSellFrameInput()
		container = sellFrame:FindFirstChild("Container", true) :: Frame?
		if container then
			rowTemplate = container:FindFirstChild("1") :: Frame?
				or container:FindFirstChild("Template") :: Frame?
			configureSellContainer()
		end
		nothingLabel = sellFrame:FindFirstChild("NothingToSellText", true) :: TextLabel?

		local sellHeaderButtons = headerButtonsOf(sellFrame)
		if sellHeaderButtons then
			local closeBtn = sellHeaderButtons:FindFirstChild("Close")
			if closeBtn and closeBtn:IsA("GuiButton") then
				UIButtonEffects.wireGlistenCloseButton(closeBtn, function()
					cancelSell()
					if HUDController.getCurrentFrame() then
						HUDController.closeCurrentFrame()
					else
						if sellFrame then
							sellFrame.Visible = false
						end
						HUDController.forceClearPanelModal()
					end
				end)
			end
			sellAllBtn = sellHeaderButtons:FindFirstChild("SellAll") :: GuiButton?
			if sellAllBtn and sellAllBtn:IsA("GuiButton") then
				wireButtonAnim(sellAllBtn)
				wireSellButton(sellAllBtn, function()
					if busy then
						return
					end
					local entries = fetchInventoryEntries()
					if #entries == 0 then
						return
					end
					local totalPrice = 0
					for _, entry in ipairs(entries) do
						totalPrice += BrainrotEconomy.sellPrice(entry)
					end
					if sellInfoFrame then
						pendingConfirm = { kind = "all", count = #entries, totalPrice = totalPrice }
						populateSellAllConfirm(#entries, totalPrice)
						setSellInfoVisible(true)
						return
					end
					local _, allRf = getRemotes()
					if not allRf then
						return
					end
					busy = true
					local allOk, allErr = pcall(function()
						allRf:InvokeServer()
					end)
					if not allOk then
						warn("[SellController] sell all failed:", allErr)
					end
					busy = false
					refreshSellList()
				end)
			end
		end

		if sellFrame then
			sellFrame.Visible = false
		end
		if sellInfoFrame then
			sellInfoFrame.Visible = false

			local infoHeaderButtons = headerButtonsOf(sellInfoFrame)
			if infoHeaderButtons then
				local infoClose = infoHeaderButtons:FindFirstChild("Close")
				if infoClose and infoClose:IsA("GuiButton") then
					UIButtonEffects.wireGlistenCloseButton(infoClose, cancelSell)
				end
			end

			local infoButtons = sellInfoFrame:FindFirstChild("Buttons")
			if infoButtons then
				local yesBtn = infoButtons:FindFirstChild("Sell")
				if yesBtn and yesBtn:IsA("GuiButton") then
					wireButtonAnim(yesBtn)
					wireSellButton(yesBtn, confirmSell)
				end
				local noBtn = infoButtons:FindFirstChild("Cancel")
				if noBtn and noBtn:IsA("GuiButton") then
					wireButtonAnim(noBtn)
					wireSellButton(noBtn, cancelSell)
				end
			end
		end
		sellFrame:GetPropertyChangedSignal("Visible"):Connect(function()
			if sellFrame and sellFrame.Visible then
				refreshSellList()
			end
		end)
		local bushFolder = ReplicatedStorage:WaitForChild("BushRemotes", 60)
		if bushFolder then
			local sync = bushFolder:WaitForChild("BrainrotInventorySync", 30)
			if sync and sync:IsA("RemoteEvent") then
				sync.OnClientEvent:Connect(function()
					if sellFrame and sellFrame.Visible then
						refreshSellList()
					end
				end)
			end
		end
		getRemotes()
		if sellFrame and sellFrame.Visible then
			refreshSellList()
		end
	end)
end

return SellController
