-- [ACTIVE] PlotUsernameLabels.server
--[[
	PlotUsernameLabels (server)
	Updates each plot's Studio sign at "<Story>.PlotUsername":
	  - Name.SurfaceGui.TextLabel → owner DisplayName / "Empty"
	  - Icon/Head ImageLabel (or Decal) → owner AvatarHeadShot
	when PlotOwnerUserId changes (see Templates.Base layout).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))

local hooked: { [Instance]: boolean } = {}

local ICON_NAME_KEYS: { [string]: boolean } = {
	icon = true,
	head = true,
	avatar = true,
	image = true,
	player = true,
	picture = true,
	playericon = true,
	ownericon = true,
	headicon = true,
	playerimage = true,
	pfp = true,
}

local function normalizeKey(name: string): string
	return string.gsub(string.lower(name), "%s+", "")
end

local function avatarHeadshotUrl(userId: number): string
	return string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", userId)
end

local function findPlotUsernameRoot(plot: Instance): Instance?
	for _, d in ipairs(plot:GetDescendants()) do
		if (d:IsA("Folder") or d:IsA("Model")) and normalizeKey(d.Name) == "plotusername" then
			return d
		end
	end
	return nil
end

local function findUsernameTextLabel(plot: Instance): TextLabel?
	local root = findPlotUsernameRoot(plot)
	if not root then
		return nil
	end
	local namePart = root:FindFirstChild("Name")
	if namePart and namePart:IsA("BasePart") then
		local sg = namePart:FindFirstChildWhichIsA("SurfaceGui")
		if sg then
			local tl = sg:FindFirstChildWhichIsA("TextLabel", true)
			if tl and tl:IsA("TextLabel") then
				return tl
			end
		end
	end
	return nil
end

-- ImageLabel or Decal used as the owner portrait under PlotUsername.
local function findUsernamePortrait(plot: Instance): (ImageLabel | Decal)?
	local root = findPlotUsernameRoot(plot)
	if not root then
		return nil
	end

	local preferred: (ImageLabel | Decal)? = nil
	local fallback: (ImageLabel | Decal)? = nil

	for _, d in ipairs(root:GetDescendants()) do
		local parentKey = if d.Parent then normalizeKey(d.Parent.Name) else ""
		local selfKey = normalizeKey(d.Name)
		local nameHit = ICON_NAME_KEYS[selfKey] == true or ICON_NAME_KEYS[parentKey] == true

		if d:IsA("ImageLabel") then
			if nameHit then
				preferred = d
				break
			end
			-- Skip tiny chrome under the name label if we already have a better candidate later.
			if not fallback then
				fallback = d
			end
		elseif d:IsA("Decal") then
			if nameHit then
				preferred = d
				break
			end
			if not fallback then
				fallback = d
			end
		end
	end

	return preferred or fallback
end

local function setPortraitImage(portrait: ImageLabel | Decal, image: string)
	if portrait:IsA("ImageLabel") then
		portrait.Image = image
	else
		portrait.Texture = image
	end
end

local function ownerDisplayName(plot: Instance): string
	local uid = plot:GetAttribute("PlotOwnerUserId")
	if typeof(uid) ~= "number" then
		return "Empty"
	end
	local plr = Players:GetPlayerByUserId(uid)
	if plr then
		return plr.DisplayName
	end
	return "Player"
end

local function refreshPlotUsername(plot: Instance)
	local label = findUsernameTextLabel(plot)
	if label then
		label.Text = ownerDisplayName(plot)
	end

	local portrait = findUsernamePortrait(plot)
	if not portrait then
		return
	end

	local uid = plot:GetAttribute("PlotOwnerUserId")
	if typeof(uid) == "number" then
		setPortraitImage(portrait, avatarHeadshotUrl(uid))
	else
		-- Unclaimed: clear placeholder so it isn't a random stock head.
		setPortraitImage(portrait, "")
	end
end

local function hookPlot(plot: Instance)
	if not PlotPaths.isPlotRoot(plot) or hooked[plot] then
		return
	end
	hooked[plot] = true
	plot:GetAttributeChangedSignal("PlotOwnerUserId"):Connect(function()
		refreshPlotUsername(plot)
	end)
	plot.Destroying:Once(function()
		hooked[plot] = nil
	end)
	refreshPlotUsername(plot)
end

local function hookFolder(folder: Instance)
	for _, ch in ipairs(folder:GetChildren()) do
		hookPlot(ch)
	end
	folder.ChildAdded:Connect(function(ch)
		if PlotPaths.isPlotRoot(ch) then
			task.defer(function()
				hookPlot(ch)
			end)
		end
	end)
end

task.spawn(function()
	local folder = PlotPaths.waitForSpawnAndBasesFolder(120)
	if folder then
		hookFolder(folder)
	end
end)

Players.PlayerAdded:Connect(function(plr)
	for plot in pairs(hooked) do
		if plot.Parent and plot:GetAttribute("PlotOwnerUserId") == plr.UserId then
			refreshPlotUsername(plot)
		end
	end
end)
