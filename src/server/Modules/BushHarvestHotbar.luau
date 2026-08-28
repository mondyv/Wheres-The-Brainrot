-- [ACTIVE] BushHarvestHotbar
--[[
	Hotbar / parked-slot helpers extracted from BushHarvest.server so the main
	script stays under Luau's 200 local register limit.
]]

local BushHarvestBrainrotEquip = require(script.Parent:WaitForChild("BushHarvestBrainrotEquip"))

local M = {}

local HOTBAR_UI_SLOTS = 9

export type BrainrotInvEntry = {
	name: string,
	icon: string,
	sourcePath: string,
	rarity: string,
	mutation: string,
	level: number,
	baseIncome: number,
}

export type BootDeps = {
	brainrotInventories: { [Player]: { BrainrotInvEntry } },
	brainrotParkedInExpandedBackpack: { [Player]: { [number]: boolean } },
	brainrotHotbarSlots: { [Player]: { [number]: number } },
	getBushRemotesFolder: () -> Folder,
	ensureInventoryRemotes: () -> RemoteEvent,
	packInventoryForClient: (Player, { BrainrotInvEntry }, number?) -> any,
	MAX_BRAINROT_INVENTORY_CAPACITY: number,
}

export type Api = {
	HOTBAR_UI_SLOTS: number,
	shiftParkedMapAfterListRemove: ({ [number]: boolean }, number) -> (),
	findLowestFreeHotbarSlot: (Player, { BrainrotInvEntry }, { [number]: boolean }) -> number?,
	assignEntryToLowestFreeHotbarSlot: (Player, { BrainrotInvEntry }, { [number]: boolean }, number) -> number?,
	ensureEquipBrainrotRemote: () -> RemoteEvent,
	destroyAllBrainrotToolsForPlayer: (Player) -> (),
}

