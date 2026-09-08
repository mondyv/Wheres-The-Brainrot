-- [ACTIVE] GearConfig
-- Workout gear catalog (Upgrades panel + tools + Robux products).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local M = {}

export type GearDef = {
	id: number,
	name: string,
	rarity: string, -- common | uncommon | rare | epic | mythic | legendary | godly
	weightLbs: number,
	powerGain: number, -- Power added per workout second
	cashPrice: number,
	robuxPrice: number?, -- display Robux cost (developer product priced in dashboard)
	robuxProductId: number?, -- nil = cash only
	assetName: string, -- ReplicatedStorage.EssentialAssets.Gears["Gear N"]
	flipOnFeet: boolean?, -- Moon / Jupiter: Primary sits on the wrong pole
	hiddenFromShop: boolean?, -- event / admin-only; still grantable
	eventLabel: boolean?, -- "EVENT GEAR" rainbow banner on the mesh
	-- Studio Orientation degrees applied when the gear is posed on the feet.
	workoutOrientation: Vector3?,
}

local GEARS: { GearDef } = {
	{
		id = 1,
		name = "Tree Branch",
		rarity = "common",
		weightLbs = 5,
		powerGain = 2,
		cashPrice = 0,
		robuxPrice = nil,
		robuxProductId = nil,
		assetName = "Gear 1",
	},
	{
		id = 2,
		name = "Stone Dumbbell",
		rarity = "common",
		weightLbs = 10,
		powerGain = 5,
		cashPrice = 45_000,
		robuxPrice = 9,
		robuxProductId = 3696509712,
		assetName = "Gear 2",
	},
	{
		id = 3,
		name = "Ancient Dumbbell",
		rarity = "common",
		weightLbs = 45,
		powerGain = 10,
		cashPrice = 75_000,
		robuxPrice = 19,
		robuxProductId = 3696515436,
		assetName = "Gear 3",
	},
	{
		id = 4,
		name = "Star Dumbbell",
		rarity = "uncommon",
		weightLbs = 135,
		powerGain = 50,
		cashPrice = 1_500_000,
		robuxPrice = 59,
		robuxProductId = 3696519931,
		assetName = "Gear 4",
	},
	{
		id = 5,
		name = "Plate Dumbbell",
		rarity = "uncommon",
		weightLbs = 225,
		powerGain = 150,
		cashPrice = 7_500_000,
		robuxPrice = 79,
		robuxProductId = 3696524705,
		assetName = "Gear 5",
	},
	{
		id = 6,
		name = "Rainbow Dumbbell",
		rarity = "rare",
		weightLbs = 450,
		powerGain = 300,
		cashPrice = 3_000_000_000,
		robuxPrice = 129,
		robuxProductId = 3696529600,
		assetName = "Gear 6",
	},
	{
		id = 7,
		name = "Galaxy Dumbbell",
		rarity = "rare",
		weightLbs = 900,
		powerGain = 700,
		cashPrice = 7_400_000_000,
		robuxPrice = 199,
		robuxProductId = 3696533697,
		assetName = "Gear 7",
	},
	{
		id = 8,
		name = "Purple Orb Dumbbell",
		rarity = "rare",
		weightLbs = 1800,
		powerGain = 1600,
		cashPrice = 30_000_000_000,
		robuxPrice = 249,
		robuxProductId = 3696552109,
		assetName = "Gear 8",
	},
	{
		id = 9,
		name = "Red Orb Dumbbell",
		rarity = "epic",
		weightLbs = 4500,
		powerGain = 3500,
		cashPrice = 90_000_000_000,
		robuxPrice = 259,
		robuxProductId = 3696556426,
		assetName = "Gear 9",
	},
	{
		id = 10,
		name = "Lava Planets Dumbbell",
		rarity = "epic",
		weightLbs = 9000,
		powerGain = 7000,
		cashPrice = 1_200_000_000_000,
		robuxPrice = 299,
		robuxProductId = 3696577307,
		assetName = "Gear 10",
	},
	{
		id = 11,
		name = "Black Holes Dumbbell",
		rarity = "mythic",
		weightLbs = 22500,
		powerGain = 14000,
		cashPrice = 18_000_000_000_000,
		robuxPrice = 349,
		robuxProductId = 3696561899,
		assetName = "Gear 11",
	},
	{
		id = 12,
		name = "Moon",
		rarity = "legendary",
		weightLbs = 99999,
		powerGain = 25000,
		cashPrice = 500_000_000_000_000,
		robuxPrice = 449,
		robuxProductId = 3696581519,
		assetName = "Gear 12",
		flipOnFeet = true,
	},
	{
		id = 13,
		name = "Jupiter",
		rarity = "godly",
		weightLbs = 425000,
		powerGain = 45000,
		cashPrice = 20_000_000_000_000_000,
		robuxPrice = 549,
		robuxProductId = 3696584468,
		assetName = "Gear 13",
		flipOnFeet = true,
	},
	{
		id = 14,
		name = "The Bus",
		rarity = "epic",
		weightLbs = 9000,
		powerGain = 7000,
		cashPrice = 0,
		robuxPrice = nil,
		robuxProductId = nil,
		assetName = "The Bus",
		hiddenFromShop = true,
		eventLabel = true,
		workoutOrientation = Vector3.new(90, 58.986, 0),
	},
}

