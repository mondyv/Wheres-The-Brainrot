--[[
	DailyConfig
	Shared definitions for the 7-day daily rewards calendar.

	Day 1: Free rebirth (keeps stats, like the skip gamepass).
	Day 2: +2M cash.
	Day 3: Permanent +5% cash boost (stacks via CashBoostUtil DAILY_BOOST_ATTR).
	Day 4: +1B cash.
	Day 5: Random legendary brainrot (auto-equipped).
	Day 6: +50B cash.
	Day 7: Star-Rainbow Lucky Block tool (legendary / godly / mythic roll).

	Per-day cards live under Main.Frames.Daily.Container["1".."7"].
--]]

local M = {}

M.MAX_DAY = 7
M.SKIP_ALL_GAMEPASS_ID = 3601652426

-- 20 hours between claims; first day is always claimable on first join.
M.CLAIM_COOLDOWN_SEC = 20 * 3600

-- Attribute names persisted on the player while in-session.
M.DAY_ATTR = "DailyDayClaimed"             -- last day index claimed (0 = none)
M.NEXT_AT_ATTR = "DailyNextAvailableAt"    -- os.time() epoch when next day unlocks
M.SKIP_ALL_ATTR = "DailySkipAllOwned"      -- true if Skip All gamepass owned

M.NOTIF_ATTR = "DailyHasUnclaimed"         -- mirror flag; HUD reads this for the sidebar !

export type RewardKind = "rebirth_free" | "cash" | "cash_boost_percent" | "random_legendary" | "lucky_block_star_rainbow"

export type DailyReward = {
	day: number,
	kind: RewardKind,
	-- For "cash" rewards this is the flat amount; for "cash_boost_percent" it's the percent.
	amount: number?,
	displayAmount: string?,
	displayName: string?,
	-- Optional rarity that styles the card (Day 5 → legendary, Day 7 → galaxy / lucky)
	specialStyle: string?,
}

M.REWARDS = {
	{
		day = 1,
		kind = "rebirth_free",
		displayAmount = "+1",
		displayName = "Free Rebirth",
	},
	{
		day = 2,
		kind = "cash",
		amount = 2_000_000,
		displayAmount = "+2M",
		displayName = "Cash",
	},
	{
		day = 3,
		kind = "cash_boost_percent",
		amount = 5,
		displayAmount = "+5%",
		displayName = "Cash Boost",
	},
	{
		day = 4,
		kind = "cash",
		amount = 1_000_000_000,
		displayAmount = "+1B",
		displayName = "Cash",
	},
	{
		day = 5,
		kind = "random_legendary",
		displayAmount = "???",
		displayName = "Legendary Brainrot",
		specialStyle = "legendary",
	},
	{
		day = 6,
		kind = "cash",
		amount = 50_000_000_000,
		displayAmount = "+50B",
		displayName = "Cash",
	},
	{
		day = 7,
		kind = "lucky_block_star_rainbow",
		displayAmount = "+1 LB",
		displayName = "Lucky Block",
		specialStyle = "galaxy",
	},
} :: { DailyReward }

M.REWARD_BY_DAY = {} :: { [number]: DailyReward }
for _, r in ipairs(M.REWARDS) do
	M.REWARD_BY_DAY[r.day] = r
end

-- Player → daily state snapshot for the UI.
export type DailyState = {
	currentDay: number,        -- the day that is currently claimable (0 if none yet ready)
	lastClaimedDay: number,    -- 0..MAX_DAY
	nextAvailableAt: number,   -- os.time() epoch when currentDay becomes claimable
	skipAll: boolean,
	now: number,
}

function M.buildState(player: Player): DailyState
	local last = player:GetAttribute(M.DAY_ATTR)
	local lastClaimed = if typeof(last) == "number" then math.clamp(math.floor(last), 0, M.MAX_DAY) else 0
	local nextAt = player:GetAttribute(M.NEXT_AT_ATTR)
	local nextEpoch = if typeof(nextAt) == "number" then math.floor(nextAt) else 0
	local skipAll = player:GetAttribute(M.SKIP_ALL_ATTR) == true
	local now = os.time()

	local currentDay = lastClaimed + 1
	if currentDay > M.MAX_DAY then
		currentDay = 0
	end

	return {
		currentDay = currentDay,
		lastClaimedDay = lastClaimed,
		nextAvailableAt = nextEpoch,
		skipAll = skipAll,
		now = now,
	}
end

-- Returns true if `day` is currently claimable for this player.
function M.canClaim(player: Player, day: number): boolean
	local state = M.buildState(player)
	if state.skipAll then
		return day >= 1 and day <= M.MAX_DAY and day > state.lastClaimedDay
	end
	if day ~= state.currentDay then
		return false
	end
	return state.now >= state.nextAvailableAt
end

-- Status for a single card in the UI.
export type DayStatus = "claimed" | "claim" | "locked"

function M.statusForDay(state: DailyState, day: number): DayStatus
	if day <= state.lastClaimedDay then
		return "claimed"
	end
	if state.skipAll and day > state.lastClaimedDay then
		return "claim"
	end
	if day == state.currentDay and state.now >= state.nextAvailableAt then
		return "claim"
	end
	return "locked"
end

function M.hasUnclaimedReady(state: DailyState): boolean
	if state.skipAll and state.lastClaimedDay < M.MAX_DAY then
		return true
	end
	return state.currentDay >= 1
		and state.currentDay <= M.MAX_DAY
		and state.now >= state.nextAvailableAt
end

return M
