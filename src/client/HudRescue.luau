-- [ACTIVE] HudRescue
--[[
	Studio/join safety net: force-restores Main + SideUI, clears stuck overlays,
	restores camera, and prints a short diagnostic so we can see what's wrong.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)

local HudRescue = {}

local function rescueOnce(reason: string)
	local player = Players.LocalPlayer
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		warn("[HudRescue]", reason, "— PlayerGui missing")
		return
	end

	local lines = { "[HudRescue] " .. reason }

	local loading = pg:FindFirstChild("LoadingScreen")
	if loading and loading:IsA("ScreenGui") and loading.Enabled then
		loading.Enabled = false
		table.insert(lines, "disabled LoadingScreen")
	end

	for _, name in { "Purchasing", "OfflineEarningsDim", "OfflineEarningsHost", "ReviveDim", "FloatingClaimCutscene", "BushSpiderCutscene" } do
		local gui = pg:FindFirstChild(name)
		if gui and gui:IsA("ScreenGui") and gui.Enabled then
			gui.Enabled = false
			table.insert(lines, "disabled " .. name)
		end
	end

	-- SideUI is often fullscreen; Active chrome blocks Frames panel clicks.
	local mainForChrome = pg:FindFirstChild("Main")
	if mainForChrome and mainForChrome:IsA("ScreenGui") then
		local side = mainForChrome:FindFirstChild("SideUI")
		if side and side:IsA("GuiObject") then
			side.Active = false
			table.insert(lines, "SideUI.Active=false")
		end
		local frames = mainForChrome:FindFirstChild("Frames")
		if frames and frames:IsA("GuiObject") then
			local sideZ = if side and side:IsA("GuiObject") then side.ZIndex else 1
			if frames.ZIndex <= sideZ then
				frames.ZIndex = sideZ + 10
				table.insert(lines, "Frames.ZIndex=" .. tostring(frames.ZIndex))
			end
			frames.Active = false
		end
	end

	local purchasing = pg:FindFirstChild("Purchasing")
	if purchasing then
		for _, child in purchasing:GetChildren() do
			if child.Name ~= "Rainbow" and child:IsA("GuiObject") and (child.Visible or child.Active) then
				child.Visible = false
				child.Active = false
				table.insert(lines, "hid Purchasing." .. child.Name)
			end
		end
	end

	local offline = pg:FindFirstChild("Main")
	if offline and offline:IsA("ScreenGui") then
		local frames = offline:FindFirstChild("Frames")
		local oe = frames and frames:FindFirstChild("OfflineEarnings2x")
		if oe and oe:IsA("GuiObject") and oe.Visible then
			table.insert(lines, "OfflineEarnings2x.Visible=true")
		end
	end

	local main = pg:FindFirstChild("Main")
	if main and main:IsA("ScreenGui") then
		if not main.Enabled then
			main.Enabled = true
			table.insert(lines, "enabled Main")
		end
		local sideUI = main:FindFirstChild("SideUI")
		if sideUI and sideUI:IsA("GuiObject") then
			if not (sideUI :: GuiObject).Visible and not GameplayUiVisibility.isHidden() then
				(sideUI :: GuiObject).Visible = true
				table.insert(lines, "showed SideUI")
			elseif GameplayUiVisibility.isHidden() then
				table.insert(lines, "skipped SideUI show (panel/cutscene hide active)")
			end
			table.insert(lines, string.format("Main.Enabled=%s SideUI.Visible=%s", tostring(main.Enabled), tostring((sideUI :: GuiObject).Visible)))
		else
			table.insert(lines, "SideUI MISSING under Main")
		end
	else
		table.insert(lines, "Main ScreenGui MISSING under PlayerGui")
	end

	local cam = Workspace.CurrentCamera
	if cam then
		if cam.CameraType ~= Enum.CameraType.Custom then
			cam.CameraType = Enum.CameraType.Custom
			table.insert(lines, "camera -> Custom")
		end
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum and cam.CameraSubject ~= hum then
			cam.CameraSubject = hum
			table.insert(lines, "camera subject -> Humanoid")
		end
	end

	for _, fx in Lighting:GetChildren() do
		if fx:IsA("BlurEffect") and (fx.Name == "LoadingBlur" or fx.Name == "ReviveBlur" or fx.Size > 0) then
			if fx.Name == "LoadingBlur" or fx.Name == "ReviveBlur" then
				fx:Destroy()
				table.insert(lines, "removed " .. fx.Name)
			elseif fx.Size > 8 then
				fx.Size = 0
				table.insert(lines, "cleared blur Size")
			end
		end
	end

	local headerCount = 0
	-- Prefer tagged headers — never Workspace:GetDescendants() (Studio script timeout).
	for _, inst in CollectionService:GetTagged("BrainrotHeaderTarget") do
		if inst:IsA("Model") then
			local bb = inst:FindFirstChild("BrainrotInfoBillboard", true)
			if bb and bb:IsA("BillboardGui") then
				headerCount += 1
				bb.Enabled = true
			end
		end
	end
	local playerGui = player:FindFirstChild("PlayerGui")
	if playerGui then
		for _, ch in playerGui:GetChildren() do
			if ch:IsA("BillboardGui") and ch.Name == "BrainrotInfoBillboard" then
				headerCount += 1
				ch.Enabled = true
			end
		end
	end

	local tagged = #CollectionService:GetTagged("BrainrotHeaderTarget")
	local stands = #CollectionService:GetTagged("BrainrotStand")
	local standDisplays = 0
	for _, inst in CollectionService:GetTagged("BrainrotStand") do
		if inst:IsA("Model") then
			for _, ch in inst:GetChildren() do
				if ch:IsA("Model") and ch:GetAttribute("BrainrotStandDisplay") == true then
					standDisplays += 1
				end
			end
		end
	end

	local templates = ReplicatedStorage:FindFirstChild("Templates")
	local headerFolder = templates and templates:FindFirstChild("BrainrotHeader")
	local hasBb = headerFolder and headerFolder:FindFirstChildWhichIsA("BillboardGui", true) ~= nil

	table.insert(lines, "BrainrotInfoBillboard count=" .. tostring(headerCount))
	table.insert(lines, "tagged=" .. tostring(tagged))
	table.insert(lines, "stands=" .. tostring(stands))
	table.insert(lines, "standDisplays=" .. tostring(standDisplays))
	table.insert(lines, "templateBB=" .. tostring(hasBb))

	warn(table.concat(lines, " | "))
end

function HudRescue.init()
	task.defer(function()
		task.wait(1)
		rescueOnce("t+1s")
		task.wait(4)
		rescueOnce("t+5s")
		task.wait(10)
		rescueOnce("t+15s")
	end)
end

function HudRescue.run(reason: string)
	rescueOnce(reason)
end

return HudRescue
