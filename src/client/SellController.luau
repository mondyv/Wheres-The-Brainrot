--[[
	Sell UI — inventory rows, per-item sell, Sell All, optional SellInfo confirm.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local HUDController = require(script.Parent.HUDController)
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))

local player = Players.LocalPlayer

type InvEntry = BrainrotEconomy.InvEntry

local sellFrame: Frame? = nil
local sellInfoFrame: Frame? = nil
local container: Frame? = nil
local rowTemplate: Frame? = nil
local nothingLabel: TextLabel? = nil
local sellAllBtn: GuiButton? = nil
local busy = false
local sellFrameHiddenForConfirm = false
local pendingConfirm: { idx: number, entry: InvEntry, price: number }? = nil

local sellOneRF: RemoteFunction? = nil
local sellAllRF: RemoteFunction? = nil
local refreshSellList: () -> ()

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

local function resolveSellButton(row: Frame): GuiButton?
	for _, n in { "Sell", "SellButton" } do
		local inst = row:FindFirstChild(n, true)
		if not inst then
			continue
		end
		if inst:IsA("GuiButton") then
			return inst
		end
		local nested = inst:FindFirstChildWhichIsA("GuiButton", true)
		if nested then
			return nested
		end
	end
	return findGuiButton(row, { "Sell", "SellButton" })
end

local function looksLikeSellPriceText(text: string): boolean
	if string.find(text, "/s", 1, true) then
		return false
	end
	if string.find(text, "+$", 1, true) then
		return true
	end
	if not string.find(text, "$", 1, true) then
		return false
	end
	return string.find(text, "K", 1, true) ~= nil
		or string.find(text, "M", 1, true) ~= nil
		or string.find(text, "B", 1, true) ~= nil
		or string.find(text, "T", 1, true) ~= nil
end

local function applySellPriceToRow(row: Frame, priceText: string)
	for _, name in { "Price", "Amount", "Value", "SellPrice", "SellAmount", "Cash" } do
		local node = row:FindFirstChild(name, true)
		if node then
			BrainrotHeaderStyle.setTextOnNode(node, priceText)
		end
	end

	local sellBtn = resolveSellButton(row)
	if sellBtn then
		BrainrotHeaderStyle.setTextOnNode(sellBtn, priceText)
		for _, desc in sellBtn:GetDescendants() do
			if desc:IsA("TextLabel") or desc:IsA("TextButton") then
				if looksLikeSellPriceText(desc.Text) then
					BrainrotHeaderStyle.setTextOnNode(desc, priceText)
				end
			end
		end
	end

	for _, desc in row:GetDescendants() do
		if desc:IsA("TextLabel") or desc:IsA("TextButton") then
			if looksLikeSellPriceText(desc.Text) then
				BrainrotHeaderStyle.setTextOnNode(desc, priceText)
			end
		end
	end
end

local function wireHover(btn: GuiButton)
	btn.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
	end)
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

local function setSellInfoVisible(on: boolean)
	if sellInfoFrame then
		sellInfoFrame.Visible = on
	end
	if not sellFrame then
		return
	end
	if on then
		if sellFrame.Visible then
			sellFrameHiddenForConfirm = true
			sellFrame.Visible = false
		end
	else
		if sellFrameHiddenForConfirm then
			sellFrame.Visible = true
			sellFrameHiddenForConfirm = false
		end
	end
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