M.GEARS = GEARS
M.WORKOUT_IMAGE = "rbxassetid://73088512205933"
M.WORKOUT_ANIMATION_ID = "rbxassetid://118202501576957"
M.GEAR_TOOL_ATTR = "WorkoutGearTool"
M.GEAR_ID_ATTR = "WorkoutGearId"
M.OWNED_GEARS_ATTR = "OwnedGears" -- comma-separated ids e.g. "1,3,5"
M.EQUIPPED_GEAR_ATTR = "EquippedGearId"
M.POWER_ATTR = "Power"
M.POWER_MAX_ATTR = "PowerMax" -- true ceiling; Edit Power can only set active Power ≤ this
M.POWER_EDITED_ATTR = "PowerEdited"
M.WORKOUT_ACTIVE_ATTR = "WorkoutActive"
M.WORKOUT_LIFT_MULT_MAX = 3
-- Combo count where lift first hits the cap.
M.WORKOUT_LIFT_COMBO_FOR_MAX = 16
-- Combo button locks here until the workout stops (no more taps / misses).
M.WORKOUT_COMBO_MAX = 50

function M.workoutLiftMultiplier(combo: number): number
	local c = math.max(1, math.floor(combo))
	local span = math.max(1, M.WORKOUT_LIFT_COMBO_FOR_MAX - 1)
	return math.clamp(1 + (c - 1) / span * (M.WORKOUT_LIFT_MULT_MAX - 1), 1, M.WORKOUT_LIFT_MULT_MAX)
end

local byId: { [number]: GearDef } = {}
local byProduct: { [number]: GearDef } = {}
for _, g in M.GEARS do
	byId[g.id] = g
	if g.robuxProductId then
		byProduct[g.robuxProductId] = g
	end
end

function M.get(id: number): GearDef?
	return byId[id]
end

function M.isShopListed(def: GearDef): boolean
	return def.hiddenFromShop ~= true
end

local function compactName(value: string): string
	return string.lower((string.gsub(value, "[%s_%-%p]", "")))
end

local GEAR_QUERY_ALIASES: { [string]: number } = {
	bus = 14,
	thebus = 14,
	schoolbus = 14,
	eventbus = 14,
	eventgear = 14,
}

