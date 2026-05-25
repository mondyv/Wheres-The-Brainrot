--[[
	BaseFloorUnlockClick (client)
	Wires the Upgrade/Add sign SurfaceGui on the local player's plot.
	Studio signs use a Frame named Upgrade — same overlay pattern as BrainrotStandController.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local GameSoundEffects = require(script.Parent.GameSoundEffects)

local player = Players.LocalPlayer

local UNLOCK_REMOTE_NAME = "UnlockBaseFloor"
local OVERLAY_NAME = "__FloorUnlockOverlay"
local WIRE_RETRY_SEC = 8

local wiredSigns: { [Instance]: boolean } = {}
local plotConns: { [Instance]: RBXScriptConnection } = {}

local function alphaKey(name: string): string
	return string.gsub(string.lower(name), "[^a-z0-9]", "")
end

local function isUpgradeAddSign(model: Instance): boolean
	if not model:IsA("Model") then
		return false
	end
	local ak = alphaKey(model.Name)
	return ak == "upgradeadd" or (string.find(ak, "upgrade", 1, true) ~= nil and string.find(ak, "add", 1, true) ~= nil)
end

local function ensureSurfaceGuiInputChain(leaf: GuiObject)
	local w: Instance? = leaf
	while w do
		if w:IsA("GuiObject") then
			(w :: GuiObject).Active = true
		end
		if w:IsA("SurfaceGui") then
			local sg = w :: SurfaceGui
			sg.Enabled = true
			(sg :: any).Active = true
			break
		end
		w = w.Parent
	end
end

local function findUpgradeFrame(sign: Model): GuiObject?
	local guiPart = sign:FindFirstChild("GUIPart") or sign:FindFirstChildWhichIsA("BasePart", true)
	if not guiPart then
		return nil
	end
	local sg = guiPart:FindFirstChildWhichIsA("SurfaceGui", true)
	if not sg or not sg:IsA("SurfaceGui") then
		return nil
	end
	local frame = sg:FindFirstChild("Frame") or sg:FindFirstChildWhichIsA("Frame", true)
	if not frame then
		return nil
	end
	local upgrade = frame:FindFirstChild("Upgrade")
	if upgrade and upgrade:IsA("GuiObject") then
		return upgrade :: GuiObject
	end
	if frame:IsA("GuiObject") then
		return frame :: GuiObject
	end
	return frame:FindFirstChildWhichIsA("GuiObject", true)
end

local function getUnlockRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
	if not remotes then
		return nil
	end
	local ev = remotes:WaitForChild(UNLOCK_REMOTE_NAME, 30)
	if ev and ev:IsA("RemoteEvent") then
		return ev :: RemoteEvent
	end
	return nil
end

local function wireUpgradeTarget(upgradeFrame: GuiObject, unlockRE: RemoteEvent)
	if wiredSigns[upgradeFrame] then
		return true
	end
	ensureSurfaceGuiInputChain(upgradeFrame)

	local function fire()
		unlockRE:FireServer()
	end

	if upgradeFrame:IsA("GuiButton") then
		wiredSigns[upgradeFrame] = true
		(upgradeFrame :: GuiButton).MouseButton1Click:Connect(fire)
		upgradeFrame.Destroying:Once(function()
			wiredSigns[upgradeFrame] = nil
		end)
		return true
	end

	local overlayExisting = upgradeFrame:FindFirstChild(OVERLAY_NAME)
	local overlay: TextButton
	if overlayExisting and overlayExisting:IsA("TextButton") then
		overlay = overlayExisting
	else
		if overlayExisting then
			overlayExisting:Destroy()
		end
		overlay = Instance.new("TextButton")
		overlay.Name = OVERLAY_NAME
		overlay.Size = UDim2.fromScale(1, 1)
		overlay.Position = UDim2.fromScale(0, 0)
		overlay.AnchorPoint = Vector2.new(0, 0)
		overlay.BackgroundTransparency = 0.99
		overlay.Text = ""
		overlay.TextTransparency = 1
		overlay.AutoButtonColor = false
		overlay.ZIndex = 100
		overlay.Parent = upgradeFrame
	end
	overlay.Active = true
	wiredSigns[upgradeFrame] = true
	overlay.MouseButton1Click:Connect(fire)
	upgradeFrame.Destroying:Once(function()
		wiredSigns[upgradeFrame] = nil
	end)
	return true
end

local function wireSign(sign: Model, unlockRE: RemoteEvent): boolean
	if wiredSigns[sign] then
		return true
	end
	local upgradeFrame = findUpgradeFrame(sign)
	if not upgradeFrame then
		return false
	end
	if wireUpgradeTarget(upgradeFrame, unlockRE) then
		wiredSigns[sign] = true
		sign.Destroying:Once(function()
			wiredSigns[sign] = nil
		end)
		return true
	end
	return false
end

local function wireSignWithRetry(sign: Model, unlockRE: RemoteEvent)
	if wiredSigns[sign] then
		return
	end
	task.spawn(function()
		local deadline = os.clock() + WIRE_RETRY_SEC
		while os.clock() < deadline do
			if not sign.Parent then
				return
			end
			if wireSign(sign, unlockRE) then
				return
			end
			task.wait(0.2)
		end
	end)
end

local function wirePlot(plot: Instance, unlockRE: RemoteEvent)
	local uid = plot:GetAttribute("PlotOwnerUserId")
	if typeof(uid) ~= "number" or uid ~= player.UserId then
		return
	end
	for _, d in ipairs(plot:GetDescendants()) do
		if isUpgradeAddSign(d) then
			wireSignWithRetry(d :: Model, unlockRE)
		end
	end
end

local function hookPlot(plot: Instance, unlockRE: RemoteEvent)
	local descConn: RBXScriptConnection? = nil
	local floorConn: RBXScriptConnection? = nil

	local function sync()
		wirePlot(plot, unlockRE)
		local uid = plot:GetAttribute("PlotOwnerUserId")
		local mine = typeof(uid) == "number" and uid == player.UserId
		if mine and not descConn then
			descConn = plot.DescendantAdded:Connect(function(desc)
				if isUpgradeAddSign(desc) then
					wireSignWithRetry(desc :: Model, unlockRE)
				end
			end)
			if not floorConn then
				floorConn = plot:GetAttributeChangedSignal("BaseFloorLevel"):Connect(function()
					wirePlot(plot, unlockRE)
				end)
			end
		elseif not mine then
			if descConn then
				descConn:Disconnect()
				descConn = nil
			end
			if floorConn then
				floorConn:Disconnect()
				floorConn = nil
			end
		end
	end

	if not plotConns[plot] then
		plotConns[plot] = plot:GetAttributeChangedSignal("PlotOwnerUserId"):Connect(sync)
		plot.Destroying:Once(function()
			local c = plotConns[plot]
			if c then
				c:Disconnect()
				plotConns[plot] = nil
			end
			if descConn then
				descConn:Disconnect()
			end
			if floorConn then
				floorConn:Disconnect()
			end
		end)
	end
	sync()
end

local M = {}

function M.init()
	task.spawn(function()
		local unlockRE = getUnlockRemote()
		if not unlockRE then
			warn("[BaseFloorUnlockClick] UnlockBaseFloor remote missing")
			return
		end
		unlockRE.OnClientEvent:Connect(function(ok: boolean, reason: string)
			if ok or reason == "" or reason == "debounce" then
				return
			end
			GameSoundEffects.playErrorNotif()
			warn("[BaseFloorUnlockClick] Unlock failed:", reason)
		end)
		local folder = PlotPaths.waitForSpawnAndBasesFolder(120)
		if not folder then
			return
		end
		local function onPlotAdded(ch: Instance)
			if PlotPaths.isPlotRoot(ch) then
				task.defer(function()
					hookPlot(ch, unlockRE)
				end)
			end
		end
		for _, ch in ipairs(folder:GetChildren()) do
			onPlotAdded(ch)
		end
		folder.ChildAdded:Connect(onPlotAdded)
		player:GetAttributeChangedSignal("AssignedPlotSlot"):Connect(function()
			for _, ch in ipairs(folder:GetChildren()) do
				if PlotPaths.isPlotRoot(ch) then
					wirePlot(ch, unlockRE)
				end
			end
		end)
	end)
end

return M
