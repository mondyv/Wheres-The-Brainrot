-- [ACTIVE] MainGradientButtons
--[[
	Shared buy-button visuals using Main.Purchased (or Main.GameGradients.Purchased).
--]]

local Players = game:GetService("Players")

local MainGradientButtons = {}

local PURCHASED_CLONE = "_MainPurchasedGradient"
local BUY_TEXT_NAMES = { "Name", "Text", "Cost", "Robux", "Price", "Label" }

local purchasedTemplate: UIGradient? = nil
local purchasedTextByHost: { [GuiObject]: string } = {}
local priceIconVisibleByHost: { [GuiObject]: { [GuiObject]: boolean } } = {}
local missingTemplateWarned = false

local function setAllGradientsEnabled(root: Instance, enabled: boolean)
	if root:IsA("UIGradient") then
		(root :: UIGradient).Enabled = enabled
	end
	for _, d in root:GetDescendants() do
		if d:IsA("UIGradient") then
			(d :: UIGradient).Enabled = enabled
		end
	end
end

local function isDecorVisualLabel(label: Instance): boolean
	local p = label.Parent
	while p do
		if p.Name == "Highlight" or p.Name == "On" or p.Name == "Off" then
			return true
		end
		p = p.Parent
	end
	return false
end

local function findBuyTextLabel(buyHost: GuiObject): TextLabel?
	local info = buyHost:FindFirstChild("Info")
	if info then
		local price = info:FindFirstChild("Price")
		if price and (price:IsA("TextLabel") or price:IsA("TextButton")) then
			return price :: TextLabel
		end
	end
	for _, name in BUY_TEXT_NAMES do
		local node = buyHost:FindFirstChild(name, true)
		if node and (node:IsA("TextLabel") or node:IsA("TextButton")) and not isDecorVisualLabel(node) then
			return node :: TextLabel
		end
	end
	for _, d in buyHost:GetDescendants() do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and not isDecorVisualLabel(d) then
			return d :: TextLabel
		end
	end
	return nil
end

local function forEachBuyPriceIcon(buyHost: GuiObject, visit: (GuiObject) -> ())
	local info = buyHost:FindFirstChild("Info")
	if info then
		local icon = info:FindFirstChild("ImageLabel")
		if icon and icon:IsA("GuiObject") then
			visit(icon :: GuiObject)
		end
	end
	local price = buyHost:FindFirstChild("Price", true)
	if price then
		local nestedIcon = price:FindFirstChild("ImageLabel")
		if nestedIcon and nestedIcon:IsA("GuiObject") then
			visit(nestedIcon :: GuiObject)
		end
	end
end

local function setPriceRobuxIconsVisible(buyHost: GuiObject, visible: boolean)
	forEachBuyPriceIcon(buyHost, function(icon)
		local cache = priceIconVisibleByHost[buyHost]
		if not cache then
			cache = {}
			priceIconVisibleByHost[buyHost] = cache
		end
		if cache[icon] == nil then
			cache[icon] = icon.Visible
		end
		icon.Visible = visible
	end)
end

local function restorePriceRobuxIcons(buyHost: GuiObject)
	local cache = priceIconVisibleByHost[buyHost]
	if not cache then
		return
	end
	for icon, wasVisible in cache do
		if icon.Parent then
			icon.Visible = wasVisible
		end
	end
	priceIconVisibleByHost[buyHost] = nil
end

local function clearCloneGradients(parent: Instance)
	local existing = parent:FindFirstChild(PURCHASED_CLONE)
	if existing then
		existing:Destroy()
	end
end

local function asPurchasedGradient(node: Instance?): UIGradient?
	if not node then
		return nil
	end
	if node:IsA("UIGradient") then
		return node
	end
	local nested = node:FindFirstChildWhichIsA("UIGradient")
	if nested then
		return nested
	end
	return nil
end

local function findPurchasedTemplate(main: ScreenGui): UIGradient?
	local gradientsFolder = main:FindFirstChild("GameGradients")
	if gradientsFolder then
		local nested = asPurchasedGradient(gradientsFolder:FindFirstChild("Purchased"))
		if nested then
			return nested
		end
		-- Case / alternate names sometimes used in Studio.
		for _, child in gradientsFolder:GetChildren() do
			if string.lower(child.Name) == "purchased" then
				local g = asPurchasedGradient(child)
				if g then
					return g
				end
			end
		end
	end
	local direct = asPurchasedGradient(main:FindFirstChild("Purchased"))
	if direct then
		return direct
	end
	for _, d in main:GetDescendants() do
		if d:IsA("UIGradient") and string.lower(d.Name) == "purchased" then
			return d
		end
	end
	return nil
end

