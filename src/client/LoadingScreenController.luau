-- [ACTIVE] LoadingScreenController
--[[
	LoadingScreenController — full-screen join overlay:
	Moon camera flyover + heavy blur, centered GameNameImage (wobbly jump),
	"Loading..." + lime progress bar + cycling [hints]; hides other PlayerGui until ready.
	StarterGui.LoadingScreen + GameNameImage. Moon export: "Camera loading" (Frames/0..N).
--]]

local ContentProvider = game:GetService("ContentProvider")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local MIN_DISPLAY_SEC = 2.4
local HOLD_AT_FULL_SEC = 0.6
local FADE_OUT_SEC = 0.9
local FADE_TWEEN_INFO = TweenInfo.new(FADE_OUT_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local RESOLVE_TIMEOUT = 45
-- Wall-clock duration multiplier for moon flyover (2x slower back cam → longer load).
local MOON_PLAYBACK_SCALE = 2

local DEFAULT_CAMERA_POS = Vector3.new(1452.568, 100.564, 518.559)
local DEFAULT_CAMERA_RAD = Vector3.new(math.rad(4.555), math.rad(18.409), 0)

-- Backpack stays off permanently — custom Toolbar replaces it.
local CORE_GUIS_ALWAYS_DISABLED: { Enum.CoreGuiType } = {
	Enum.CoreGuiType.Backpack,
}

local CORE_GUIS_TO_HIDE: { Enum.CoreGuiType } = {
	Enum.CoreGuiType.Chat,
	Enum.CoreGuiType.EmotesMenu,
	Enum.CoreGuiType.Health,
	Enum.CoreGuiType.PlayerList,
}

local OVERLAY_COLOR = Color3.fromRGB(8, 5, 4)
local SOLID_COVER_COLOR = Color3.fromRGB(6, 4, 3)
local OVERLAY_TRANSPARENCY = 0.38
local LOADING_BLUR_SIZE = 56

local ENTRANCE_DURATION = 0.85
local ENTRANCE_SCALE_START = 0.78
local SOLID_COVER_FADE_SEC = 0.55
local TITLE_MAX_WIDTH_MOBILE = 560
local TITLE_MAX_WIDTH_DESKTOP = 860
local TITLE_DEFAULT_ASPECT = 3.15
local STACK_PADDING_PX = 8
local STACK_CENTER_Y = 0.52
local LOADING_TEXT_SIZE = 24
local HINT_TEXT_SIZE = 16
local BAR_WIDTH_MOBILE = 340
local BAR_WIDTH_DESKTOP = 440
local BAR_HEIGHT_PX = 16
local BAR_OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
local BAR_OUTLINE_TRANSPARENCY = 0.72
local BAR_OUTLINE_THICKNESS = 1.25

local BAR_FILL_COLOR = Color3.fromRGB(118, 196, 66)
local BAR_FILL_HIGHLIGHT = Color3.fromRGB(160, 230, 100)
local BAR_TRACK_COLOR = Color3.fromRGB(22, 20, 18)
local LOADING_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local HINT_TEXT_COLOR = Color3.fromRGB(255, 255, 255)

local ELLIPSIS_INTERVAL_SEC = 0.38
local HINT_INTERVAL_SEC = 2.15
local WOBBLE_JUMP_SPEED = 2.35
local WOBBLE_ROT_DEG = 4
local WOBBLE_JUMP_PX = 8
local WOBBLE_SCALE_AMOUNT = 0.022

local LIQUID_IMAGE_IDS = {
	"rbxassetid://114678398666932",
	"rbxassetid://79066128728111",
	"rbxassetid://126746861363784",
}
local LIQUID_BLOB_COUNT = 6
local LIQUID_SPEED_MUL = 0.45
local LIQUID_STYLE = "image_v2_blur_sides"
local LIQUID_BLUR_LAYERS = 5 -- stacked copies = fake heavy blur
local LIQUID_CORE_TRANSPARENCY = 0.55
local LIQUID_OUTER_TRANSPARENCY = 0.9

local LOADING_HINTS = {
	"Optimizing Vibes",
	"Warming Up Bushes",
	"Charging Brainrot",
	"Polishing Luck",
	"Spawning Chaos",
	"Calibrating Steals",
	"Syncing Stands",
	"Brewing Rebirths",
	"Untangling Spaghetti",
	"Feeding the Turtle",
}

local HIDE_LOADING_UI_NAMES = { "LoadingFrame", "BarPlaceholder", "LoadingBar", "Stud TextureDecal", "Stud Texture", "StudTexture" }

local function isLoadingGuiAllowed(name: string): boolean
	-- Only LoadingScreen stays up. Main must stay disabled or Toolbar/inventory bleed through.
	-- Never force-enable Purchasing — DisplayOrder 10000 overlay stuck after join.
	return name == "LoadingScreen"
end

local LOGO_NAMES = { "GameNameImage", "ImageLabel" }
local MOON_CAMERA_EXPORT_NAMES = { "Camera loading", "Camera Loading", "CameraLoading" }

local M = {}

local savedGuiStates: { [ScreenGui]: boolean }? = nil
local playerGuiChildConn: RBXScriptConnection? = nil
local loadingActive = false
local gameplayReadyCallbacks: { () -> () } = {}
local activeBlurEffect: BlurEffect? = nil
local stopNameAnim: (() -> ())? = nil
local stopCameraLock: (() -> ())? = nil
local fadeCanvas: CanvasGroup? = nil
local cameraClipStartedAt: number? = nil
local characterHideConn: RBXScriptConnection? = nil
local hiddenCharacterParts: { [BasePart]: number }? = nil
local earlyVisualsReady = false
local loadingBarFill: Frame? = nil
local loadingProgress = 0
local stopLiquidAnim: (() -> ())? = nil

type LiquidBlob = {
	gui: GuiObject,
	baseX: number,
	baseY: number,
	speed: number,
	ampY: number,
	ampX: number,
	phase: number,
	rotSpeed: number,
	baseScale: number,
}

local function defaultLoadingCFrame(): CFrame
	return CFrame.new(DEFAULT_CAMERA_POS) * CFrame.fromOrientation(DEFAULT_CAMERA_RAD.X, DEFAULT_CAMERA_RAD.Y, DEFAULT_CAMERA_RAD.Z)
end

local function findReferenceCamera(root: Instance?): Camera?
	if not root then
		return nil
	end
	local cam = root:FindFirstChild("Camera")
	if cam and cam:IsA("Camera") then
		return cam
	end
	return nil
end

local function resolveLoadingCFrame(_loadingGui: ScreenGui?): CFrame
	-- Prefer StarterGui template — PlayerGui clone Camera CFrame is often wrong under ScreenGui.
	local starter = StarterGui:FindFirstChild("LoadingScreen")
	local ref = findReferenceCamera(starter) or findReferenceCamera(_loadingGui)
	if ref then
		local attr = ref:GetAttribute("LoadingWorldCFrame")
		if typeof(attr) == "CFrame" then
			return attr
		end
		local cf = ref.CFrame
		if cf.Position.Magnitude > 1 then
			return cf
		end
	end
	return defaultLoadingCFrame()
end

local function hideLocalCharacter(character: Model)
	local saved: { [BasePart]: number } = {}
	local scanned = 0
	for _, desc in character:GetDescendants() do
		scanned += 1
		if scanned % 400 == 0 then
			task.wait()
		end
		if desc:IsA("BasePart") then
			saved[desc] = desc.LocalTransparencyModifier
			desc.LocalTransparencyModifier = 1
		end
	end
	hiddenCharacterParts = saved
end

local function restoreLocalCharacter()
	if not hiddenCharacterParts then
		return
	end
	for part, modifier in hiddenCharacterParts do
		if part.Parent then
			part.LocalTransparencyModifier = modifier
		end
	end
	hiddenCharacterParts = nil
end

local function bindCharacterHideWhileLoading(player: Player)
	if characterHideConn then
		return
	end
	if player.Character then
		hideLocalCharacter(player.Character)
	end
	characterHideConn = player.CharacterAdded:Connect(function(character)
		if not loadingActive then
			return
		end
		task.defer(function()
			if loadingActive and character.Parent then
				hideLocalCharacter(character)
			end
		end)
	end)
end

local function unbindCharacterHide()
	if characterHideConn then
		characterHideConn:Disconnect()
		characterHideConn = nil
	end
	restoreLocalCharacter()
end

local function destroyLightingBlurEffects()
	if activeBlurEffect and activeBlurEffect.Parent then
		activeBlurEffect:Destroy()
	end
	activeBlurEffect = nil

	for _, name in { "LoadingScreenBlur", "UIModalBlur" } do
		local effect = Lighting:FindFirstChild(name)
		if effect and effect:IsA("BlurEffect") then
			effect:Destroy()
		end
	end
end

local function ensureLoadingBlur(): BlurEffect
	if activeBlurEffect and activeBlurEffect.Parent then
		activeBlurEffect.Size = LOADING_BLUR_SIZE
		return activeBlurEffect
	end

	destroyLightingBlurEffects()
	local blur = Instance.new("BlurEffect")
	blur.Name = "LoadingScreenBlur"
	blur.Size = LOADING_BLUR_SIZE
	blur.Parent = Lighting
	activeBlurEffect = blur
	return blur
end

local function findSolidCover(loadingGui: ScreenGui): Frame?
	local direct = loadingGui:FindFirstChild("SolidCover")
	if direct and direct:IsA("Frame") then
		return direct
	end
	local nested = loadingGui:FindFirstChild("SolidCover", true)
	if nested and nested:IsA("Frame") then
		return nested
	end
	return nil
end

local function ensureSolidCover(loadingGui: ScreenGui): Frame
	local existing = findSolidCover(loadingGui)
	if existing and existing:IsA("Frame") then
		existing.Size = UDim2.fromScale(1, 1)
		existing.Position = UDim2.fromScale(0, 0)
		existing.AnchorPoint = Vector2.new(0, 0)
		existing.BackgroundTransparency = 0
		existing.Visible = true
		return existing
	end

	local cover = Instance.new("Frame")
	cover.Name = "SolidCover"
	cover.BackgroundColor3 = SOLID_COVER_COLOR
	cover.BackgroundTransparency = 0
	cover.BorderSizePixel = 0
	cover.AnchorPoint = Vector2.new(0, 0)
	cover.Position = UDim2.fromScale(0, 0)
	cover.Size = UDim2.fromScale(1, 1)
	cover.ZIndex = 10
	cover.Parent = loadingGui
	return cover
end

local function forceReleaseSolidCover(loadingGui: ScreenGui)
	local cover = findSolidCover(loadingGui)
	if not cover or not cover:IsA("Frame") then
		return
	end
	cover.BackgroundTransparency = 1
	cover.Visible = false
end

local function releaseSolidCover(loadingGui: ScreenGui)
	local cover = findSolidCover(loadingGui)
	if not cover or not cover:IsA("Frame") or not cover.Visible then
		return
	end

	local tween = TweenService:Create(
		cover,
		TweenInfo.new(SOLID_COVER_FADE_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	tween:Play()
	local completedConn: RBXScriptConnection?
	completedConn = tween.Completed:Connect(function()
		if completedConn then
			completedConn:Disconnect()
			completedConn = nil
		end
		if cover.Parent then
			cover.Visible = false
		end
	end)
end

local function ensureBlurOverlay(loadingGui: ScreenGui): Frame
	local existing = loadingGui:FindFirstChild("BlurOverlay")
	if existing and existing:IsA("Frame") then
		existing.Size = UDim2.new(1, 0, 1, 0)
		existing.Position = UDim2.new(0, 0, 0, 0)
		existing.AnchorPoint = Vector2.new(0, 0)
		existing.BackgroundTransparency = OVERLAY_TRANSPARENCY
		return existing
	end
	local overlay = Instance.new("Frame")
	overlay.Name = "BlurOverlay"
	overlay.BackgroundColor3 = OVERLAY_COLOR
	overlay.BackgroundTransparency = OVERLAY_TRANSPARENCY
	overlay.BorderSizePixel = 0
	overlay.AnchorPoint = Vector2.new(0, 0)
	overlay.Position = UDim2.new(0, 0, 0, 0)
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.ZIndex = 0
	overlay.Parent = loadingGui
	return overlay
end

local function restoreGameplayCamera(camera: Camera, player: Player)
	camera.CameraType = Enum.CameraType.Custom
	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
end

type MoonCameraTrack = {
	frames: { CFrame },
	fov: { number },
	fps: number,
}

local loadedMoonTrack: MoonCameraTrack? = nil

local SKIP_MOON_FRAME_NAMES: { [string]: boolean } = {
	default = true,
	Default = true,
}

local function frameIndexFromName(name: string): number?
	if SKIP_MOON_FRAME_NAMES[name] then
		return nil
	end
	local direct = tonumber(name)
	if direct then
		return direct
	end
	local digits = string.match(name, "%d+")
	if digits then
		return tonumber(digits)
	end
	return nil
end

local function readSettingNumber(settings: Instance, names: { string }): number?
	for _, settingName in names do
		local ch = settings:FindFirstChild(settingName)
		if not ch then
			continue
		end
		if ch:IsA("NumberValue") or ch:IsA("IntValue") then
			return ch.Value
		end
		if ch:IsA("StringValue") then
			return tonumber(ch.Value)
		end
	end
	return nil
end

local function describeLoadingScreenForMoon(root: ScreenGui?): string
	if not root then
		return "LoadingScreen missing"
	end
	local cameraNode = root:FindFirstChild("Camera")
	if not cameraNode then
		local kids = {}
		for _, ch in root:GetChildren() do
			table.insert(kids, ch.Name)
		end
		return "no Camera child; LoadingScreen has: " .. table.concat(kids, ", ")
	end
	local parts = {}
	for _, ch in cameraNode:GetChildren() do
		table.insert(parts, ch.Name .. " (" .. ch.ClassName .. ")")
	end
	return "Camera children: " .. table.concat(parts, ", ")
end

local function waitForStarterLoadingScreen(): ScreenGui?
	local existing = StarterGui:FindFirstChild("LoadingScreen")
	if existing and existing:IsA("ScreenGui") then
		return existing
	end
	local ok, waited = pcall(function()
		return StarterGui:WaitForChild("LoadingScreen", 12)
	end)
	if ok and waited and waited:IsA("ScreenGui") then
		return waited
	end
	return nil
end

local function findMoonCameraExport(loadingGui: ScreenGui): Instance?
	local roots: { ScreenGui } = {}
	local starterScreen = waitForStarterLoadingScreen()
	if starterScreen then
		table.insert(roots, starterScreen)
	end
	if loadingGui and loadingGui:IsA("ScreenGui") and loadingGui ~= starterScreen then
		table.insert(roots, loadingGui)
	end

	for _, root in roots do
		for _, exportName in MOON_CAMERA_EXPORT_NAMES do
			local export = root:FindFirstChild(exportName, true)
			if export then
				return export
			end
		end

		-- Moon path: LoadingScreen.Camera["Camera loading"]
		local cameraNode = root:FindFirstChild("Camera")
		if cameraNode then
			for _, exportName in MOON_CAMERA_EXPORT_NAMES do
				local export = cameraNode:FindFirstChild(exportName)
				if export then
					return export
				end
			end
		end
	end
	return nil
end

local function moonClipDurationSec(track: MoonCameraTrack): number
	local frameCount = #track.frames
	if frameCount <= 1 then
		return 0
	end
	return ((frameCount - 1) / track.fps) * MOON_PLAYBACK_SCALE
end

local function computeLoadingDisplaySec(track: MoonCameraTrack?): number
	if track and #track.frames > 1 then
		return moonClipDurationSec(track) + HOLD_AT_FULL_SEC
	end
	return MIN_DISPLAY_SEC
end

local function deepSelectMoonPath(root: Instance, path: { string }): any?
	local current: Instance? = root
	for _, segment in path do
		if not current then
			return nil
		end
		if segment == "Value" then
			if current:IsA("ValueBase") then
				return current.Value
			end
			return nil
		end
		current = current:FindFirstChild(segment)
	end
	return nil
end

local function moonRawToCFrame(raw: any): CFrame?
	if typeof(raw) == "CFrame" then
		return raw
	end
	if type(raw) == "string" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok then
			return moonRawToCFrame(decoded)
		end
		return nil
	end
	if type(raw) ~= "table" then
		return nil
	end

	local x = raw.X or raw.x
	local y = raw.Y or raw.y
	local z = raw.Z or raw.z
	if x and y and z then
		if raw.R00 ~= nil then
			return CFrame.new(x, y, z, raw.R00, raw.R01, raw.R02, raw.R10, raw.R11, raw.R12, raw.R20, raw.R21, raw.R22)
		end
		local rx = raw.RX or raw.rx or raw.Rx
		local ry = raw.RY or raw.ry or raw.Ry
		local rz = raw.RZ or raw.rz or raw.Rz
		if rx and ry and rz then
			return CFrame.new(x, y, z) * CFrame.fromOrientation(math.rad(rx), math.rad(ry), math.rad(rz))
		end
		return CFrame.new(x, y, z)
	end

	if raw[1] and raw[2] and raw[3] and type(raw[1]) == "number" then
		if raw[7] and type(raw[7]) == "number" then
			return CFrame.new(raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12])
		end
		return CFrame.new(raw[1], raw[2], raw[3])
	end

	return nil
end

local function tryGetMoon2FrameRaw(saveRoot: Instance, itemIndex: number, prop: string, frame: number): any?
	return deepSelectMoonPath(saveRoot, {
		tostring(itemIndex),
		prop,
		tostring(frame),
		"Values",
		"0",
		"Value",
	})
end

local function findMoonJsonSave(export: Instance): (Instance?, any?)
	local roots: { Instance } = { export }
	local frames = export:FindFirstChild("Frames")
	if frames then
		table.insert(roots, frames)
	end
	if export.Parent then
		table.insert(roots, export.Parent)
	end

	for _, root in roots do
		if root:IsA("StringValue") then
			local ok, data = pcall(HttpService.JSONDecode, HttpService, root.Value)
			if ok and type(data) == "table" and data.Information and data.Items then
				return root, data
			end
		end
		for _, desc in root:GetDescendants() do
			if desc:IsA("StringValue") and string.sub(desc.Value, 1, 1) == "{" then
				local ok, data = pcall(HttpService.JSONDecode, HttpService, desc.Value)
				if ok and type(data) == "table" and data.Information and data.Items then
					return desc, data
				end
			end
		end
	end
	return nil, nil
end

local function findCameraItemIndex(items: { any }): number?
	for i, item in items do
		if type(item) ~= "table" then
			continue
		end
		local path = item.Path
		if type(path) ~= "table" then
			continue
		end
		local names = path.InstanceNames
		if type(names) == "table" and #names > 0 then
			local last = names[#names]
			if last == "CurrentCamera" or last == "Camera" then
				return i
			end
		end
		if path.ItemType == "Camera" then
			return i
		end
	end
	return nil
end

local function parseMoonJsonFrames(saveRoot: Instance, data: any): { CFrame }?
	local items = data.Items
	local info = data.Information
	if type(items) ~= "table" or type(info) ~= "table" then
		return nil
	end

	local itemIdx = findCameraItemIndex(items)
	if not itemIdx then
		return nil
	end

	local length = info.Length
	if type(length) ~= "number" then
		length = 120
	end
	length = math.max(0, math.floor(length))

	local frames: { CFrame } = {}
	local lastCf: CFrame? = nil
	for f = 0, length do
		local raw = tryGetMoon2FrameRaw(saveRoot, itemIdx, "CFrame", f)
		local cf = moonRawToCFrame(raw)
		if cf then
			lastCf = cf
		end
		if lastCf then
			table.insert(frames, lastCf)
		end
	end

	if #frames > 1 then
		return frames
	end
	return nil
end

local function parseMoonItemFolders(export: Instance, maxFrames: number?): { CFrame }?
	local limit = maxFrames or 900
	for itemIdx = 1, 8 do
		local frames: { CFrame } = {}
		local lastCf: CFrame? = nil
		for f = 0, limit do
			local raw = tryGetMoon2FrameRaw(export, itemIdx, "CFrame", f)
			if raw == nil then
				if f == 0 then
					break
				end
				break
			end
			local cf = moonRawToCFrame(raw)
			if cf then
				lastCf = cf
			end
			if lastCf then
				table.insert(frames, lastCf)
			end
		end
		if #frames > 1 then
			return frames
		end
	end
	return nil
end

local function frameSortKey(inst: Instance, framesFolder: Instance, sequence: number): number
	local idx = frameIndexFromName(inst.Name)
	if idx then
		return idx
	end
	local parent = inst.Parent
	while parent and parent ~= framesFolder do
		idx = frameIndexFromName(parent.Name)
		if idx then
			return idx
		end
		parent = parent.Parent
	end
	return sequence
end

local function cframeFromMoonFrameFolder(frameFolder: Instance): CFrame?
	if frameFolder:IsA("CFrameValue") then
		return frameFolder.Value
	end

	local attr = frameFolder:GetAttribute("CFrame")
	if typeof(attr) == "CFrame" then
		return attr
	end

	for _, name in { "CFrame", "CF", "Value" } do
		local ch = frameFolder:FindFirstChild(name)
		if ch and ch:IsA("CFrameValue") then
			return ch.Value
		end
	end

	for _, desc in frameFolder:GetDescendants() do
		if desc:IsA("CFrameValue") and not SKIP_MOON_FRAME_NAMES[desc.Name] then
			return desc.Value
		end
	end

	local raw = deepSelectMoonPath(frameFolder, { "CFrame", "Values", "0", "Value" })
		or deepSelectMoonPath(frameFolder, { "Values", "0", "Value" })
	if raw then
		return moonRawToCFrame(raw)
	end

	return nil
end

-- Moon export: Frames["0"], Frames["1"], ... each folder holds one keyframe.
local function parseMoonNumberedFrameFolders(framesFolder: Instance): { CFrame }
	local keyed: { { sortKey: number, cf: CFrame } } = {}

	for _, child in framesFolder:GetChildren() do
		if SKIP_MOON_FRAME_NAMES[child.Name] then
			continue
		end
		local idx = tonumber(child.Name)
		if idx == nil then
			continue
		end
		local cf = cframeFromMoonFrameFolder(child)
		if cf then
			table.insert(keyed, { sortKey = idx, cf = cf })
		end
	end

	table.sort(keyed, function(a, b)
		return a.sortKey < b.sortKey
	end)

	local frames: { CFrame } = {}
	for i, item in ipairs(keyed) do
		frames[i] = item.cf
	end
	return frames
end

local function parseMoonFramesOrdered(framesFolder: Instance): { CFrame }
	local frames: { CFrame } = {}
	for _, child in framesFolder:GetChildren() do
		if child:IsA("CFrameValue") and not SKIP_MOON_FRAME_NAMES[child.Name] then
			table.insert(frames, child.Value)
		end
	end
	return frames
end

local function parseMoonFramesFolder(framesFolder: Instance): { CFrame }
	local numbered = parseMoonNumberedFrameFolders(framesFolder)
	if #numbered > 1 then
		return numbered
	end

	-- Moon Studio export: direct CFrameValue children in timeline order.
	local ordered = parseMoonFramesOrdered(framesFolder)
	if #ordered > 1 then
		return ordered
	end

	-- Moon often nests every keyframe under one subfolder; collect ALL CFrameValues.
	local keyed: { { sortKey: number, cf: CFrame } } = {}
	local seenAtKey: { [number]: boolean } = {}
	local sequence = 0

	local scanned = 0
	for _, desc in framesFolder:GetDescendants() do
		scanned += 1
		if scanned % 400 == 0 then
			task.wait()
		end
		if not desc:IsA("CFrameValue") or SKIP_MOON_FRAME_NAMES[desc.Name] then
			continue
		end
		sequence += 1
		local sortKey = frameSortKey(desc, framesFolder, sequence)
		if seenAtKey[sortKey] then
			sortKey = sequence + 100000
		else
			seenAtKey[sortKey] = true
		end
		table.insert(keyed, { sortKey = sortKey, cf = desc.Value })
	end

	if #keyed == 0 then
		local order = 0
		for _, child in framesFolder:GetChildren() do
			if SKIP_MOON_FRAME_NAMES[child.Name] then
				continue
			end
			if child:IsA("CFrameValue") then
				order += 1
				table.insert(keyed, { sortKey = frameIndexFromName(child.Name) or order, cf = child.Value })
			end
		end
	end

	table.sort(keyed, function(a, b)
		return a.sortKey < b.sortKey
	end)

	local frames: { CFrame } = {}
	for i, item in ipairs(keyed) do
		frames[i] = item.cf
	end
	return frames
end

local function collectMoonCFramesFromRoot(root: Instance, framesFolder: Instance?): { CFrame }
	local keyed: { { sortKey: number, cf: CFrame } } = {}
	local seenAtKey: { [number]: boolean } = {}
	local sequence = 0
	local sortRoot = framesFolder or root

	local scanned = 0
	for _, desc in root:GetDescendants() do
		scanned += 1
		if scanned % 400 == 0 then
			task.wait()
		end
		if not desc:IsA("CFrameValue") or SKIP_MOON_FRAME_NAMES[desc.Name] then
			continue
		end
		sequence += 1
		local sortKey = frameSortKey(desc, sortRoot, sequence)
		if seenAtKey[sortKey] then
			sortKey = sequence + 100000
		else
			seenAtKey[sortKey] = true
		end
		table.insert(keyed, { sortKey = sortKey, cf = desc.Value })
	end

	table.sort(keyed, function(a, b)
		return a.sortKey < b.sortKey
	end)

	local frames: { CFrame } = {}
	for i, item in ipairs(keyed) do
		frames[i] = item.cf
	end
	return frames
end

local function framesHaveMotion(frames: { CFrame }): boolean
	if #frames < 2 then
		return false
	end
	local first = frames[1]
	for i = 2, #frames do
		local cf = frames[i]
		if (cf.Position - first.Position).Magnitude > 0.35 then
			return true
		end
		if cf.LookVector:Dot(first.LookVector) < 0.998 then
			return true
		end
	end
	return false
end

local function normalizeMoonFrames(frames: { CFrame }, refCamera: Camera?): { CFrame }
	if #frames == 0 then
		return frames
	end

	local maxPos = 0
	for _, cf in frames do
		maxPos = math.max(maxPos, cf.Position.Magnitude)
	end

	-- Moon sometimes exports camera-local offsets; anchor to the Studio reference camera.
	if maxPos < 120 and refCamera then
		local refCf = refCamera.CFrame
		if refCf.Position.Magnitude > 50 then
			local out: { CFrame } = table.create(#frames)
			for i, cf in ipairs(frames) do
				out[i] = refCf * cf
			end
			if framesHaveMotion(out) then
				return out
			end
		end
	end

	return frames
end

local function parseMoonFovFolder(fovFolder: Instance?, frameCount: number, defaultFov: number): { number }
	local fovs = table.create(frameCount, defaultFov)
	if not fovFolder or frameCount <= 0 then
		return fovs
	end

	for _, desc in fovFolder:GetDescendants() do
		if desc:IsA("NumberValue") or desc:IsA("IntValue") then
			local idx = frameIndexFromName(desc.Name)
			if idx then
				local slot = idx
				if slot >= 0 and slot < frameCount then
					slot += 1
				end
				if slot >= 1 and slot <= frameCount then
					fovs[slot] = desc.Value
				end
			end
		end
	end

	for i = 2, frameCount do
		if fovs[i] == defaultFov then
			fovs[i] = fovs[i - 1]
		end
	end
	return fovs
end

local function loadMoonCameraTrack(export: Instance, defaultFov: number, refCamera: Camera?): MoonCameraTrack?
	local frames: { CFrame } = {}
	local framesFolder = export:FindFirstChild("Frames")
	if framesFolder then
		frames = parseMoonFramesFolder(framesFolder)
	end

	if #frames <= 1 then
		frames = collectMoonCFramesFromRoot(export, framesFolder)
	end

	local cameraHolder = export.Parent
	if #frames <= 1 and cameraHolder then
		frames = collectMoonCFramesFromRoot(cameraHolder, framesFolder)
	end

	if #frames <= 1 and cameraHolder and cameraHolder ~= export then
		local holderFrames = parseMoonItemFolders(cameraHolder, nil)
		if holderFrames then
			frames = holderFrames
		end
	end

	local jsonRoot, jsonData = findMoonJsonSave(export)
	if #frames <= 1 and jsonRoot and jsonData then
		local jsonFrames = parseMoonJsonFrames(jsonRoot, jsonData)
		if jsonFrames then
			frames = jsonFrames
		end
	end

	if #frames <= 1 then
		local folderFrames = parseMoonItemFolders(export, nil)
		if folderFrames then
			frames = folderFrames
		end
	end

	if #frames <= 1 and jsonRoot and jsonData then
		local folderFrames = parseMoonItemFolders(jsonRoot, jsonData.Information and jsonData.Information.Length)
		if folderFrames then
			frames = folderFrames
		end
	end

	frames = normalizeMoonFrames(frames, refCamera)

	if #frames == 0 then
		local framesFolder = export:FindFirstChild("Frames")
		local childCount = if framesFolder then #framesFolder:GetChildren() else 0
		warn(
			"[LoadingScreenController] No Moon camera frames parsed from",
			if framesFolder then framesFolder:GetFullName() else export:GetFullName(),
			"(",
			childCount,
			"frame folders — each needs a CFrameValue inside)"
		)
		return nil
	end
	if #frames == 1 or not framesHaveMotion(frames) then
		warn(
			"[LoadingScreenController] Moon camera has no motion (",
			#frames,
			"frames) — re-export with multiple camera keyframes in Moon Animator"
		)
		return nil
	end

	local settings = export:FindFirstChild("Settings")
	local fps = 60
	if settings then
		for _, desc in settings:GetDescendants() do
			if desc:IsA("NumberValue") or desc:IsA("IntValue") then
				local nameLower = string.lower(desc.Name)
				if string.find(nameLower, "fps", 1, true) or nameLower == "framerate" then
					fps = desc.Value
					break
				end
			end
		end
	end
	if jsonData and jsonData.Information then
		local info = jsonData.Information
		if type(info.FPS) == "number" then
			fps = info.FPS
		elseif type(info.fps) == "number" then
			fps = info.fps
		end
	end
	if settings then
		fps = readSettingNumber(settings, { "FPS", "Framerate", "FrameRate", "fps" }) or fps
	end
	fps = math.clamp(fps, 12, 120)

	local fovFolder = export:FindFirstChild("FOV")
	local fovs = parseMoonFovFolder(fovFolder, #frames, defaultFov)

	return {
		frames = frames,
		fov = fovs,
		fps = fps,
	}
end

local function sampleMoonCameraTrack(track: MoonCameraTrack, elapsed: number, loopPlayback: boolean): (CFrame, number)
	local frameCount = #track.frames
	if frameCount <= 0 then
		return defaultLoadingCFrame(), 70
	end
	if frameCount == 1 then
		return track.frames[1], track.fov[1]
	end

	local clipDuration = (frameCount - 1) / track.fps
	-- Slow playback so the flyover fills the longer loading window.
	local t = elapsed / MOON_PLAYBACK_SCALE
	if clipDuration > 0.05 then
		if loopPlayback then
			t = t % clipDuration
		else
			t = math.min(t, clipDuration)
		end
	end

	local framePos = math.max(0, t * track.fps)
	local maxIndex = frameCount - 1
	local idx0 = math.clamp(math.floor(framePos), 0, maxIndex)
	local idx1 = math.min(idx0 + 1, maxIndex)
	local alpha = framePos - idx0

	local cf = track.frames[idx0 + 1]:Lerp(track.frames[idx1 + 1], alpha)
	local fov = track.fov[idx0 + 1] + (track.fov[idx1 + 1] - track.fov[idx0 + 1]) * alpha
	return cf, fov
end

local function startLoadingCameraLock(camera: Camera, loadingGui: ScreenGui): () -> ()
	loadedMoonTrack = nil
	local ref = findReferenceCamera(StarterGui:FindFirstChild("LoadingScreen")) or findReferenceCamera(loadingGui)
	local defaultFov = if ref then ref.FieldOfView else camera.FieldOfView

	local starterScreen = waitForStarterLoadingScreen()
	local export = findMoonCameraExport(loadingGui)
	local track = if export then loadMoonCameraTrack(export, defaultFov, ref) else nil

	if track then
		loadedMoonTrack = track
		if not cameraClipStartedAt then
			cameraClipStartedAt = os.clock()
		end
		local bindName = "LoadingScreenMoonCamera"
		local clipSec = moonClipDurationSec(track)
		local function applyAnimated()
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CameraSubject = nil
			local clipStart = cameraClipStartedAt or os.clock()
			local cf, fov = sampleMoonCameraTrack(track, os.clock() - clipStart, false)
			camera.CFrame = cf
			camera.FieldOfView = fov
			camera.Focus = cf
		end

		applyAnimated()

		RunService:BindToRenderStep(bindName, Enum.RenderPriority.Last.Value, applyAnimated)

		return function()
			RunService:UnbindFromRenderStep(bindName)
		end
	elseif export then
		warn(
			"[LoadingScreenController] Moon export found but not playable — check Camera loading/Frames for multiple CFrameValues"
		)
	else
		warn("[LoadingScreenController] No Moon export — using static loading camera pose")
		warn("[LoadingScreenController] StarterGui:", describeLoadingScreenForMoon(starterScreen))
		warn("[LoadingScreenController] PlayerGui:", describeLoadingScreenForMoon(loadingGui))
		local pgExport = loadingGui:FindFirstChild("Camera loading", true)
		local sgExport = if starterScreen then starterScreen:FindFirstChild("Camera loading", true) else nil
		warn(
			"[LoadingScreenController] Camera loading found?",
			"PlayerGui=",
			pgExport ~= nil,
			"StarterGui=",
			sgExport ~= nil
		)
	end

	local loadingCFrame = resolveLoadingCFrame(loadingGui)
	local fov = defaultFov

	local function applyStatic()
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = fov
		camera.CFrame = loadingCFrame
		camera.Focus = loadingCFrame
	end

	applyStatic()

	local conn = RunService.RenderStepped:Connect(function()
		applyStatic()
	end)

	return function()
		conn:Disconnect()
	end
end

local function bootstrapLoadingVisuals(loadingGui: ScreenGui, player: Player)
	ensureSolidCover(loadingGui)
	ensureBlurOverlay(loadingGui)
	ensureLoadingBlur()

	local camera = Workspace.CurrentCamera
	if camera and not stopCameraLock then
		if not cameraClipStartedAt then
			cameraClipStartedAt = os.clock()
		end
		stopCameraLock = startLoadingCameraLock(camera, loadingGui)
	end

	bindCharacterHideWhileLoading(player)
	earlyVisualsReady = true
end

local function wrapAsScreenGui(source: Instance, playerGui: PlayerGui): ScreenGui
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LoadingScreen"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 5000
	screenGui.Parent = playerGui

	local copy = source:Clone()
	for _, child in copy:GetChildren() do
		child.Parent = screenGui
	end
	copy:Destroy()

	return screenGui
end

local function cloneStarterLoadingScreen(playerGui: PlayerGui): ScreenGui?
	local template = StarterGui:FindFirstChild("LoadingScreen")
	if not template then
		return nil
	end

	if template:IsA("ScreenGui") then
		local existing = playerGui:FindFirstChild("LoadingScreen")
		if existing and existing:IsA("ScreenGui") then
			return existing
		end
		local clone = template:Clone()
		clone.Parent = playerGui
		return clone
	end

	local existing = playerGui:FindFirstChild("LoadingScreen")
	if existing and existing:IsA("ScreenGui") then
		return existing
	end
	return wrapAsScreenGui(template, playerGui)
end

local function findLoadingScreenGui(playerGui: PlayerGui): ScreenGui?
	local direct = playerGui:FindFirstChild("LoadingScreen")
	if direct and direct:IsA("ScreenGui") then
		return direct
	end
	return cloneStarterLoadingScreen(playerGui)
end

local function beginLoadingCameraIfPossible()
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	local loadingGui = findLoadingScreenGui(playerGui)
	if not loadingGui then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if stopCameraLock then
		return
	end
	stopCameraLock = startLoadingCameraLock(camera, loadingGui)
end

local function resolveLoadingScreenGui(playerGui: PlayerGui): ScreenGui?
	local deadline = os.clock() + RESOLVE_TIMEOUT

	while os.clock() < deadline do
		local direct = playerGui:FindFirstChild("LoadingScreen")
		if direct and direct:IsA("ScreenGui") then
			return direct
		end

		local cloned = cloneStarterLoadingScreen(playerGui)
		if cloned then
			return cloned
		end

		local scanned = 0
		for _, desc in playerGui:GetDescendants() do
			scanned += 1
			if scanned % 400 == 0 then
				task.wait()
			end
			if desc.Name == "LoadingScreen" and desc:IsA("ScreenGui") then
				return desc
			end
		end

		task.wait(0.05)
	end

	return cloneStarterLoadingScreen(playerGui)
end

local function setCoreGuisVisible(visible: boolean)
	for _, coreType in CORE_GUIS_ALWAYS_DISABLED do
		pcall(function()
			StarterGui:SetCoreGuiEnabled(coreType, false)
		end)
	end
	for _, coreType in CORE_GUIS_TO_HIDE do
		pcall(function()
			StarterGui:SetCoreGuiEnabled(coreType, visible)
		end)
	end
end

local function hideNonLoadingScreenGuis(playerGui: PlayerGui)
	for _, child in playerGui:GetChildren() do
		if child:IsA("ScreenGui") and not isLoadingGuiAllowed(child.Name) then
			child.Enabled = false
		end
	end
	local main = playerGui:FindFirstChild("Main")
	if main and main:IsA("ScreenGui") then
		main.Enabled = false
		local sideUI = main:FindFirstChild("SideUI")
		if sideUI and sideUI:IsA("GuiObject") then
			(sideUI :: GuiObject).Visible = false
		end
	end
	local blurGui = playerGui:FindFirstChild("Blur")
	if blurGui and blurGui:IsA("ScreenGui") then
		blurGui.Enabled = false
	end
end

local function enterLoadingIsolation(playerGui: PlayerGui)
	local loadingGui = playerGui:FindFirstChild("LoadingScreen")
	if not loadingGui or not loadingGui:IsA("ScreenGui") then
		return
	end

	loadingActive = true
	setCoreGuisVisible(false)

	PlayerGuiMain.dedupe(playerGui)

	if not savedGuiStates then
		savedGuiStates = {}
		for _, child in playerGui:GetChildren() do
			if child:IsA("ScreenGui") then
				savedGuiStates[child] = child.Enabled
			end
		end
	end

	for _, child in playerGui:GetChildren() do
		if child:IsA("ScreenGui") then
			if isLoadingGuiAllowed(child.Name) then
				child.Enabled = true
			else
				child.Enabled = false
			end
		end
	end
	hideNonLoadingScreenGuis(playerGui)

	if not playerGuiChildConn then
		playerGuiChildConn = playerGui.ChildAdded:Connect(function(child)
			if not loadingActive then
				return
			end
			if child:IsA("ScreenGui") and child.Name == "Main" then
				PlayerGuiMain.dedupe(playerGui)
				-- Keep Main off until exitLoadingIsolation — inventory must not show through loading.
				child.Enabled = false
				return
			end
			if child:IsA("ScreenGui") and not isLoadingGuiAllowed(child.Name) then
				if savedGuiStates then
					savedGuiStates[child] = child.Enabled
				end
				child.Enabled = false
			end
		end)
	end
end

local function prepareGameplayUIBeforeReveal(playerGui: PlayerGui)
	local main = PlayerGuiMain.finalize(playerGui)
	if not main then
		return
	end

	local frames = main:FindFirstChild("Frames")
	if frames then
		for _, ch in frames:GetChildren() do
			if ch:IsA("GuiObject") then
				(ch :: GuiObject).Visible = false
			end
		end
	end

	local sideUI = main:FindFirstChild("SideUI")
	if not sideUI then
		return
	end

	local toolbar = sideUI:FindFirstChild("Toolbar")
	if toolbar and toolbar:IsA("GuiObject") then
		local toolbarGui = toolbar :: GuiObject
		toolbarGui.Visible = false
		local backpack = toolbar:FindFirstChild("Backpack")
		if backpack and backpack:IsA("GuiObject") then
			(backpack :: GuiObject).Visible = false
		end
		local hotbar = toolbar:FindFirstChild("Hotbar")
		if hotbar then
			for i = 1, 9 do
				local slot = hotbar:FindFirstChild(tostring(i))
				if slot and slot:IsA("GuiObject") then
					(slot :: GuiObject).Visible = false
				end
			end
			local hotbarIcon = hotbar:FindFirstChild("ToggleBackpackImage")
			if hotbarIcon and hotbarIcon:IsA("GuiObject") then
				(hotbarIcon :: GuiObject).Visible = false
			end
		end
		local toolbarIcon = toolbar:FindFirstChild("ToggleBackpackImage")
		if toolbarIcon and toolbarIcon:IsA("GuiObject") then
			(toolbarIcon :: GuiObject).Visible = false
		end
	end

	local top = sideUI:FindFirstChild("Top")
	if top then
		local currentArea = top:FindFirstChild("CurrentArea")
		if currentArea and currentArea:IsA("GuiObject") then
			(currentArea :: GuiObject).Visible = false
		end
	end
end

local function fireGameplayReadyCallbacks()
	local callbacks = gameplayReadyCallbacks
	gameplayReadyCallbacks = {}
	for _, fn in callbacks do
		task.defer(fn)
	end
end

local function exitLoadingIsolation(playerGui: PlayerGui)
	loadingActive = false
	unbindCharacterHide()

	if playerGuiChildConn then
		playerGuiChildConn:Disconnect()
		playerGuiChildConn = nil
	end

	prepareGameplayUIBeforeReveal(playerGui)

	if savedGuiStates then
		for gui, wasEnabled in savedGuiStates do
			if gui.Parent and gui.Name ~= "LoadingScreen" then
				-- Always bring Main back; other guis restore prior state.
				if gui.Name == "Main" then
					gui.Enabled = true
				else
					gui.Enabled = wasEnabled
				end
			end
		end
		savedGuiStates = nil
	end

	PlayerGuiMain.finalize(playerGui)
	local main = playerGui:FindFirstChild("Main")
	if main and main:IsA("ScreenGui") then
		main.Enabled = true
		local sideUI = main:FindFirstChild("SideUI")
		if sideUI and sideUI:IsA("GuiObject") then
			(sideUI :: GuiObject).Visible = true
		end
	end

	-- Purchasing is a fullscreen overlay (DisplayOrder 10000); never leave it on after load.
	-- Also hide Studio leftovers Purchasing.Loading / Purchasing.Main that block HUD frames.
	local purchasing = playerGui:FindFirstChild("Purchasing")
	if purchasing then
		if purchasing:IsA("ScreenGui") then
			purchasing.Enabled = false
		end
		for _, child in purchasing:GetChildren() do
			if child.Name ~= "Rainbow" and child:IsA("GuiObject") then
				child.Visible = false
				child.Active = false
			end
		end
	end

	setCoreGuisVisible(true)

	local blurGui = playerGui:FindFirstChild("Blur")
	if blurGui and blurGui:IsA("ScreenGui") then
		blurGui.Enabled = false
	end

	fireGameplayReadyCallbacks()
end

local function cleanupLoadingVisuals(playerGui: PlayerGui, loadingGui: ScreenGui?, overlay: Frame?)
	destroyLightingBlurEffects()

	if overlay and overlay.Parent then
		overlay.Visible = false
		overlay:Destroy()
	end

	if loadingGui and loadingGui.Parent then
		local guiOverlay = loadingGui:FindFirstChild("BlurOverlay")
		if guiOverlay and guiOverlay:IsA("Frame") then
			guiOverlay:Destroy()
		end
		local solidCover = loadingGui:FindFirstChild("SolidCover")
		if solidCover and solidCover:IsA("Frame") then
			solidCover:Destroy()
		end

		local function salvageLogoAndDestroyStack(stackParent: Instance)
			local stack = stackParent:FindFirstChild("LoadingStack")
			if not stack then
				return
			end
			local logo = stack:FindFirstChild("GameNameImage", true) or stack:FindFirstChild("ImageLabel", true)
			if logo and logo:IsA("ImageLabel") then
				logo.Parent = loadingGui
			end
			stack:Destroy()
		end

		local liquid = loadingGui:FindFirstChild("LiquidLayer")
		if liquid then
			liquid:Destroy()
		end
		salvageLogoAndDestroyStack(loadingGui)

		local canvas = loadingGui:FindFirstChild("LoadingFadeCanvas")
		if canvas then
			local canvasLiquid = canvas:FindFirstChild("LiquidLayer")
			if canvasLiquid then
				canvasLiquid:Destroy()
			end
			salvageLogoAndDestroyStack(canvas)
		end
	end

	local blurGui = playerGui:FindFirstChild("Blur")
	if blurGui and blurGui:IsA("ScreenGui") then
		blurGui.Enabled = false
	end
end

local function findGameNameImage(loadingGui: ScreenGui): ImageLabel?
	for _, name in LOGO_NAMES do
		local img = loadingGui:FindFirstChild(name, true)
		if img and img:IsA("ImageLabel") then
			return img
		end
	end
	return nil
end

local function setupFadeCanvas(loadingGui: ScreenGui): CanvasGroup
	-- Keep a CanvasGroup only for legacy Studio chrome fade — crisp text/logo stay OUTSIDE it.
	local existing = loadingGui:FindFirstChild("LoadingFadeCanvas")
	if existing and existing:IsA("CanvasGroup") then
		fadeCanvas = existing
		existing.GroupTransparency = 0
		return existing
	end

	local canvas = Instance.new("CanvasGroup")
	canvas.Name = "LoadingFadeCanvas"
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.Position = UDim2.fromScale(0, 0)
	canvas.BackgroundTransparency = 1
	canvas.BorderSizePixel = 0
	canvas.GroupTransparency = 0
	canvas.ZIndex = 1
	canvas.Parent = loadingGui

	local moveList: { GuiObject } = {}
	for _, child in loadingGui:GetChildren() do
		if
			child:IsA("GuiObject")
			and child ~= canvas
			and child.Name ~= "Camera"
			and child.Name ~= "BlurOverlay"
			and child.Name ~= "SolidCover"
			and child.Name ~= "LiquidLayer"
			and child.Name ~= "LoadingStack"
		then
			table.insert(moveList, child)
		end
	end
	for _, child in moveList do
		child.Parent = canvas
	end

	fadeCanvas = canvas
	return canvas
end

local function hideLoadingChrome(loadingGui: ScreenGui)
	for _, desc in loadingGui:GetDescendants() do
		if desc.Name == "BarArea" or desc.Name == "LoadingBar" then
			desc:Destroy()
		end
	end
	for _, name in HIDE_LOADING_UI_NAMES do
		local inst = loadingGui:FindFirstChild(name, true)
		if inst and inst:IsA("GuiObject") then
			inst.Visible = false
		end
	end
end

-- Crisp UI must NOT live under CanvasGroup (it rasterizes and makes text look low-res).
local function getCrispUiParent(loadingGui: ScreenGui): ScreenGui
	return loadingGui
end

local function findOrCreateStack(loadingGui: ScreenGui): Frame
	local parent = getCrispUiParent(loadingGui)
	-- Migrate old stack out of CanvasGroup if needed.
	local canvas = loadingGui:FindFirstChild("LoadingFadeCanvas")
	if canvas then
		local buried = canvas:FindFirstChild("LoadingStack")
		if buried and buried:IsA("Frame") then
			buried.Parent = parent
		end
	end

	local existing = parent:FindFirstChild("LoadingStack")
	if existing and existing:IsA("Frame") then
		existing.AnchorPoint = Vector2.new(0.5, 0.5)
		existing.Position = UDim2.fromScale(0.5, STACK_CENTER_Y)
		existing.Size = UDim2.fromScale(1, 0)
		existing.ZIndex = 20
		local layout = existing:FindFirstChild("StackLayout")
		if layout and layout:IsA("UIListLayout") then
			layout.Padding = UDim.new(0, STACK_PADDING_PX)
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
		end
		return existing
	end

	local stack = Instance.new("Frame")
	stack.Name = "LoadingStack"
	stack.BackgroundTransparency = 1
	stack.BorderSizePixel = 0
	stack.AnchorPoint = Vector2.new(0.5, 0.5)
	stack.Position = UDim2.fromScale(0.5, STACK_CENTER_Y)
	stack.Size = UDim2.fromScale(1, 0)
	stack.AutomaticSize = Enum.AutomaticSize.Y
	stack.ZIndex = 20
	stack.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.Name = "StackLayout"
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, STACK_PADDING_PX)
	layout.Parent = stack

	return stack
end

local function ensureLiquidLayer(loadingGui: ScreenGui): Frame
	local parent = getCrispUiParent(loadingGui)
	for _, root in { parent, loadingGui:FindFirstChild("LoadingFadeCanvas") } do
		if root then
			local old = root:FindFirstChild("LiquidLayer")
			if old and old:GetAttribute("LiquidStyle") ~= LIQUID_STYLE then
				old:Destroy()
			end
		end
	end

	local existing = parent:FindFirstChild("LiquidLayer")
	if existing and existing:IsA("Frame") and existing:GetAttribute("LiquidStyle") == LIQUID_STYLE then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local layer = Instance.new("Frame")
	layer.Name = "LiquidLayer"
	layer.BackgroundTransparency = 1
	layer.BorderSizePixel = 0
	layer.AnchorPoint = Vector2.new(0, 0)
	layer.Position = UDim2.fromScale(0, 0)
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = 3
	-- Allow big soft blobs to bleed past the edges.
	layer.ClipsDescendants = false
	layer:SetAttribute("LiquidStyle", LIQUID_STYLE)
	layer.Parent = parent

	-- Big soft blobs hug left + right edges only (keep center clear for logo).
	-- { x, y, size }
	local placements = {
		{ -0.02, 0.18, 0.72 },
		{ 1.02, 0.22, 0.68 },
		{ -0.06, 0.58, 0.78 },
		{ 1.06, 0.62, 0.74 },
		{ -0.1, 0.38, 0.62 },
		{ 1.1, 0.42, 0.66 },
	}

	for i = 1, LIQUID_BLOB_COUNT do
		local place = placements[((i - 1) % #placements) + 1]
		local imageId = LIQUID_IMAGE_IDS[((i - 1) % #LIQUID_IMAGE_IDS) + 1]

		local holder = Instance.new("Frame")
		holder.Name = "LiquidBlob" .. i
		holder.BackgroundTransparency = 1
		holder.BorderSizePixel = 0
		holder.AnchorPoint = Vector2.new(0.5, 0.5)
		holder.Position = UDim2.fromScale(place[1], place[2])
		holder.Size = UDim2.fromScale(place[3], place[3])
		holder.Rotation = (i * 31) % 40 - 20
		holder.ZIndex = 3
		holder.Parent = layer

		-- Stacked oversized copies at rising transparency = heavy soft blur look.
		for layerIdx = LIQUID_BLUR_LAYERS, 1, -1 do
			local t = (layerIdx - 1) / math.max(LIQUID_BLUR_LAYERS - 1, 1)
			local grow = 1 + t * 0.55
			local ox = math.sin(layerIdx * 1.7 + i) * t * 0.04
			local oy = math.cos(layerIdx * 1.3 + i) * t * 0.04
			local ghost = Instance.new("ImageLabel")
			ghost.Name = "Blur" .. layerIdx
			ghost.BackgroundTransparency = 1
			ghost.BorderSizePixel = 0
			ghost.Image = imageId
			ghost.ImageTransparency = LIQUID_CORE_TRANSPARENCY
				+ t * (LIQUID_OUTER_TRANSPARENCY - LIQUID_CORE_TRANSPARENCY)
			ghost.ScaleType = Enum.ScaleType.Fit
			ghost.AnchorPoint = Vector2.new(0.5, 0.5)
			ghost.Position = UDim2.fromScale(0.5 + ox, 0.5 + oy)
			ghost.Size = UDim2.fromScale(grow, grow)
			ghost.ZIndex = 3
			ghost.Parent = holder
		end
	end

	task.defer(function()
		local toPreload: { Instance } = {}
		for _, child in layer:GetDescendants() do
			if child:IsA("ImageLabel") then
				table.insert(toPreload, child)
			end
		end
		if #toPreload > 0 then
			local ok, err = pcall(function()
				ContentProvider:PreloadAsync(toPreload)
			end)
			if not ok then
				warn("[LoadingScreenController] liquid preload failed:", err)
			end
		end
	end)

	return layer
end

local function startLiquidAnim(loadingGui: ScreenGui): () -> ()
	local layer = ensureLiquidLayer(loadingGui)
	local blobs: { LiquidBlob } = {}

	for _, child in layer:GetChildren() do
		if child:IsA("Frame") and string.sub(child.Name, 1, 10) == "LiquidBlob" then
			local idx = tonumber(string.match(child.Name, "%d+")) or (#blobs + 1)
			local scaleInst = child:FindFirstChild("BlobScale")
			if not scaleInst or not scaleInst:IsA("UIScale") then
				scaleInst = Instance.new("UIScale")
				scaleInst.Name = "BlobScale"
				scaleInst.Parent = child
			end
			-- Keep drift mostly vertical so they stay left/right.
			local onLeft = child.Position.X.Scale < 0.5
			table.insert(blobs, {
				gui = child,
				baseX = child.Position.X.Scale,
				baseY = child.Position.Y.Scale,
				speed = (0.008 + (idx % 5) * 0.003) * LIQUID_SPEED_MUL,
				ampY = 0.06 + (idx % 3) * 0.02,
				ampX = if onLeft then 0.035 else 0.035,
				phase = idx * 1.37,
				rotSpeed = 2.2 + (idx % 4) * 1.1,
				baseScale = 1,
			})
		end
	end

	local t = 0
	local conn = RunService.RenderStepped:Connect(function(dt)
		if not loadingActive then
			return
		end
		t += dt
		for _, blob in blobs do
			if not blob.gui.Parent then
				continue
			end
			local wave = t * blob.speed + blob.phase
			local x = blob.baseX + math.sin(wave * 0.55) * blob.ampX
			local y = blob.baseY + math.sin(wave * 0.7 + 0.6) * blob.ampY
			-- Clamp so blobs never crawl into the center.
			if blob.baseX < 0.5 then
				x = math.clamp(x, -0.15, 0.22)
			else
				x = math.clamp(x, 0.78, 1.15)
			end
			blob.gui.Position = UDim2.fromScale(x, y)
			blob.gui.Rotation = math.sin(wave * 0.28) * blob.rotSpeed
			local scaleInst = blob.gui:FindFirstChild("BlobScale")
			if scaleInst and scaleInst:IsA("UIScale") then
				scaleInst.Scale = 0.94 + 0.1 * (0.5 + 0.5 * math.sin(wave * 0.65))
			end
		end
	end)

	return function()
		conn:Disconnect()
	end
end

local function applyCrispLabel(label: TextLabel, textSize: number, bold: boolean)
	label.TextScaled = false
	label.RichText = false
	label.TextSize = textSize
	label.FontFace = if bold
		then Font.fromEnum(Enum.Font.GothamBold)
		else Font.fromEnum(Enum.Font.GothamMedium)
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint then
		constraint:Destroy()
	end
end

local function ensureGameNameVisible(loadingGui: ScreenGui)
	local logo = findGameNameImage(loadingGui)
	if not logo then
		return
	end

	local aspectAttr = logo:GetAttribute("AspectRatio")
	local titleAspect = if typeof(aspectAttr) == "number" and aspectAttr > 0 then aspectAttr else TITLE_DEFAULT_ASPECT
	local maxW = if UserInputService.TouchEnabled then TITLE_MAX_WIDTH_MOBILE else TITLE_MAX_WIDTH_DESKTOP
	local slotH = math.floor(maxW / titleAspect)

	local stack = findOrCreateStack(loadingGui)
	local logoSlot = stack:FindFirstChild("LogoSlot")
	if not logoSlot or not logoSlot:IsA("Frame") then
		logoSlot = Instance.new("Frame")
		logoSlot.Name = "LogoSlot"
		logoSlot.BackgroundTransparency = 1
		logoSlot.BorderSizePixel = 0
		logoSlot.LayoutOrder = 1
		logoSlot.ZIndex = 21
		logoSlot.Parent = stack
	end
	logoSlot.Size = UDim2.fromOffset(maxW, slotH)
	logoSlot.AnchorPoint = Vector2.new(0.5, 0.5)

	logo.Visible = true
	logo.ScaleType = Enum.ScaleType.Fit
	logo.BackgroundTransparency = 1
	logo.AnchorPoint = Vector2.new(0.5, 0.5)
	logo.Position = UDim2.fromScale(0.5, 0.5)
	logo.Size = UDim2.fromScale(1, 1)
	logo.Parent = logoSlot
	logo.LayoutOrder = 1
	logo.ZIndex = 22

	local aspect = logo:FindFirstChild("TitleAspectLock")
	if not aspect or not aspect:IsA("UIAspectRatioConstraint") then
		aspect = Instance.new("UIAspectRatioConstraint")
		aspect.Name = "TitleAspectLock"
		aspect.Parent = logo
	end
	local aspectLock = aspect :: UIAspectRatioConstraint
	aspectLock.AspectRatio = titleAspect
	aspectLock.AspectType = Enum.AspectType.FitWithinMaxSize
	aspectLock.DominantAxis = Enum.DominantAxis.Width

	local sizeConstraint = logoSlot:FindFirstChild("TitleSizeCap")
	if not sizeConstraint or not sizeConstraint:IsA("UISizeConstraint") then
		sizeConstraint = Instance.new("UISizeConstraint")
		sizeConstraint.Name = "TitleSizeCap"
		sizeConstraint.Parent = logoSlot
	end
	local sizeCap = sizeConstraint :: UISizeConstraint
	sizeCap.MaxSize = Vector2.new(maxW, slotH)
end

local function ensureSleekLoadingUI(loadingGui: ScreenGui)
	ensureLiquidLayer(loadingGui)
	local stack = findOrCreateStack(loadingGui)

	local loadingLabel = stack:FindFirstChild("LoadingText")
	if not loadingLabel or not loadingLabel:IsA("TextLabel") then
		loadingLabel = Instance.new("TextLabel")
		loadingLabel.Name = "LoadingText"
		loadingLabel.BackgroundTransparency = 1
		loadingLabel.BorderSizePixel = 0
		loadingLabel.LayoutOrder = 2
		loadingLabel.ZIndex = 21
		loadingLabel.Text = "Loading"
		loadingLabel.TextColor3 = LOADING_TEXT_COLOR
		loadingLabel.TextTransparency = 0
		loadingLabel.TextXAlignment = Enum.TextXAlignment.Center
		loadingLabel.TextYAlignment = Enum.TextYAlignment.Center
		loadingLabel.Parent = stack
	end
	local loadLbl = loadingLabel :: TextLabel
	loadLbl.Size = UDim2.fromOffset(440, 30)
	loadLbl.AutomaticSize = Enum.AutomaticSize.None
	loadLbl.TextColor3 = LOADING_TEXT_COLOR
	applyCrispLabel(loadLbl, LOADING_TEXT_SIZE, true)

	local barW = if UserInputService.TouchEnabled then BAR_WIDTH_MOBILE else BAR_WIDTH_DESKTOP
	local barTrack = stack:FindFirstChild("ProgressTrack")
	if barTrack and barTrack:IsA("Frame") and barTrack:GetAttribute("BarStyle") ~= "outlined_v1" then
		barTrack:Destroy()
		barTrack = nil
	end
	if not barTrack or not barTrack:IsA("Frame") then
		barTrack = Instance.new("Frame")
		barTrack.Name = "ProgressTrack"
		barTrack.BackgroundColor3 = BAR_TRACK_COLOR
		barTrack.BackgroundTransparency = 0.08
		barTrack.BorderSizePixel = 0
		barTrack.LayoutOrder = 3
		barTrack.ZIndex = 21
		barTrack.ClipsDescendants = true
		barTrack:SetAttribute("BarStyle", "outlined_v1")
		barTrack.Parent = stack

		local trackCorner = Instance.new("UICorner")
		trackCorner.CornerRadius = UDim.new(1, 0)
		trackCorner.Parent = barTrack

		local outline = Instance.new("UIStroke")
		outline.Name = "BarOutline"
		outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		outline.Color = BAR_OUTLINE_COLOR
		outline.Transparency = BAR_OUTLINE_TRANSPARENCY
		outline.Thickness = BAR_OUTLINE_THICKNESS
		outline.Parent = barTrack

		local fill = Instance.new("Frame")
		fill.Name = "ProgressFill"
		fill.BackgroundColor3 = BAR_FILL_COLOR
		fill.BackgroundTransparency = 0
		fill.BorderSizePixel = 0
		fill.AnchorPoint = Vector2.new(0, 0.5)
		fill.Position = UDim2.new(0, 3, 0.5, 0)
		fill.Size = UDim2.new(0.08, -6, 1, -6)
		fill.ZIndex = 22
		fill.Parent = barTrack

		local fillCorner = Instance.new("UICorner")
		fillCorner.CornerRadius = UDim.new(1, 0)
		fillCorner.Parent = fill

		local fillGrad = Instance.new("UIGradient")
		fillGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, BAR_FILL_COLOR),
			ColorSequenceKeypoint.new(0.5, BAR_FILL_HIGHLIGHT),
			ColorSequenceKeypoint.new(1, BAR_FILL_COLOR),
		})
		fillGrad.Rotation = 90
		fillGrad.Parent = fill
	end
	;(barTrack :: Frame).Size = UDim2.fromOffset(barW, BAR_HEIGHT_PX)

	local fill = (barTrack :: Frame):FindFirstChild("ProgressFill")
	if fill and fill:IsA("Frame") then
		loadingBarFill = fill
		local shown = 0.06 + math.clamp(loadingProgress, 0, 1) * 0.94
		fill.Size = UDim2.new(shown, -6, 1, -6)
	end

	local hintLabel = stack:FindFirstChild("LoadingHint")
	if not hintLabel or not hintLabel:IsA("TextLabel") then
		hintLabel = Instance.new("TextLabel")
		hintLabel.Name = "LoadingHint"
		hintLabel.BackgroundTransparency = 1
		hintLabel.BorderSizePixel = 0
		hintLabel.LayoutOrder = 4
		hintLabel.ZIndex = 21
		hintLabel.Text = "[" .. LOADING_HINTS[1] .. "]"
		hintLabel.TextColor3 = HINT_TEXT_COLOR
		hintLabel.TextTransparency = 0.05
		hintLabel.TextXAlignment = Enum.TextXAlignment.Center
		hintLabel.TextYAlignment = Enum.TextYAlignment.Center
		hintLabel.Parent = stack
	end
	local hintLbl = hintLabel :: TextLabel
	hintLbl.Size = UDim2.fromOffset(560, 26)
	hintLbl.TextColor3 = HINT_TEXT_COLOR
	hintLbl.TextTransparency = 0.05
	applyCrispLabel(hintLbl, HINT_TEXT_SIZE, false)
end

local function setLoadingProgress(alpha: number)
	loadingProgress = math.clamp(alpha, 0, 1)
	local fill = loadingBarFill
	if fill and fill.Parent then
		-- Keep a tiny visible nub at the start so the bar never looks empty.
		local shown = 0.06 + loadingProgress * 0.94
		fill.Size = UDim2.new(shown, -6, 1, -6)
	end
end

local function startGameNameSubtitleAnim(loadingGui: ScreenGui): () -> ()
	local logo = findGameNameImage(loadingGui)
	local stack = findOrCreateStack(loadingGui)
	local loadingLabel = stack:FindFirstChild("LoadingText")
	local hintLabel = stack:FindFirstChild("LoadingHint")

	local wrapScale: UIScale? = nil
	if logo then
		local oldScale = logo:FindFirstChildOfClass("UIScale")
		if oldScale and oldScale.Name ~= "TitleAnimScale" then
			oldScale:Destroy()
		end

		local scaleInst = logo:FindFirstChild("TitleAnimScale")
		if not scaleInst or not scaleInst:IsA("UIScale") then
			scaleInst = Instance.new("UIScale")
			scaleInst.Name = "TitleAnimScale"
			scaleInst.Parent = logo
		end
		wrapScale = scaleInst :: UIScale
		logo.Rotation = 0
		wrapScale.Scale = ENTRANCE_SCALE_START
		logo.ImageTransparency = 1
		logo.Position = UDim2.fromScale(0.5, 0.5)
	end

	if loadingLabel and loadingLabel:IsA("TextLabel") then
		loadingLabel.TextTransparency = 1
	end
	if hintLabel and hintLabel:IsA("TextLabel") then
		hintLabel.TextTransparency = 1
	end

	local entranceStart = os.clock()
	local entranceDone = false
	local idlePhase = 0
	local ellipsisPhase = 0
	local hintIndex = 1
	local hintTimer = 0
	local hintFade = 0

	local conn = RunService.RenderStepped:Connect(function(dt)
		if not loadingActive then
			return
		end

		if not entranceDone then
			local elapsed = os.clock() - entranceStart
			local t = math.clamp(elapsed / ENTRANCE_DURATION, 0, 1)
			local eased = 1 - (1 - t) ^ 3
			if wrapScale and logo and logo.Parent then
				wrapScale.Scale = ENTRANCE_SCALE_START + (1 - ENTRANCE_SCALE_START) * eased
				logo.ImageTransparency = 1 - eased
			end
			if loadingLabel and loadingLabel:IsA("TextLabel") and loadingLabel.Parent then
				loadingLabel.TextTransparency = 1 - eased
			end
			if hintLabel and hintLabel:IsA("TextLabel") and hintLabel.Parent then
				hintLabel.TextTransparency = 1 - eased * 0.92
			end
			if t >= 1 then
				entranceDone = true
				if wrapScale then
					wrapScale.Scale = 1
				end
				if logo and logo.Parent then
					logo.ImageTransparency = 0
				end
				if loadingLabel and loadingLabel:IsA("TextLabel") then
					loadingLabel.TextTransparency = 0
				end
				if hintLabel and hintLabel:IsA("TextLabel") then
					hintLabel.TextTransparency = 0.08
				end
			end
			return
		end

		idlePhase += dt * WOBBLE_JUMP_SPEED
		-- Soft jump (abs sin) + slight rotation wobble + micro scale pulse.
		local jumpWave = math.abs(math.sin(idlePhase * math.pi))
		local rotWave = math.sin(idlePhase * 1.65)
		local scaleWave = math.sin(idlePhase * 1.1)
		if logo and logo.Parent and wrapScale then
			logo.Position = UDim2.new(0.5, 0, 0.5, -jumpWave * WOBBLE_JUMP_PX)
			logo.Rotation = rotWave * WOBBLE_ROT_DEG
			wrapScale.Scale = 1 + scaleWave * WOBBLE_SCALE_AMOUNT + jumpWave * 0.012
		end

		ellipsisPhase += dt
		if loadingLabel and loadingLabel:IsA("TextLabel") and loadingLabel.Parent then
			local dots = math.floor(ellipsisPhase / ELLIPSIS_INTERVAL_SEC) % 4
			loadingLabel.Text = "Loading" .. string.rep(".", dots)
		end

		hintTimer += dt
		if hintLabel and hintLabel:IsA("TextLabel") and hintLabel.Parent then
			if hintTimer >= HINT_INTERVAL_SEC then
				hintTimer = 0
				hintIndex = (hintIndex % #LOADING_HINTS) + 1
				hintLabel.Text = "[" .. LOADING_HINTS[hintIndex] .. "]"
				hintFade = 0.35
			end
			if hintFade > 0 then
				hintFade = math.max(0, hintFade - dt)
				local flash = hintFade / 0.35
				hintLabel.TextTransparency = 0.08 + flash * 0.55
			end
		end
	end)

	return function()
		conn:Disconnect()
		if wrapScale and wrapScale.Parent then
			wrapScale.Scale = 1
		end
		if logo and logo.Parent then
			logo.Rotation = 0
			logo.ImageTransparency = 0
			logo.Position = UDim2.fromScale(0.5, 0.5)
		end
		if loadingLabel and loadingLabel:IsA("TextLabel") and loadingLabel.Parent then
			loadingLabel.Text = "Loading..."
			loadingLabel.TextTransparency = 0
		end
		if hintLabel and hintLabel:IsA("TextLabel") and hintLabel.Parent then
			hintLabel.TextTransparency = 0.08
		end
	end
end

local function preloadGameName(loadingGui: ScreenGui)
	local logo = findGameNameImage(loadingGui)
	if logo and logo.Image ~= "" then
		pcall(function()
			ContentProvider:PreloadAsync({ logo })
		end)
	end
end

local function fadeOutLoadingTogether(
	loadingGui: ScreenGui,
	blur: BlurEffect?,
	camera: Camera?,
	player: Player
)
	if stopNameAnim then
		stopNameAnim()
		stopNameAnim = nil
	end
	if stopLiquidAnim then
		stopLiquidAnim()
		stopLiquidAnim = nil
	end

	local tweens: { Tween } = {}

	local overlay = loadingGui:FindFirstChild("BlurOverlay")
	if overlay and overlay:IsA("GuiObject") then
		table.insert(tweens, TweenService:Create(overlay, FADE_TWEEN_INFO, { BackgroundTransparency = 1 }))
	end

	local canvas = fadeCanvas or loadingGui:FindFirstChild("LoadingFadeCanvas")
	if canvas and canvas:IsA("CanvasGroup") then
		table.insert(tweens, TweenService:Create(canvas, FADE_TWEEN_INFO, { GroupTransparency = 1 }))
	end

	-- Stack + liquid sit outside CanvasGroup for crisp text — fade them directly.
	local function fadeTree(root: Instance?)
		if not root then
			return
		end
		for _, desc in root:GetDescendants() do
			if desc:IsA("TextLabel") or desc:IsA("TextButton") then
				table.insert(tweens, TweenService:Create(desc, FADE_TWEEN_INFO, { TextTransparency = 1 }))
			elseif desc:IsA("ImageLabel") or desc:IsA("ImageButton") then
				table.insert(tweens, TweenService:Create(desc, FADE_TWEEN_INFO, { ImageTransparency = 1 }))
			elseif desc:IsA("Frame") and desc.BackgroundTransparency < 1 then
				table.insert(tweens, TweenService:Create(desc, FADE_TWEEN_INFO, { BackgroundTransparency = 1 }))
			end
		end
	end
	fadeTree(loadingGui:FindFirstChild("LoadingStack"))
	fadeTree(loadingGui:FindFirstChild("LiquidLayer"))

	if blur and blur.Parent then
		table.insert(tweens, TweenService:Create(blur, FADE_TWEEN_INFO, { Size = 0 }))
	end

	for _, tween in tweens do
		tween:Play()
	end
	task.wait(FADE_OUT_SEC)

	-- Keep LoadingScreen.Enabled true until exitLoadingIsolation finishes in run().
	-- Disabling it here raced OfflineEarnings / other join UI before Main was restored.
	fadeCanvas = nil

	if camera then
		restoreGameplayCamera(camera, player)
	end
end

function M.showEarly()
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local playerGui = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return
	end

	loadingActive = true
	setCoreGuisVisible(false)
	hideNonLoadingScreenGuis(playerGui)

	local loadingGui = findLoadingScreenGui(playerGui)
	if loadingGui then
		loadingGui.Enabled = true
		loadingGui.DisplayOrder = 5000
		loadingGui.ResetOnSpawn = false
		loadingGui.IgnoreGuiInset = true
		pcall(function()
			loadingGui.ScreenInsets = Enum.ScreenInsets.None
		end)
	else
		-- No LoadingScreen GUI yet — still block the default gameplay camera immediately.
		local camera = Workspace.CurrentCamera
		if camera then
			camera.CameraType = Enum.CameraType.Scriptable
			local loadingCFrame = defaultLoadingCFrame()
			camera.CFrame = loadingCFrame
			camera.Focus = loadingCFrame
			camera.CameraSubject = nil
		end
	end

	enterLoadingIsolation(playerGui)

	local guiForBootstrap = loadingGui
	task.defer(function()
		if not loadingActive then
			return
		end
		if guiForBootstrap then
			prepareGameplayUIBeforeReveal(playerGui)
			bootstrapLoadingVisuals(guiForBootstrap, player)
		else
			ensureLoadingBlur()
			bindCharacterHideWhileLoading(player)
			earlyVisualsReady = true
		end
	end)
end

function M.run()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui", 30)
	if not playerGui then
		warn("[LoadingScreenController] PlayerGui missing")
		return
	end

	local loadingGui = findLoadingScreenGui(playerGui) or resolveLoadingScreenGui(playerGui)
	if not loadingGui then
		warn("[LoadingScreenController] No StarterGui.LoadingScreen — add ScreenGui with GameNameImage")
		-- showEarly may still have isolation / camera lock active — always release.
		exitLoadingIsolation(playerGui)
		local camera = Workspace.CurrentCamera
		if camera then
			restoreGameplayCamera(camera, player)
		end
		return
	end

	loadingGui.Enabled = true
	loadingGui.ResetOnSpawn = false
	loadingGui.DisplayOrder = 5000
	loadingGui.IgnoreGuiInset = true
	loadingGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		loadingGui.ScreenInsets = Enum.ScreenInsets.None
	end)

	enterLoadingIsolation(playerGui)

	ensureBlurOverlay(loadingGui)
	setupFadeCanvas(loadingGui)
	hideLoadingChrome(loadingGui)
	ensureSleekLoadingUI(loadingGui)
	ensureGameNameVisible(loadingGui)
	setLoadingProgress(0.08)

	if not earlyVisualsReady then
		bootstrapLoadingVisuals(loadingGui, player)
	end

	stopNameAnim = startGameNameSubtitleAnim(loadingGui)
	if stopLiquidAnim then
		stopLiquidAnim()
		stopLiquidAnim = nil
	end
	stopLiquidAnim = startLiquidAnim(loadingGui)
	preloadGameName(loadingGui)

	local camera = Workspace.CurrentCamera
	if not camera then
		camera = Workspace:WaitForChild("Camera", 10) :: Camera?
	end

	local blur = ensureLoadingBlur()

	if camera and not stopCameraLock then
		if not cameraClipStartedAt then
			cameraClipStartedAt = os.clock()
		end
		stopCameraLock = startLoadingCameraLock(camera, loadingGui)
	end

	releaseSolidCover(loadingGui)

	local clipSec = if loadedMoonTrack
		then math.max(moonClipDurationSec(loadedMoonTrack), 0.05)
		else MIN_DISPLAY_SEC - HOLD_AT_FULL_SEC
	local minDisplaySec = clipSec + HOLD_AT_FULL_SEC
	if not loadedMoonTrack and not cameraClipStartedAt then
		cameraClipStartedAt = os.clock()
	end

	local startedAt = cameraClipStartedAt or os.clock()
	while os.clock() - startedAt < minDisplaySec do
		enterLoadingIsolation(playerGui)
		local elapsed = os.clock() - startedAt
		-- Ease toward ~92% during the clip, then finish on hold.
		local t = math.clamp(elapsed / math.max(clipSec, 0.05), 0, 1)
		local eased = 1 - (1 - t) ^ 2
		setLoadingProgress(0.08 + eased * 0.84)
		task.wait(0.05)
	end
	setLoadingProgress(1)
	task.wait(HOLD_AT_FULL_SEC)

	loadingActive = false
	cameraClipStartedAt = nil
	if stopCameraLock then
		stopCameraLock()
		stopCameraLock = nil
	end
	if camera then
		restoreGameplayCamera(camera, player)
	end

	fadeOutLoadingTogether(loadingGui, blur, camera, player)
	cleanupLoadingVisuals(playerGui, loadingGui, nil)
	loadingBarFill = nil

	if stopNameAnim then
		stopNameAnim()
		stopNameAnim = nil
	end
	if stopLiquidAnim then
		stopLiquidAnim()
		stopLiquidAnim = nil
	end

	exitLoadingIsolation(playerGui)
	loadingGui.Enabled = false
	-- Ensure gameplay HUD is interactable after the last isolation pass.
	local main = playerGui:FindFirstChild("Main")
	if main and main:IsA("ScreenGui") then
		main.Enabled = true
		local sideUI = main:FindFirstChild("SideUI")
		if sideUI and sideUI:IsA("GuiObject") then
			(sideUI :: GuiObject).Visible = true
		end
	end
end

function M.isActive(): boolean
	return loadingActive
end

function M.registerOnGameplayReady(callback: () -> ())
	if typeof(callback) ~= "function" then
		return
	end
	if not loadingActive then
		task.defer(callback)
		return
	end
	table.insert(gameplayReadyCallbacks, callback)
end

return M
