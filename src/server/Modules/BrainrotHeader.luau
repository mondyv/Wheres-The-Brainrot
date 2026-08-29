-- [ACTIVE] BrainrotHeader
--[[
	BrainrotHeader
	Clones ServerStorage.Templates.BrainrotHeader.BillboardGui and parents it to a brainrot part.
	Selects per-mutation / per-rarity / per-level UIGradients and fills label text.

	Studio layout (current):
	  Templates.BrainrotHeader
	    └── BillboardGui
	          └── Info (Frame) → Level, Name, Rarity, Rate, Type
--]]

local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Brainrots = require(script.Parent:WaitForChild("Brainrots"))
local HeaderStyle = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))

local M = {}

local HEADER_NAME = "BrainrotInfoBillboard"
local HEADER_TAG = "BrainrotHeaderTarget"
local _DEFAULT_BB_SIZE = UDim2.fromOffset(280, 130)

local templateCache: BillboardGui? = nil

local function scoreBillboard(bb: BillboardGui): number
	local info = bb:FindFirstChild("Info", true)
	if not info or not info:IsA("GuiObject") then
		return 0
	end
	local score = 1
	if info:FindFirstChild("Name") then
		score += 3
	end
	if info:FindFirstChild("Rarity") then
		score += 1
	end
	if info:FindFirstChild("Level") then
		score += 1
	end
	return score
end

local function findBestBillboard(root: Instance): BillboardGui?
	local best: BillboardGui? = nil
	local bestScore = 0
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("BillboardGui") then
			local s = scoreBillboard(desc)
			if s > bestScore then
				bestScore = s
				best = desc
			end
		end
	end
	if best then
		return best
	end
	local any = root:FindFirstChildWhichIsA("BillboardGui", true)
	if any and any:IsA("BillboardGui") then
		return any
	end
	return nil
end

local function fetchTemplateBillboard(): BillboardGui?
	if templateCache and templateCache.Parent then
		return templateCache
	end

	local templates = ServerStorage:FindFirstChild("Templates")
	if not templates then
		templates = ServerStorage:WaitForChild("Templates", 60)
	end
	if not templates then
		return nil
	end

	local header = templates:FindFirstChild("BrainrotHeader")
	if not header then
		warn("[BrainrotHeader] ServerStorage.Templates.BrainrotHeader missing")
		return nil
	end

	-- Prefer direct child: Templates.BrainrotHeader.BillboardGui (your current Studio layout).
	local direct = header:FindFirstChild("BillboardGui")
	if direct and direct:IsA("BillboardGui") then
		templateCache = direct
		return direct
	end

	local bb = findBestBillboard(header)
	if bb then
		templateCache = bb
		return bb
	end

	warn("[BrainrotHeader] No BillboardGui under ServerStorage.Templates.BrainrotHeader")
	return nil
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
M.formatCash = formatCash

local function formatRate(n: number): string
	return formatCash(n) .. "/s"
end
M.formatRate = formatRate

