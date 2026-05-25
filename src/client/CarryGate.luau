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

local function countBrainrotTools(container: Instance?): number
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
	n = math.max(n, countBrainrotTools(player:FindFirstChild("Backpack")))
	if char then
		n = math.max(n, countBrainrotTools(char))
	end
	return n
end

function CarryGate.isFull(): boolean
	return CarryGate.usedSlots() >= carryCapacity()
end

-- True when any brainrot is on the character (floating, equipped tool, etc.).
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

function CarryGate.isBushSearchPrompt(prompt: ProximityPrompt): boolean
	return prompt.Name == "BushHarvestPrompt"
		or (prompt.ActionText == "Search" and prompt.ObjectText == "Bush")
end

return CarryGate
