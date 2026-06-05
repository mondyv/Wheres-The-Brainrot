-- [ACTIVE] ChatTagsController
--[[
	ChatTagsController
	Client-only stacked chat prefixes for group ranks + VIP gamepass.

	Uses TextChatService.OnIncomingMessage (assign directly — never read it back).
	Results are cached per UserId so group rank / gamepass checks run once per player.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))

local GROUP_ID = 34716703
local VIP_GAMEPASS_ID = StoreConfig.GAMEPASS.VIP

local TAGS = {
	OWNER = "<font color='rgb(60,0,0)'><b>[</b></font><font color='rgb(140,0,0)'><b>O</b></font><font color='rgb(220,0,0)'><b>W</b></font><font color='rgb(255,60,20)'><b>N</b></font><font color='rgb(255,140,40)'><b>E</b></font><font color='rgb(255,60,20)'><b>R</b></font><font color='rgb(140,0,0)'><b>]</b></font>",

	FOUNDER = "<font color='rgb(180,0,255)'><b>[</b></font><font color='rgb(190,30,255)'><b>O</b></font><font color='rgb(210,60,240)'><b>W</b></font><font color='rgb(225,80,220)'><b>N</b></font><font color='rgb(235,100,200)'><b>E</b></font><font color='rgb(200,40,255)'><b>R</b></font><font color='rgb(180,0,255)'><b>]</b></font>",

	CONTRIBUTOR = "<font color='rgb(0,220,255)'><b>[</b></font><font color='rgb(0,230,240)'><b>C</b></font><font color='rgb(0,235,220)'><b>O</b></font><font color='rgb(0,240,200)'><b>N</b></font><font color='rgb(0,235,180)'><b>T</b></font><font color='rgb(0,230,200)'><b>R</b></font><font color='rgb(0,225,220)'><b>I</b></font><font color='rgb(0,220,240)'><b>B</b></font><font color='rgb(0,215,255)'><b>]</b></font>",

	TESTER = "<font color='rgb(50,255,100)'><b>[</b></font><font color='rgb(80,255,80)'><b>T</b></font><font color='rgb(120,255,60)'><b>E</b></font><font color='rgb(160,255,40)'><b>S</b></font><font color='rgb(180,240,30)'><b>T</b></font><font color='rgb(160,255,40)'><b>E</b></font><font color='rgb(100,255,70)'><b>R</b></font><font color='rgb(50,255,100)'><b>]</b></font>",

	VIP = "<font color='rgb(255,180,0)'><b>[</b></font><font color='rgb(255,200,20)'><b>V</b></font><font color='rgb(255,220,40)'><b>I</b></font><font color='rgb(255,210,20)'><b>P</b></font><font color='rgb(255,180,0)'><b>]</b></font>",
}

local RANK_TAGS: { [number]: string } = {
	[255] = TAGS.OWNER,
	[254] = TAGS.FOUNDER,
	[5] = TAGS.CONTRIBUTOR,
	[2] = TAGS.TESTER,
}

local ChatTagsController = {}

-- [userId] = concatenated prefix string (may be "" if no tags).
local tagCache: { [number]: string } = {}

local function clearTagCache(userId: number)
	tagCache[userId] = nil
end

local function getTagsForPlayer(plr: Player): string
	local cached = tagCache[plr.UserId]
	if cached ~= nil then
		return cached
	end

	local tagParts: { string } = {}

	local rankOk, rank = pcall(function()
		return plr:GetRankInGroup(GROUP_ID)
	end)
	if not rankOk then
		warn("[ChatTagsController] GetRankInGroup failed:", rank)
	end
	if rankOk and typeof(rank) == "number" and RANK_TAGS[rank] then
		table.insert(tagParts, RANK_TAGS[rank])
	end

	local ownsVip = plr:GetAttribute(StoreConfig.ATTR.VIP_OWNED) == true
	if not ownsVip then
		local vipOk, ownsVIP = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(plr.UserId, VIP_GAMEPASS_ID)
		end)
		if not vipOk then
			warn("[ChatTagsController] UserOwnsGamePassAsync failed:", ownsVIP)
		end
		ownsVip = vipOk and ownsVIP == true
	end
	if ownsVip then
		table.insert(tagParts, TAGS.VIP)
	end

	local result = table.concat(tagParts, " ")
	tagCache[plr.UserId] = result
	return result
end

local function bindCacheInvalidation(plr: Player)
	plr:GetAttributeChangedSignal(StoreConfig.ATTR.VIP_OWNED):Connect(function()
		clearTagCache(plr.UserId)
	end)
end

local function init()
	TextChatService.OnIncomingMessage = function(message: TextChatMessage)
		local props = Instance.new("TextChatMessageProperties")

		local source = message.TextSource
		if not source then
			return props
		end

		local plr = Players:GetPlayerByUserId(source.UserId)
		if not plr then
			return props
		end

		local tags = getTagsForPlayer(plr)
		if tags ~= "" then
			props.PrefixText = tags .. " " .. message.PrefixText
		end

		return props
	end

	Players.PlayerRemoving:Connect(function(plr)
		clearTagCache(plr.UserId)
	end)

	Players.PlayerAdded:Connect(bindCacheInvalidation)
	for _, plr in Players:GetPlayers() do
		bindCacheInvalidation(plr)
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, gamePassId, wasPurchased)
		if wasPurchased and gamePassId == VIP_GAMEPASS_ID then
			clearTagCache(plr.UserId)
		end
	end)
end

function ChatTagsController.init()
	local ok, err = pcall(init)
	if not ok then
		warn("[ChatTags] setup failed:", err)
	end
end

return ChatTagsController
