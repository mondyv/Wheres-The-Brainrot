-- [ACTIVE] CarryGate
-- Client carry capacity checks (bushes, prompt UI, etc.)
local Players = game:GetService("Players")

local player = Players.LocalPlayer

local CarryGate = {}

local function carryCapacity(): number
	local cap = player:GetAttribute("Carry")
	return if typeof(cap) == "number" then math.max(1, math.floor(cap)) else 1
end

local function countOnCharacter(char: Model): number
	local models = 0
	local hasCarryWeld = false
	for _, d in char:GetDescendants() do
		if d:IsA("Model") then
			local phase = d:GetAttribute("BrainrotCarryPhase")
			if phase == "Carried" or phase == "Floating" or phase == "Pop" then
				models += 1
			elseif d:GetAttribute("BrainrotName") ~= nil and d.Parent == char then
				models += 1
			end
		elseif d:IsA("WeldConstraint") and d.Name == "BrainrotCarryWeld" then
			hasCarryWeld = true
		end
	end
	if models > 0 then
		return models
	end
	return if hasCarryWeld then 1 else 0
end

local function _countBrainrotTools(container: Instance?): number
	if not container then
		return 0
	end
	local n = 0
	for _, ch in container:GetChildren() do
		if ch:IsA("Tool") and ch:GetAttribute("BrainrotTool") == true then
			n += 1
		end
	end
	return n
end

-- Bush haul slots only (floating / head carry). Equipped inventory tools do not count.
function CarryGate.usedSlots(): number
	local n = 0
	local cnt = player:GetAttribute("BrainrotCarryCount")
	if typeof(cnt) == "number" then
		n = math.floor(cnt)
	end
	local char = player.Character
	if char then
		n = math.max(n, countOnCharacter(char))
	end
	return n
end

function CarryGate.isFull(): boolean
	return CarryGate.usedSlots() >= carryCapacity()
end

-- True when any brainrot is on the character (floating, carried on head, etc.).
function CarryGate.isCarrying(): boolean
	if CarryGate.usedSlots() > 0 then
		return true
	end
	local char = player.Character
	if not char then
		return false
	end
	for _, d in char:GetDescendants() do
		if d:IsA("Model") then
			local phase = d:GetAttribute("BrainrotCarryPhase")
			if phase == "Carried" or phase == "Floating" or phase == "Pop" then
				return true
			end
			local owner = d:GetAttribute("OwnerUserId")
			if typeof(owner) == "number" and owner == player.UserId and d.Parent == char then
				return true
			end
		elseif d:IsA("WeldConstraint") and d.Name == "BrainrotCarryWeld" then
			return true
		end
	end
	-- Carried brainrot can be a direct child of the character rig.
	for _, child in char:GetChildren() do
		if child:IsA("Model") and child ~= char then
			local owner = child:GetAttribute("OwnerUserId")
			if typeof(owner) == "number" and owner == player.UserId then
				return true
			end
		end
	end
	return false
end

-- True when carrying at least one placeable brainrot (excludes lucky-block hauls).
function CarryGate.isCarryingPlaceableBrainrot(): boolean
	local char = player.Character
	if not char then
		return false
	end
	for _, d in char:GetDescendants() do
		if d:IsA("Model") then
			if d:GetAttribute("LuckyBlockCarry") == true then
				continue
			end
			local phase = d:GetAttribute("BrainrotCarryPhase")
			if phase == "Carried" or phase == "Floating" or phase == "Pop" then
				return true
			end
			local owner = d:GetAttribute("OwnerUserId")
			if typeof(owner) == "number" and owner == player.UserId and d.Parent == char then
				if d:GetAttribute("BrainrotName") ~= nil then
					return true
				end
			end
		end
	end
	for _, child in char:GetChildren() do
		if child:IsA("Model") and child ~= char then
			if child:GetAttribute("LuckyBlockCarry") == true then
				continue
			end
			local owner = child:GetAttribute("OwnerUserId")
			if typeof(owner) == "number" and owner == player.UserId then
				if child:GetAttribute("BrainrotName") ~= nil or child:GetAttribute("BrainrotCarryPhase") ~= nil then
					return true
				end
			end
		end
	end
	return false
end

-- True when a brainrot is welded on the character's head (not floating/pop phase).
function CarryGate.isCarryingOnHead(): boolean
	local char = player.Character
	if not char then
		return false
	end
	for _, d in char:GetDescendants() do
		if d:IsA("Model") and d:GetAttribute("BrainrotCarryPhase") == "Carried" then
			return true
		end
	end
	for _, d in char:GetDescendants() do
		if d:IsA("WeldConstraint") and d.Name == "BrainrotCarryWeld" then
			return true
		end
	end
	return false
end

function CarryGate.isBushSearchPrompt(prompt: ProximityPrompt): boolean
	if prompt.Name == "BushHarvestPrompt" then
		return true
	end
	if prompt.ActionText == "Search" and prompt.ObjectText == "Bush" then
		return true
	end
	-- Managed bush hold cards still count as bush search UI.
	if prompt:GetAttribute("BushManagedPrompt") == true or prompt:GetAttribute("BushSearchManaged") == true then
		return true
	end
	return false
end

return CarryGate