function M.findByQuery(raw: string): GearDef?
	local trimmed = string.gsub(raw, "^%s*(.-)%s*$", "%1")
	if trimmed == "" then
		return nil
	end
	trimmed = string.gsub(trimmed, "^[\"'](.*)[\"']$", "%1")
	local asNum = tonumber(trimmed)
	if asNum then
		return byId[math.floor(asNum)]
	end
	local key = compactName(trimmed)
	local aliasId = GEAR_QUERY_ALIASES[key]
	if aliasId then
		return byId[aliasId]
	end
	for _, g in M.GEARS do
		if compactName(g.name) == key or compactName(g.assetName) == key then
			return g
		end
	end
	-- Last word ("bus") and each token, skipping filler like "the".
	for token in string.gmatch(string.lower(trimmed), "%w+") do
		if #token >= 3 and token ~= "the" and token ~= "gear" then
			local tokenAlias = GEAR_QUERY_ALIASES[token]
			if tokenAlias then
				return byId[tokenAlias]
			end
			for _, g in M.GEARS do
				if compactName(g.name) == token or compactName(g.assetName) == token then
					return g
				end
				if string.find(compactName(g.name), token, 1, true) then
					return g
				end
			end
		end
	end
	local lower = string.lower(trimmed)
	if #lower >= 3 then
		for _, g in M.GEARS do
			if string.find(string.lower(g.name), lower, 1, true) then
				return g
			end
			if string.find(string.lower(g.assetName), lower, 1, true) then
				return g
			end
		end
	end
	return nil
end

function M.flipOnFeet(id: number): boolean
	local def = byId[id]
	return def ~= nil and def.flipOnFeet == true
end

-- Studio Orientation (degrees) → CFrame. Uses YXZ fromOrientation, not Angles.
function M.workoutPoseCFrame(id: number): CFrame?
	local def = byId[id]
	local o = def and def.workoutOrientation
	if not o then
		return nil
	end
	return CFrame.fromOrientation(math.rad(o.X), math.rad(o.Y), math.rad(o.Z))
end

function M.getByProductId(productId: number): GearDef?
	return byProduct[productId]
end

function M.allProductIds(): { number }
	local out: { number } = {}
	for _, g in M.GEARS do
		if g.robuxProductId then
			table.insert(out, g.robuxProductId)
		end
	end
	return out
end

function M.parseOwned(raw: any): { [number]: boolean }
	local set: { [number]: boolean } = {}
	if typeof(raw) ~= "string" or raw == "" then
		return set
	end
	for token in string.gmatch(raw, "[^,%s]+") do
		local n = tonumber(token)
		if n and byId[n] then
			set[n] = true
		end
	end
	return set
end

function M.encodeOwned(set: { [number]: boolean }): string
	local ids: { number } = {}
	for id in set do
		if byId[id] then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	local parts: { string } = {}
	for _, id in ids do
		table.insert(parts, tostring(id))
	end
	return table.concat(parts, ",")
end

function M.isUnlocked(_gearId: number, _owned: { [number]: boolean }): boolean
	-- All gears are available to buy; no progression lock.
	return true
end

function M.rarityDisplay(rarity: string): string
	local r = string.lower(rarity)
	if r == "mythic" then
		return "Mythical"
	end
	return string.upper(string.sub(r, 1, 1)) .. string.lower(string.sub(r, 2))
end

local function getGearsFolder(): Folder?
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	local folder = assets and assets:FindFirstChild("Gears")
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

local function nameMatchesGear(childName: string, def: GearDef): boolean
	local lower = string.lower(childName)
	local idStr = tostring(def.id)
	if lower == string.lower(def.assetName) or lower == string.lower(def.name) then
		return true
	end
	if lower == "gear" .. idStr or lower == "gear_" .. idStr or lower == "gear " .. idStr then
		return true
	end
	if string.find(lower, "gear%s*" .. idStr, 1) then
		return true
	end
	local skip = {
		dumbbell = true,
		orb = true,
		holes = true,
		planets = true,
		the = true,
	}
	for token in string.gmatch(string.lower(def.name), "%w+") do
		if #token >= 3 and not skip[token] and string.find(lower, token, 1, true) then
			return true
		end
	end
	return false
end

-- Studio gears store a 2D icon at EssentialAssets.Gears["Gear N"].ImageLabel.
function M.getIconImage(gearId: number): string
	local src = M.findGearAsset(gearId)
	if not src then
		return ""
	end
	local label = src:FindFirstChild("ImageLabel")
	if not label then
		label = src:FindFirstChild("Icon") or src:FindFirstChild("icon")
	end
	if label and (label:IsA("ImageLabel") or label:IsA("ImageButton")) then
		local img = (label :: ImageLabel).Image
		if typeof(img) == "string" and img ~= "" then
			return img
		end
	end
	return ""
