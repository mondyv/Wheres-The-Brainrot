-- [ACTIVE] ServerChatTipsConfig
--[[
	Rotating system-chat tips (interval, Discord invite, rich-text messages).
	Update DISCORD_INVITE to your real invite link.
]]

local M = {}

M.INTERVAL_SEC = 30
M.FIRST_DELAY_SEC = 12
-- Change this to your real Discord invite (shown in chat tips).
M.DISCORD_INVITE = "discord.gg/YOURINVITE"

local function tip(emoji: string, title: string, titleRgb: string, body: string): string
	return string.format(
		"%s <font color='%s'><b>%s</b></font><font color='rgb(140,148,165)'> · </font><font color='rgb(228,232,240)'>%s</font>",
		emoji,
		titleRgb,
		title,
		body
	)
end

function M.buildMessages(): { string }
	local discord = M.DISCORD_INVITE
	return {
		tip("🎮", "ENJOYING THE GAME?", "rgb(110,200,255)", "Drop a like on the experience — it helps a ton!"),
		tip("❤️", "SUPPORT US", "rgb(255,110,140)", "Like the game & join the group for free rewards!"),
		tip("💬", "DISCORD", "rgb(120,140,255)", string.format("Join our Discord community → %s", discord)),
		tip("👥", "GROUP", "rgb(90,230,160)", "Join the group for updates, drops, and exclusive rewards!"),
		tip("⭐", "FAVORITE", "rgb(255,210,80)", "Favorite the game so you can find it again easily!"),
		tip("🤝", "FRIENDS", "rgb(255,170,90)", "Invite your friends — swing, steal, and grow together!"),
		tip("🧠", "TIP", "rgb(180,140,255)", "Upgrade brainrots on your stands for bigger $/s!"),
		tip("🚀", "TIP", "rgb(90,210,255)", "Rebirth to unlock more power, floors, and progression!"),
		tip("📢", "COMMUNITY", "rgb(120,140,255)", string.format("Codes, news & hangouts in Discord → %s", discord)),
		tip("✨", "THANKS", "rgb(255,200,120)", "Thanks for playing Where's the Brainrot — have fun out there!"),
	}
end

return M
