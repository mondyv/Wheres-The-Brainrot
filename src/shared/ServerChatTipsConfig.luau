-- [ACTIVE] ServerChatTipsConfig
--[[
	Rotating system-chat tips (interval, Discord invite, rich-text messages).
]]

local M = {}

M.INTERVAL_SEC = 5 * 60
M.FIRST_DELAY_SEC = 45
M.DISCORD_INVITE = "discord.gg/WfsqEkW75C"

local function tip(title: string, titleRgb: string, body: string): string
	return string.format(
		"<font color='%s'><b>%s</b></font><font color='rgb(140,148,165)'> · </font><font color='rgb(228,232,240)'>%s</font>",
		titleRgb,
		title,
		body
	)
end

function M.buildMessages(): { string }
	local discord = M.DISCORD_INVITE
	return {
		tip("ENJOYING THE GAME?", "rgb(110,200,255)", "Like the experience — it really helps us keep updates coming!"),
		tip("SUPPORT US", "rgb(255,110,140)", "Like the game and join the group for free rewards!"),
		tip("DISCORD", "rgb(120,140,255)", string.format("Hang with the community → %s", discord)),
		tip("GROUP", "rgb(90,230,160)", "Join the group for drops, news, and exclusive rewards!"),
		tip("FAVORITE", "rgb(255,210,80)", "Favorite the game so you can jump back in anytime!"),
		tip("FRIENDS", "rgb(255,170,90)", "Bring friends — more plots, more swings, more brainrots!"),
		tip("TIP", "rgb(180,140,255)", "Upgrade the brainrots on your stands to stack bigger $/s!"),
		tip("TIP", "rgb(90,210,255)", "Rebirth to unlock more floors, luck, and progression!"),
		tip("TIP", "rgb(255,170,70)", "Working out? Hit the combo button — it stacks all the way to 50!"),
		tip("TIP", "rgb(90,230,190)", "Search bushes for brainrots. Lucky blocks start dropping after the tutorial!"),
		tip("TIP", "rgb(255,120,160)", "Claim a brainrot? Race home — a wave web chase is coming!"),
		tip("CONTROLLER", "rgb(120,200,255)", "On controller: inventory with Y / △, accept claims with A / ✕, decline with B / ○."),
		tip("COMMUNITY", "rgb(120,140,255)", string.format("Codes, news & hangouts in Discord → %s", discord)),
		tip("THANKS", "rgb(255,200,120)", "Thanks for playing Where's the Brainrot — go find those brainrots!"),
	}
end

return M