end

function M.applyIconToGui(gui: ImageLabel | ImageButton, gearId: number): boolean
	local src = M.findGearAsset(gearId)
	local label = src and src:FindFirstChild("ImageLabel")
	if not label then
		label = src and (src:FindFirstChild("Icon") or src:FindFirstChild("icon"))
	end
	local image = M.getIconImage(gearId)
	if image == "" then
		return false
	end
	gui.Image = image
	gui.ImageColor3 = Color3.new(1, 1, 1)
	gui.ImageTransparency = 0
	gui.ScaleType = Enum.ScaleType.Fit
	if label and (label:IsA("ImageLabel") or label:IsA("ImageButton")) then
		local srcGui = label :: ImageLabel
		gui.ImageRectOffset = srcGui.ImageRectOffset
		gui.ImageRectSize = srcGui.ImageRectSize
		if srcGui.ResampleMode then
			gui.ResampleMode = srcGui.ResampleMode
		end
	end
	return true
end

function M.resolvePrimaryPart(root: Instance): BasePart?
	local named = root:FindFirstChild("Primary") or root:FindFirstChild("Primary", true)
	if named and named:IsA("BasePart") then
		return named
	end
	if root:IsA("Model") and root.PrimaryPart then
		return root.PrimaryPart
	end
	if root:IsA("BasePart") then
		return root
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
end

function M.findGearAsset(gearId: number): Instance?
	local def = byId[gearId]
	if not def then
		return nil
	end
	local folder = getGearsFolder()
	if not folder then
		return nil
	end
	local exact = folder:FindFirstChild(def.assetName) or folder:FindFirstChild(def.name)
	if exact then
		return exact
	end
	local wantAsset = compactName(def.assetName)
	local wantName = compactName(def.name)
	for _, child in folder:GetDescendants() do
		if not (child:IsA("Model") or child:IsA("BasePart") or child:IsA("Folder") or child:IsA("Tool")) then
			continue
		end
		local n = compactName(child.Name)
		if n == wantAsset or n == wantName then
			return child
		end
	end
	for _, child in folder:GetChildren() do
		if nameMatchesGear(child.Name, def) then
			return child
		end
	end
	return nil
end

local EVENT_LABEL_ATTR = "EventGearLabeled"

local function rainbowSequence(): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 70, 90)),
		ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 200, 50)),
		ColorSequenceKeypoint.new(0.4, Color3.fromRGB(80, 255, 120)),
		ColorSequenceKeypoint.new(0.6, Color3.fromRGB(60, 200, 255)),
		ColorSequenceKeypoint.new(0.8, Color3.fromRGB(160, 90, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 70, 90)),
	})
end

local function pickEventLabelPart(model: Model): BasePart?
	local primary = model.PrimaryPart
	local best: BasePart? = nil
	local bestVol = -1
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= primary then
			local vol = d.Size.X * d.Size.Y * d.Size.Z
			if vol > bestVol then
				bestVol = vol
				best = d
			end
		end
	end
	if best then
		return best
	end
	return M.resolvePrimaryPart(model)
end