function M.boot(deps: BootDeps): Api
	local destroyAllBrainrotToolsForPlayer = BushHarvestBrainrotEquip.destroyAllBrainrotToolsForPlayer

	local function shiftParkedMapAfterListRemove(m: { [number]: boolean }, removedIdx: number)
		local prev: { [number]: boolean } = {}
		for k = 1, HOTBAR_UI_SLOTS do
			if m[k] then
				prev[k] = true
			end
		end
		for k = 1, HOTBAR_UI_SLOTS do
			m[k] = nil
		end
		for k = 1, HOTBAR_UI_SLOTS do
			if prev[k] then
				if k < removedIdx then
					m[k] = true
				elseif k > removedIdx then
					m[k - 1] = true
				end
			end
		end
	end

	local function getHotbarSlotMap(plr: Player): { [number]: number }
		local m = deps.brainrotHotbarSlots[plr]
		if not m then
			m = {}
			deps.brainrotHotbarSlots[plr] = m
		end
		return m
	end

	local function explicitInventoryIndexForHotbarSlot(
		slotMap: { [number]: number },
		slot: number,
		list: { BrainrotInvEntry }
	): number?
		for idx, mappedSlot in pairs(slotMap) do
			if typeof(idx) == "number" and typeof(mappedSlot) == "number" then
				local i = math.floor(idx)
				local s = math.floor(mappedSlot)
				if i >= 1 and list[i] ~= nil and s == slot then
					return i
				end
			end
		end
		return nil
	end

	local function inventoryIndexForHotbarSlot(
		plr: Player,
		list: { BrainrotInvEntry },
		map: { [number]: boolean },
		slot: number
	): number?
		if slot < 1 or slot > HOTBAR_UI_SLOTS then
			return nil
		end
		local slotMap = getHotbarSlotMap(plr)
		local explicit = explicitInventoryIndexForHotbarSlot(slotMap, slot, list)
		if explicit then
			return explicit
		end
		-- Default legacy behavior: inventory index 1..9 appears in the matching hotbar
		-- slot unless it was tucked or explicitly moved elsewhere.
		if list[slot] ~= nil and map[slot] ~= true and slotMap[slot] == nil then
			return slot
		end
		return nil
	end

	local function isHotbarSlotVisuallyFree(
		plr: Player,
		list: { BrainrotInvEntry },
		map: { [number]: boolean },
		slot: number
	): boolean
		return inventoryIndexForHotbarSlot(plr, list, map, slot) == nil
	end

	local function findLowestFreeHotbarSlot(
		plr: Player,
		list: { BrainrotInvEntry },
		map: { [number]: boolean }
	): number?
		for i = 2, HOTBAR_UI_SLOTS do
			if isHotbarSlotVisuallyFree(plr, list, map, i) then
				return i
			end
		end
		return nil
	end

	local function moveInventoryEntryToExactHotbarSlot(
		plr: Player,
		list: { BrainrotInvEntry },
		map: { [number]: boolean },
		srcIdx: number,
		targetSlot: number
	): boolean
		if not list[srcIdx] then
			return false
		end

		local target = math.clamp(math.floor(targetSlot), 1, HOTBAR_UI_SLOTS)
		local slotMap = getHotbarSlotMap(plr)
		local oldSlot = slotMap[srcIdx]
		if typeof(oldSlot) ~= "number" and srcIdx >= 1 and srcIdx <= HOTBAR_UI_SLOTS and map[srcIdx] ~= true then
			oldSlot = srcIdx
		end

		local displacedIdx = inventoryIndexForHotbarSlot(plr, list, map, target)
		if displacedIdx and displacedIdx ~= srcIdx then
			-- Swap when the dragged brainrot came from another visible hotbar slot.
			-- Otherwise, push the displaced brainrot into the backpack so drops from the
			-- backpack onto an occupied slot behave like replace/tuck instead of duping.
			if oldSlot and oldSlot >= 1 and oldSlot <= HOTBAR_UI_SLOTS then
				slotMap[displacedIdx] = oldSlot
				map[displacedIdx] = nil
			else
				slotMap[displacedIdx] = nil
				if displacedIdx <= HOTBAR_UI_SLOTS then
					map[displacedIdx] = true
				end
			end
		end

		-- If this item used to rely on its default matching index, make the custom
		-- slot explicit. This is what allows index 3 to live in hotbar slot 8.
		slotMap[srcIdx] = target
		map[srcIdx] = nil
		destroyAllBrainrotToolsForPlayer(plr)
		return true
	end

	local function assignEntryToLowestFreeHotbarSlot(
		plr: Player,
		list: { BrainrotInvEntry },
		map: { [number]: boolean },
		srcIdx: number
	): number?
		if not list[srcIdx] then
			return nil
		end
		local currentSlot = nil
		for s = 1, HOTBAR_UI_SLOTS do
			if inventoryIndexForHotbarSlot(plr, list, map, s) == srcIdx then
				currentSlot = s
				break
			end
		end
		if currentSlot and map[srcIdx] ~= true then
			return currentSlot
		end
		local destSlot = findLowestFreeHotbarSlot(plr, list, map)
		if not destSlot then
			local candidates: { number } = {}
			for s = 2, HOTBAR_UI_SLOTS do
				local occupied = inventoryIndexForHotbarSlot(plr, list, map, s)
				if occupied and occupied ~= srcIdx then
					table.insert(candidates, s)
				end
			end
			if #candidates > 0 then
				destSlot = candidates[math.random(1, #candidates)]
				local displacedIdx = inventoryIndexForHotbarSlot(plr, list, map, destSlot)
				if displacedIdx then
					local slotMap = getHotbarSlotMap(plr)
					slotMap[displacedIdx] = nil
					map[displacedIdx] = true
				end
			end
		end
		if not destSlot then
			return nil
		end
		if moveInventoryEntryToExactHotbarSlot(plr, list, map, srcIdx, destSlot) then
			return destSlot
		end
		return nil
	end

	local function ensureBrainrotParkedRemote(): RemoteEvent
		local folder = deps.getBushRemotesFolder()
		local ev = folder:FindFirstChild("BrainrotSetParkedSlot")
		if not ev then
			ev = Instance.new("RemoteEvent")
			ev.Name = "BrainrotSetParkedSlot"
			ev.Parent = folder
		end
		return ev :: RemoteEvent
	end

	--[[
		BrainrotSetParkedSlot(srcIdx, tuck, targetSlot?, backpackDestIdx?)
		  srcIdx          : 1..MAX — inventory index of the item being dragged.
		  tuck            : true → tuck off hotbar; false → untuck / move.
		  targetSlot      : 1..9 hotbar slot when moving onto the hotbar.
		  backpackDestIdx : optional insert index for backpack moves.
	]]
	local function normalizeBrainrotParkedMap(map: { [number]: boolean }, list: { BrainrotInvEntry })
		for slot in pairs(map) do
			if typeof(slot) ~= "number" or slot < 1 or slot > HOTBAR_UI_SLOTS or list[slot] == nil then
				map[slot] = nil
			end
		end
	end

	local function setBrainrotSlotTucked(
		map: { [number]: boolean },
		list: { BrainrotInvEntry },
		slot: number,
		tucked: boolean
	)
		if slot < 1 or slot > HOTBAR_UI_SLOTS then
			return
		end
		if list[slot] == nil then
			map[slot] = nil
			return
		end
		if tucked then
			map[slot] = true
		else
			map[slot] = nil
		end
	end

	ensureBrainrotParkedRemote().OnServerEvent:Connect(
		function(plr: Player, idx: any, parked: any, targetSlot: any?, backpackDestIdx: any?)
			if typeof(idx) ~= "number" or typeof(parked) ~= "boolean" then
				return
			end
			local i = math.floor(idx)
			if i < 1 or i > deps.MAX_BRAINROT_INVENTORY_CAPACITY then
				return
			end
			local list = deps.brainrotInventories[plr]
			if not list or not list[i] then
				return
			end
			local map = deps.brainrotParkedInExpandedBackpack[plr]
			if not map then
				map = {}
				deps.brainrotParkedInExpandedBackpack[plr] = map
			end

			local changed = false
			if parked then
				local char = plr.Character
				if char and i <= HOTBAR_UI_SLOTS then
					local hum = char:FindFirstChildOfClass("Humanoid")
					local t = char:FindFirstChildOfClass("Tool")
					if hum and t and t:IsA("Tool") and t:GetAttribute("BrainrotTool") == true then
						local a = t:GetAttribute("BrainrotInvIndex")
						if typeof(a) == "number" and math.floor(a) == i then
							hum:UnequipTools()
						end
					end
				end
				getHotbarSlotMap(plr)[i] = nil
				if i <= HOTBAR_UI_SLOTS then
					setBrainrotSlotTucked(map, list, i, true)
				end
				changed = true
				destroyAllBrainrotToolsForPlayer(plr)
			else
				if typeof(backpackDestIdx) == "number" then
					getHotbarSlotMap(plr)[i] = nil
					if i <= HOTBAR_UI_SLOTS then
						setBrainrotSlotTucked(map, list, i, true)
					end
					changed = true
					destroyAllBrainrotToolsForPlayer(plr)
				elseif typeof(targetSlot) == "number" then
					changed = moveInventoryEntryToExactHotbarSlot(plr, list, map, i, targetSlot :: number)
				else
					changed = assignEntryToLowestFreeHotbarSlot(plr, list, map, i) ~= nil
				end
			end

			if changed then
				normalizeBrainrotParkedMap(map, list)
				plr:SetAttribute("BrainrotCount", #list)
			end

			local sync = deps.ensureInventoryRemotes()
			sync:FireClient(plr, deps.packInventoryForClient(plr, list))
		end
	)

	local function ensureEquipBrainrotRemote(): RemoteEvent
		local folder = deps.getBushRemotesFolder()
		local ev = folder:FindFirstChild("EquipBrainrotSlot")
		if not ev then
			ev = Instance.new("RemoteEvent")
			ev.Name = "EquipBrainrotSlot"
			ev.Parent = folder
		end
		return ev :: RemoteEvent
	end

	return {
		HOTBAR_UI_SLOTS = HOTBAR_UI_SLOTS,
		shiftParkedMapAfterListRemove = shiftParkedMapAfterListRemove,
		findLowestFreeHotbarSlot = findLowestFreeHotbarSlot,
		assignEntryToLowestFreeHotbarSlot = assignEntryToLowestFreeHotbarSlot,
		ensureEquipBrainrotRemote = ensureEquipBrainrotRemote,
		destroyAllBrainrotToolsForPlayer = destroyAllBrainrotToolsForPlayer,
	}
end

return M