local function applyTemplateToTargets(buyHost: GuiObject, template: UIGradient?, cloneName: string)
	if not template then
		return
	end
	local targets: { Instance } = { buyHost }
	local decor = buyHost:FindFirstChild("Decor")
	if decor then
		local stud = decor:FindFirstChild("Stud")
		if stud then
			table.insert(targets, stud)
		end
		local shadow = decor:FindFirstChild("Shadow")
		if shadow then
			table.insert(targets, shadow)
		end
	end
	for _, target in targets do
		clearCloneGradients(target)
		setAllGradientsEnabled(target, false)
		local clone = template:Clone()
		clone.Name = cloneName
		clone.Enabled = true
		clone.Parent = target
	end
end

local function hideHighlightOn(buyHost: GuiObject)
	local decor = buyHost:FindFirstChild("Decor")
	local highlight = decor and decor:FindFirstChild("Highlight")
	local on = highlight and highlight:FindFirstChild("On")
	if on and on:IsA("GuiObject") then
		(on :: GuiObject).Visible = false
	end
end

local function warnMissingOnce(context: string)
	if missingTemplateWarned then
		return
	end
	missingTemplateWarned = true
	warn("[MainGradientButtons]", context, "— add UIGradient Purchased under Main or Main.GameGradients")
end

local function ensureTemplate(main: ScreenGui?): UIGradient?
	if purchasedTemplate and purchasedTemplate.Parent then
		return purchasedTemplate
	end
	if main then
		local found = findPurchasedTemplate(main)
		if found then
			purchasedTemplate = found
			found.Enabled = false
			return found
		end
	end
	local plr = Players.LocalPlayer
	local pg = plr and plr:FindFirstChildOfClass("PlayerGui")
	local gui = pg and pg:FindFirstChild("Main")
	if gui and gui:IsA("ScreenGui") then
		local found = findPurchasedTemplate(gui)
		if found then
			purchasedTemplate = found
			found.Enabled = false
			return found
		end
	end
	return nil
end

function MainGradientButtons.init(main: ScreenGui)
	local purchased = findPurchasedTemplate(main)
	if not purchased then
		local gradientsFolder = main:WaitForChild("GameGradients", 8)
		if gradientsFolder then
			local nested = gradientsFolder:WaitForChild("Purchased", 5)
			purchased = asPurchasedGradient(nested)
		end
		if not purchased then
			local direct = main:WaitForChild("Purchased", 5)
			purchased = asPurchasedGradient(direct)
		end
		if not purchased then
			purchased = findPurchasedTemplate(main)
		end
	end
	if purchased then
		purchasedTemplate = purchased
		purchased.Enabled = false
	else
		purchasedTemplate = nil
		warnMissingOnce("Purchased UIGradient missing under Main or Main.GameGradients")
	end
end

function MainGradientButtons.getPurchasedTemplate(): UIGradient?
	return purchasedTemplate
end

function MainGradientButtons.applyDefault(buyHost: GuiObject)
	local targets: { Instance } = { buyHost }
	local decor = buyHost:FindFirstChild("Decor")
	if decor then
		local stud = decor:FindFirstChild("Stud")
		if stud then
			table.insert(targets, stud)
		end
		local shadow = decor:FindFirstChild("Shadow")
		if shadow then
			table.insert(targets, shadow)
		end
	end
	for _, target in targets do
		clearCloneGradients(target)
		setAllGradientsEnabled(target, true)
	end
	local label = findBuyTextLabel(buyHost)
	if label and purchasedTextByHost[buyHost] then
		label.Text = purchasedTextByHost[buyHost]
		purchasedTextByHost[buyHost] = nil
	end
	restorePriceRobuxIcons(buyHost)
end

function MainGradientButtons.applyPurchasedGradient(buyHost: GuiObject)
	local template = ensureTemplate(nil)
	if not template then
		warnMissingOnce("applyPurchasedGradient skipped — template missing")
		return
	end
	applyTemplateToTargets(buyHost, template, PURCHASED_CLONE)
end

function MainGradientButtons.applyPurchased(buyHost: GuiObject, text: string?)
	local template = ensureTemplate(nil)
	if not template then
		-- Still flip label / hide robux so purchased state is readable without gradient.
		warnMissingOnce("applyPurchased skipped — template missing")
		setPriceRobuxIconsVisible(buyHost, false)
		local label = findBuyTextLabel(buyHost)
		if label then
			if purchasedTextByHost[buyHost] == nil then
				purchasedTextByHost[buyHost] = label.Text
			end
			label.Text = text or "Purchased"
		end
		hideHighlightOn(buyHost)
		return
	end
	MainGradientButtons.applyPurchasedGradient(buyHost)
	setPriceRobuxIconsVisible(buyHost, false)
	local label = findBuyTextLabel(buyHost)
	if label then
		if purchasedTextByHost[buyHost] == nil then
			purchasedTextByHost[buyHost] = label.Text
		end
		label.Text = text or "Purchased"
	end
	hideHighlightOn(buyHost)
end

return MainGradientButtons