-- One-time "EVENT GEAR" banners on the mesh. Safe to call on clones; skips if already labeled.
function M.applyEventGearLabel(model: Model)
	if model:GetAttribute(EVENT_LABEL_ATTR) == true then
		return
	end
	if model:FindFirstChild("EventGearBanner", true) then
		model:SetAttribute(EVENT_LABEL_ATTR, true)
		return
	end
	local part = pickEventLabelPart(model)
	if not part then
		return
	end
	local faces: { Enum.NormalId }
	if part.Size.Z >= part.Size.X then
		faces = { Enum.NormalId.Left, Enum.NormalId.Right }
	else
		faces = { Enum.NormalId.Front, Enum.NormalId.Back }
	end
	for i, face in faces do
		local gui = Instance.new("SurfaceGui")
		gui.Name = "EventGearBanner"
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.LightInfluence = 0
		gui.AlwaysOnTop = true
		gui.MaxDistance = 90
		gui.ZOffset = 1
		gui.ResetOnSpawn = false
		local label = Instance.new("TextLabel")
		label.Name = "Title"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Font = Enum.Font.GothamBlack
		label.Text = "EVENT GEAR"
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextStrokeColor3 = Color3.fromRGB(20, 10, 30)
		label.TextStrokeTransparency = 0.2
		label.TextScaled = true
		label.TextWrapped = false
		local cap = Instance.new("UITextSizeConstraint")
		cap.MaxTextSize = 42
		cap.MinTextSize = 14
		cap.Parent = label
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0.06, 0)
		pad.PaddingRight = UDim.new(0.06, 0)
		pad.PaddingTop = UDim.new(0.18, 0)
		pad.PaddingBottom = UDim.new(0.18, 0)
		pad.Parent = label
		local grad = Instance.new("UIGradient")
		grad.Name = "EventRainbow"
		grad.Color = rainbowSequence()
		grad.Rotation = 0
		grad:SetAttribute("EventGearRainbow", true)
		grad.Parent = label
		label.Parent = gui
		gui.Parent = part
		gui.LayoutOrder = i
	end
	model:SetAttribute(EVENT_LABEL_ATTR, true)
	model:SetAttribute("EventGear", true)
end

-- Clone Studio gear (Model / Folder / Tool / Part) into a fresh Model for tools/viewports.
-- Always keep sibling VFX / Attachment folders — never clone only the nested Model.
function M.cloneGearModel(gearId: number): Model?
	local src = M.findGearAsset(gearId)
	if not src then
		return nil
	end
	local def = byId[gearId]
	local wrapper: Model
	if src:IsA("Model") then
		wrapper = src:Clone()
	else
		wrapper = Instance.new("Model")
		wrapper.Name = src.Name
		if src:IsA("BasePart") then
			local part = src:Clone()
			part.Parent = wrapper
			wrapper.PrimaryPart = part
		else
			local bag = src:Clone()
			for _, child in bag:GetChildren() do
				child.Parent = wrapper
			end
			bag:Destroy()
		end
	end

	-- Nested folder/model wrappers from Studio packages.
	if not wrapper.PrimaryPart then
		local nested = wrapper:FindFirstChildWhichIsA("Model")
		if nested and nested.PrimaryPart then
			wrapper.PrimaryPart = nested.PrimaryPart
		end
	end

	local strip: { Instance } = {}
	for _, d in wrapper:GetDescendants() do
		if d:IsA("Humanoid") or d:IsA("Animator") or d:IsA("Script") or d:IsA("LocalScript") then
			table.insert(strip, d)
		end
	end
	for _, d in strip do
		d:Destroy()
	end

	-- Pull sibling FX folders in EssentialAssets.Gears (often named "Gear N VFX" / "FX").
	local folder = getGearsFolder()
	if folder and def then
		for _, child in folder:GetChildren() do
			if child == src then
				continue
			end
			local lower = string.lower(child.Name)
			local idStr = tostring(def.id)
			local looksFx = string.find(lower, "vfx", 1, true)
				or string.find(lower, "fx", 1, true)
				or string.find(lower, "effect", 1, true)
				or string.find(lower, "particle", 1, true)
			local looksGear = nameMatchesGear(child.Name, def)
				or string.find(lower, "gear%s*" .. idStr, 1) ~= nil
			if looksFx and looksGear then
				local fxClone = child:Clone()
				fxClone.Parent = wrapper
			end
		end
	end

	if not wrapper.PrimaryPart then
		local primary = M.resolvePrimaryPart(wrapper)
		if primary then
			wrapper.PrimaryPart = primary
		end
	end
	if not wrapper.PrimaryPart then
		wrapper:Destroy()
		return nil
	end
	if def and def.eventLabel == true then
		M.applyEventGearLabel(wrapper)
	end
	return wrapper
end

return M