local function pickPrimaryPart(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

-- Apply per-label UIGradient selection + text.
local function applyToInfoFrame(infoFrame: Instance, data: { name: string, rarity: string, mutation: string, level: number, incomePerSecond: number })
	HeaderStyle.applyInfoFrame(infoFrame, {
		name = data.name,
		rarity = data.rarity,
		mutation = data.mutation,
		level = data.level,
		rateText = formatRate(data.incomePerSecond),
	})
end
M.applyToInfoFrame = applyToInfoFrame

local ACTIVE_ATTR = "BrainrotHeaderActive"

local function getHeaderRemote(): RemoteEvent
	local folder = ReplicatedStorage:FindFirstChild("BrainrotRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "BrainrotRemotes"
		folder.Parent = ReplicatedStorage
	end
	local ev = folder:FindFirstChild("HeaderRefresh")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "HeaderRefresh"
		ev.Parent = folder
	end
	return ev :: RemoteEvent
end

local function syncHeaderAttributes(
	model: Model,
	data: {
		name: string,
		rarity: string,
		mutation: string,
		level: number,
		incomePerSecond: number,
		luckyBlock: boolean?,
	},
	opts: { studsOffset: Vector3?, alwaysOnTop: boolean? }?
)
	local rarityDef = Brainrots.RARITY_BY_ID[data.rarity]
	local mutationDef = Brainrots.MUTATION_BY_ID[data.mutation]
	model:SetAttribute(ACTIVE_ATTR, true)
	model:SetAttribute("BrainrotHeaderName", data.name)
	model:SetAttribute("BrainrotHeaderRarity", data.rarity)
	model:SetAttribute(
		"BrainrotHeaderRarityDisplay",
		if rarityDef then rarityDef.displayName else string.upper(data.rarity)
	)
	model:SetAttribute("BrainrotHeaderMutation", data.mutation)
	model:SetAttribute(
		"BrainrotHeaderMutationDisplay",
		if mutationDef then mutationDef.displayName else data.mutation
	)
	model:SetAttribute("BrainrotHeaderLevel", data.level)
	model:SetAttribute("BrainrotHeaderIncome", data.incomePerSecond)
	model:SetAttribute("BrainrotHeaderAlwaysOnTop", if opts and opts.alwaysOnTop == true then true else true)
	if data.luckyBlock == true then
		model:SetAttribute("BrainrotHeaderLuckyBlock", true)
	else
		model:SetAttribute("BrainrotHeaderLuckyBlock", nil)
	end
end

-- Remove header (clears client via tag + attributes).
function M.remove(model: Model)
	model:SetAttribute(ACTIVE_ATTR, nil)
	if CollectionService:HasTag(model, HEADER_TAG) then
		CollectionService:RemoveTag(model, HEADER_TAG)
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BillboardGui") and d.Name == HEADER_NAME then
			d:Destroy()
		end
	end
end

--[[
	Tell clients to show the header (ReplicatedStorage template, cloned locally).
	Server does not parent BillboardGuis — they often fail to render for players.
--]]
function M.attach(
	model: Model,
	data: {
		name: string,
		rarity: string,
		mutation: string,
		level: number,
		incomePerSecond: number,
		luckyBlock: boolean?,
	},
	opts: { studsOffset: Vector3?, alwaysOnTop: boolean? }?
): boolean
	if not model or not model.Parent then
		return false
	end
	if not pickPrimaryPart(model) then
		warn("[BrainrotHeader] No BasePart on model for header:", model:GetFullName())
		return false
	end

	M.remove(model)

	-- Template is only required on the client (mirrored to ReplicatedStorage). Do not block
	-- tagging/attrs if Studio/ServerStorage is missing BillboardGui — clients still get HeaderRefresh.
	if not fetchTemplateBillboard() then
		warn("[BrainrotHeader] ServerStorage.Templates.BrainrotHeader.BillboardGui missing — clients will use fallback if needed")
	end

	syncHeaderAttributes(model, data, opts)
	CollectionService:AddTag(model, HEADER_TAG)

	-- Tell every client to build the billboard (tags/attrs alone are not reliable enough).
	task.defer(function()
		if model.Parent then
			getHeaderRemote():FireAllClients(model)
		end
	end)
	return true
end

-- Warm template cache when Templates stream in (Studio / late Rojo sync).
task.defer(function()
	local templates = ServerStorage:WaitForChild("Templates", 120)
	if not templates then
		return
	end
	local header = templates:WaitForChild("BrainrotHeader", 60)
	if header then
		fetchTemplateBillboard()
	end
end)

function M.refresh(
	model: Model,
	data: { name: string, rarity: string, mutation: string, level: number, incomePerSecond: number },
	opts: { studsOffset: Vector3?, alwaysOnTop: boolean? }?
)
	return M.attach(model, data, opts)
end

function M.find(model: Model): boolean
	return model:GetAttribute(ACTIVE_ATTR) == true
end

return M
