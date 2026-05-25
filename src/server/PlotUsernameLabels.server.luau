--[[
	PlotUsernameLabels (server)
	Updates each plot's Studio sign at "<Story>.PlotUsername.Name.SurfaceGui.TextLabel"
	when PlotOwnerUserId changes (see Templates.Base layout).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))

local hooked: { [Instance]: boolean } = {}

local function normalizeKey(name: string): string
	return string.gsub(string.lower(name), "%s+", "")
end

local function findUsernameTextLabel(plot: Instance): TextLabel?
	for _, d in ipairs(plot:GetDescendants()) do
		if (d:IsA("Folder") or d:IsA("Model")) and normalizeKey(d.Name) == "plotusername" then
			local namePart = d:FindFirstChild("Name")
			if namePart and namePart:IsA("BasePart") then
				local sg = namePart:FindFirstChildWhichIsA("SurfaceGui")
				if sg then
					local tl = sg:FindFirstChildWhichIsA("TextLabel", true)
					if tl and tl:IsA("TextLabel") then
						return tl
					end
				end
			end
		end
	end
	return nil
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
	if not label then
		return
	end
	label.Text = ownerDisplayName(plot)
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