local function populateSellInfoConfirm(entry: InvEntry, price: number)
	if not sellInfoFrame then
		return
	end
	local message = formatSellConfirmMessage(entry, price)

	local titleRoot = sellInfoFrame:FindFirstChild("Title", true)
		or sellInfoFrame:FindFirstChild("Header", true)
		or sellInfoFrame:FindFirstChild("Top", true)
	if titleRoot then
		local titleLabel = titleRoot:FindFirstChild("Title", true)
			or titleRoot:FindFirstChild("Name", true)
			or titleRoot
		if titleLabel and (titleLabel:IsA("TextLabel") or titleLabel:IsA("TextButton") or titleLabel:FindFirstChildWhichIsA("TextLabel")) then
			BrainrotHeaderStyle.setTextOnNode(titleLabel, string.format("Sell %s?", entry.name))
		end
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
			if string.find(text, "Are you sure", 1, true) or string.find(text, "sell", 1, true) and string.find(text, "$", 1, true) then
				BrainrotHeaderStyle.setTextOnNode(desc, message)
			end
		end
	end

	local info = sellInfoFrame:FindFirstChild("Info", true) or sellInfoFrame:FindFirstChild("BrainrotInfo", true)
	if info then
		BrainrotHeaderStyle.applyInfoFrame(info, {
			name = entry.name,
			rarity = entry.rarity,
			mutation = entry.mutation,
			level = entry.level,
			rateText = BrainrotEconomy.formatCashShort(BrainrotEconomy.incomePerSecond(entry)) .. "/s",
		})
	end

	local icon = sellInfoFrame:FindFirstChild("Icon", true)
	if icon and icon:IsA("ImageLabel") and entry.icon ~= "" then
		icon.Image = entry.icon
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
	local sellBtn = resolveSellButton(row)
	if sellBtn then
		if not sellBtn:GetAttribute("SellWired") then
			sellBtn:SetAttribute("SellWired", true)
			wireHover(sellBtn)
			sellBtn.Activated:Connect(function()
				if busy then
					return
				end
				pendingConfirm = { idx = idx, entry = entry, price = price }
				if sellInfoFrame then
					populateSellInfoConfirm(entry, price)
					setSellInfoVisible(true)
				else
					task.spawn(function()
						local rf = getRemotes()
						if not rf then
							return
						end
						busy = true
						pcall(function()
							(rf :: RemoteFunction):InvokeServer(idx)
						end)
						busy = false
						task.defer(refreshSellList)
					end)
				end
			end)
		end
	end
end

local function refreshSellList()
	if not container or not rowTemplate then
		return
	end
	for _, c in container:GetChildren() do
		if c:IsA("Frame") and c ~= rowTemplate and c.Name ~= "UIListLayout" and c.Name ~= "UIPadding" then
			c:Destroy()
		end
	end
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	local getFn = folder and folder:FindFirstChild("GetBrainrotInventory")
	if not getFn or not getFn:IsA("RemoteFunction") then
		return
	end
	local ok, pack = pcall(function()
		return getFn:InvokeServer()
	end)
	if not ok or typeof(pack) ~= "table" then
		return
	end
	local entries = pack.entries
	if typeof(entries) ~= "table" then
		entries = {}
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
			row.Parent = container
			populateRow(row, entry :: InvEntry, i)
		end
	end
end

local function confirmSell()
	if not pendingConfirm then
		return
	end
	local idx = pendingConfirm.idx
	pendingConfirm = nil
	setSellInfoVisible(false)
	local rf = select(1, getRemotes())
	if not rf or busy then
		return
	end
	busy = true
	UIInteractionSounds.playClick()
	pcall(function()
		rf:InvokeServer(idx)
	end)
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
		container = sellFrame:FindFirstChild("Container", true) :: Frame?
		if container then
			rowTemplate = container:FindFirstChild("1") :: Frame?
				or container:FindFirstChild("Template") :: Frame?
			if rowTemplate then
				rowTemplate.Visible = false
			end
		end
		nothingLabel = sellFrame:FindFirstChild("NothingToSellText", true) :: TextLabel?
		sellAllBtn = findGuiButton(sellFrame, { "SellAll", "Sell All" })
		if sellAllBtn then
			wireHover(sellAllBtn)
			sellAllBtn.Activated:Connect(function()
				if busy then
					return
				end
				local _, allRf = getRemotes()
				if not allRf then
					return
				end
				busy = true
				UIInteractionSounds.playClick()
				pcall(function()
					allRf:InvokeServer()
				end)
				busy = false
				refreshSellList()
			end)
		end
		local closeBtn = findGuiButton(sellFrame, { "Close", "CloseButton", "X", "Exit" })
		if closeBtn then
			closeBtn.Activated:Connect(function()
				HUDController.closeCurrentFrame()
			end)
		end
		if sellFrame then
			sellFrame.Visible = false
		end
		if sellInfoFrame then
			sellInfoFrame.Visible = false
			local yesBtn = findGuiButton(sellInfoFrame, { "Sell", "Yes", "Confirm" })
			local noBtn = findGuiButton(sellInfoFrame, { "Cancel", "No", "Close", "X" })
			if yesBtn then
				yesBtn.Activated:Connect(confirmSell)
			end
			if noBtn then
				noBtn.Activated:Connect(cancelSell)
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
	end)
end

return SellController
