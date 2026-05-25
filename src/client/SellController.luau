--[[
	Sell UI — inventory rows, per-item sell, Sell All, optional SellInfo confirm.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local HUDController = require(script.Parent.HUDController)
local UIModalBackdrop = require(script.Parent.UIModalBackdrop)
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
	local wasInfoVisible = sellInfoFrame and sellInfoFrame.Visible
	if sellInfoFrame then
		sellInfoFrame.Visible = on
	end
	if sellInfoFrame then
		if on and not wasInfoVisible then
			UIModalBackdrop.push()
		elseif not on and wasInfoVisible then
			UIModalBackdrop.pop()
		end
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
	local sellBtn = findGuiButton(row, { "Sell", "SellButton" })
	if sellBtn then
		local priceLabel = sellBtn:FindFirstChild("Price", true) or sellBtn:FindFirstChild("TextLabel", true)
		if priceLabel and priceLabel:IsA("TextLabel") then
			priceLabel.Text = BrainrotEconomy.formatSellButton(price)
		elseif sellBtn:IsA("TextButton") then
			sellBtn.Text = BrainrotEconomy.formatSellButton(price)
		end
		if not sellBtn:GetAttribute("SellWired") then
			sellBtn:SetAttribute("SellWired", true)
			wireHover(sellBtn)
			sellBtn.Activated:Connect(function()
				if busy then
					return
				end
				pendingConfirm = { idx = idx, entry = entry, price = price }
				if sellInfoFrame then
					local title = sellInfoFrame:FindFirstChild("Title", true) or sellInfoFrame:FindFirstChild("Name", true)
					if title then
						BrainrotHeaderStyle.setTextOnNode(title, string.format("Sell %s?", entry.name))
					end
					local amt = sellInfoFrame:FindFirstChild("Amount", true)
					if amt then
						BrainrotHeaderStyle.setTextOnNode(amt, BrainrotEconomy.formatCashShort(price))
					end
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
