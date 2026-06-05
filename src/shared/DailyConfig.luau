-- [ACTIVE] DailyConfig
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
M.SKIP_ALL_DEV_PRODUCT_ID = 3601652426

-- 20 hours between claims; first day is always claimable on first join.
M.CLAIM_COOLDOWN_SEC = 20 * 3600

-- Attribute names persisted on the player while in-session.
M.DAY_ATTR = "DailyDayClaimed"             -- last sequential day claimed (normal flow)
M.CLAIMED_MASK_ATTR = "DailyClaimedMask"   -- bit mask: day N claimed => bit (N-1) set
M.NEXT_AT_ATTR = "DailyNextAvailableAt"    -- os.time() epoch when next day unlocks
M.SKIP_ALL_ATTR = "DailySkipAllOwned"      -- true if Skip All dev product purchased

M.NOTIF_ATTR = "DailyHasUnclaimed"         -- mirror flag; HUD reads this for the sidebar !

export type RewardKind = "rebirth_free" | "cash" | "cash_boost_percent" | "random_legendary" | "lucky_block_star_rainbow"

export type DailyReward = {
	day: number,
	kind: RewardKind,
	amount: number?,
	displayAmount: string?,
	displayName: string?,
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

export type DailyState = {
	currentDay: number,
	lastClaimedDay: number,
	claimedMask: number,
	nextAvailableAt: number,
	skipAll: boolean,
	now: number,
}

local function dayBit(day: number): number
	return bit32.lshift(1, day - 1)
end

function M.getClaimedMask(player: Player): number
	local raw = player:GetAttribute(M.CLAIMED_MASK_ATTR)
	return if typeof(raw) == "number" then math.floor(raw) else 0
end

function M.isDayClaimedMask(mask: number, day: number): boolean
	if day < 1 or day > M.MAX_DAY then
		return false
	end
	return bit32.band(mask, dayBit(day)) ~= 0
end

function M.isDayClaimed(player: Player, day: number): boolean
	return M.isDayClaimedMask(M.getClaimedMask(player), day)
end

function M.countClaimedDays(mask: number): number
	local count = 0
	for day = 1, M.MAX_DAY do
		if M.isDayClaimedMask(mask, day) then
			count += 1
		end
	end
	return count
end

function M.nextUnclaimedDay(mask: number): number
	for day = 1, M.MAX_DAY do
		if not M.isDayClaimedMask(mask, day) then
			return day
		end
	end
	return 0
end

function M.highestSequentialClaimed(mask: number): number
	local highest = 0
	for day = 1, M.MAX_DAY do
		if M.isDayClaimedMask(mask, day) then
			highest = day
		else
			break
		end
	end
	return highest
end

function M.buildState(player: Player): DailyState
	local mask = M.getClaimedMask(player)
	local last = player:GetAttribute(M.DAY_ATTR)
	local lastClaimed = if typeof(last) == "number" then math.clamp(math.floor(last), 0, M.MAX_DAY) else 0
	local nextAt = player:GetAttribute(M.NEXT_AT_ATTR)
	local nextEpoch = if typeof(nextAt) == "number" then math.floor(nextAt) else 0
	local skipAll = player:GetAttribute(M.SKIP_ALL_ATTR) == true
	local now = os.time()

	local currentDay = M.nextUnclaimedDay(mask)
	if currentDay == 0 then
		currentDay = 0
	end

	return {
		currentDay = currentDay,
		lastClaimedDay = math.max(lastClaimed, M.highestSequentialClaimed(mask)),
		claimedMask = mask,
		nextAvailableAt = nextEpoch,
		skipAll = skipAll,
		now = now,
	}
end

function M.canClaim(player: Player, day: number): boolean
	if day < 1 or day > M.MAX_DAY then
		return false
	end
	if M.isDayClaimed(player, day) then
		return false
	end

	local state = M.buildState(player)
	if state.skipAll then
		return true
	end

	if day ~= state.currentDay then
		return false
	end
	return state.now >= state.nextAvailableAt
end

export type DayStatus = "claimed" | "claim" | "locked"

function M.statusForDay(state: DailyState, day: number): DayStatus
	if M.isDayClaimedMask(state.claimedMask, day) then
		return "claimed"
	end
	if state.skipAll then
		return "claim"
	end
	if day == state.currentDay and state.now >= state.nextAvailableAt then
		return "claim"
	end
	return "locked"
end

function M.hasUnclaimedReady(state: DailyState): boolean
	if state.skipAll then
		return M.countClaimedDays(state.claimedMask) < M.MAX_DAY
	end
	return state.currentDay >= 1
		and state.currentDay <= M.MAX_DAY
		and state.now >= state.nextAvailableAt
end

function M.markDayClaimed(player: Player, day: number)
	local mask = M.getClaimedMask(player)
	player:SetAttribute(M.CLAIMED_MASK_ATTR, bit32.bor(mask, dayBit(day)))
	if player:GetAttribute(M.SKIP_ALL_ATTR) ~= true then
		player:SetAttribute(M.DAY_ATTR, day)
	end
end

return M
