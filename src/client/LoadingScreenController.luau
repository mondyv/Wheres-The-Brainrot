-- [ACTIVE] LoadingScreenController
--[[
	LoadingScreenController — full-screen join overlay:
	Moon camera flyover + blur, logo wobble, bottom tips.
	Streaming stays pinned to the player (tight radii + ReplicationFocus) so the
	flyover camera does not pull distant map chunks. No lava blob UI.
	StarterGui.LoadingScreen + GameNameImage. Moon export: "Camera loading" (Frames/0..N).
--]]

local ContentProvider = game:GetService("ContentProvider")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local MIN_DISPLAY_SEC = 1.6
local HOLD_AT_FULL_SEC = 0.4
local FADE_OUT_SEC = 0.9
local FADE_TWEEN_INFO = TweenInfo.new(FADE_OUT_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local RESOLVE_TIMEOUT = 45
-- Hard cap so a long Moon export can never pin the black loading screen forever.
local MAX_LOADING_DISPLAY_SEC = 5.5
-- >1 slows the flyover. Was 2 (half speed); 1.5x faster than that → ~1.33.
local MOON_PLAYBACK_SCALE = 4 / 3

-- Keep stream bubble on the player while the cinematic camera flies elsewhere.
local LOADING_STREAM_MIN_RADIUS = 64
local LOADING_STREAM_TARGET_RADIUS = 96
-- After loading, force these (Studio place often still has 256/512 which keeps
-- half the map + grass resident = high tris). Server Workspace props don't drive client streaming.
local GAMEPLAY_STREAM_MIN_RADIUS = 112
local GAMEPLAY_STREAM_TARGET_RADIUS = 280

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
local STACK_CENTER_Y = 0.48
local HINT_TEXT_SIZE = 16
local HINT_BOTTOM_Y = 0.94

local HINT_TEXT_COLOR = Color3.fromRGB(255, 255, 255)

local HINT_INTERVAL_SEC = 2.15
local WOBBLE_JUMP_SPEED = 2.35
local WOBBLE_ROT_DEG = 4
local WOBBLE_JUMP_PX = 8
local WOBBLE_SCALE_AMOUNT = 0.022

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

local HIDE_LOADING_UI_NAMES = {
	"LoadingFrame",
	"BarPlaceholder",
	"LoadingBar",
	"BarArea",
	"ProgressTrack",
	"ProgressHost",
	"ProgressGlow",
	"ProgressFill",
	"LoadingText",
	"Stud TextureDecal",
	"Stud Texture",
	"StudTexture",
}

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
local _loadingProgress = 0
local savedStreamingMinRadius: number? = nil
local savedStreamingTargetRadius: number? = nil
local streamingGuardActive = false

local function defaultLoadingCFrame(): CFrame
	return CFrame.new(DEFAULT_CAMERA_POS) * CFrame.fromOrientation(DEFAULT_CAMERA_RAD.X, DEFAULT_CAMERA_RAD.Y, DEFAULT_CAMERA_RAD.Z)
end

local function beginLoadingStreamingGuard(player: Player)
	if streamingGuardActive then
		return
	end
	streamingGuardActive = true
	-- Some Studio/runtime builds expose StreamingEnabled but not Min/Target radius.
	-- Never read those properties outside pcall — it aborts the whole loading screen.
	local okStream = pcall(function()
		if Workspace.StreamingEnabled ~= true then
			return
		end
		-- Property may be missing on some Studio builds — only touch inside pcall.
		local wsAny = Workspace :: any
		local minOk, minR = pcall(function()
			return wsAny.StreamingMinRadius
		end)
		local targetOk, targetR = pcall(function()
			return wsAny.StreamingTargetRadius
		end)
		if not minOk or not targetOk or typeof(minR) ~= "number" or typeof(targetR) ~= "number" then
			return
		end
		savedStreamingMinRadius = minR
		savedStreamingTargetRadius = targetR
		wsAny.StreamingMinRadius = LOADING_STREAM_MIN_RADIUS
		wsAny.StreamingTargetRadius = LOADING_STREAM_TARGET_RADIUS
	end)
	if not okStream then
		savedStreamingMinRadius = nil
		savedStreamingTargetRadius = nil
	end
	local char = player.Character
	local focusPart = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
	if focusPart and focusPart:IsA("BasePart") then
		local okFocus, errFocus = pcall(function()
			player.ReplicationFocus = focusPart
		end)
		if not okFocus then
			warn("[LoadingScreenController] ReplicationFocus pin failed:", errFocus)
		end
	end
end

local function endLoadingStreamingGuard(player: Player?)
	if not streamingGuardActive then
		return
	end
	streamingGuardActive = false
	-- Always restore to gameplay radii — ignore Studio's saved 256/512.
	-- Nested pcall: some Studio builds lack StreamingMinRadius entirely.
	local ok, err = pcall(function()
		local ws = Workspace :: any
		local minOk, minR = pcall(function()
			return ws.StreamingMinRadius
		end)
		local targetOk, targetR = pcall(function()
			return ws.StreamingTargetRadius
		end)
		if minOk and targetOk and typeof(minR) == "number" and typeof(targetR) == "number" then
			ws.StreamingMinRadius = GAMEPLAY_STREAM_MIN_RADIUS
			ws.StreamingTargetRadius = GAMEPLAY_STREAM_TARGET_RADIUS
		end
	end)
	if not ok then
		if typeof(err) == "string" and not string.find(err, "StreamingMinRadius", 1, true) and not string.find(err, "rawget", 1, true) then
			warn("[LoadingScreenController] streaming radius restore failed:", err)
		end
	end
	savedStreamingMinRadius = nil
	savedStreamingTargetRadius = nil
	if player and player.Parent then
		local okFocus, errFocus = pcall(function()
			player.ReplicationFocus = nil
		end)
		if not okFocus then
			warn("[LoadingScreenController] ReplicationFocus clear failed:", errFocus)
		end
	end
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

local function _forceReleaseSolidCover(loadingGui: ScreenGui)
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

local function defaultGameplayCameraCFrame(hrp: BasePart): CFrame
	local look = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
	if look.Magnitude < 0.05 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end
	local camPos = hrp.Position - look * 14 + Vector3.new(0, 6, 0)
	local lookAt = hrp.Position + Vector3.new(0, 1.5, 0)
	return CFrame.lookAt(camPos, lookAt)
end

-- Smooth handoff from loading moon cam into normal third-person (no hard cut).
local function settleGameplayCamera(camera: Camera, player: Player, durationSec: number?)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not hrp or not hrp:IsA("BasePart") or not humanoid then
		restoreGameplayCamera(camera, player)
		return
	end

	local dur = math.clamp(durationSec or 0.9, 0.35, 2)
	local startCf = camera.CFrame
	local startFov = camera.FieldOfView
	local goalFov = 70
	camera.CameraType = Enum.CameraType.Scriptable

	local t0 = os.clock()
	while os.clock() - t0 < dur do
		local liveHrp = character:FindFirstChild("HumanoidRootPart")
		if liveHrp and liveHrp:IsA("BasePart") then
			hrp = liveHrp
		end
		local endCf = defaultGameplayCameraCFrame(hrp :: BasePart)
		local alpha = math.clamp((os.clock() - t0) / dur, 0, 1)
		-- Smooth ease-out so it settles softly into place.
		local eased = 1 - (1 - alpha) ^ 3
		camera.CFrame = startCf:Lerp(endCf, eased)
		camera.FieldOfView = startFov + (goalFov - startFov) * eased
		RunService.RenderStepped:Wait()
	end

	restoreGameplayCamera(camera, player)
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

local function _computeLoadingDisplaySec(track: MoonCameraTrack?): number
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
		local framesChildren = export:FindFirstChild("Frames")
		local childCount = if framesChildren then #framesChildren:GetChildren() else 0
		warn(
			"[LoadingScreenController] No Moon camera frames parsed from",
			if framesChildren then framesChildren:GetFullName() else export:GetFullName(),
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

local function startLoadingCameraLock(camera: Camera, loadingGui: ScreenGui, player: Player): () -> ()
	beginLoadingStreamingGuard(player)
	loadedMoonTrack = nil
	local ref = findReferenceCamera(StarterGui:FindFirstChild("LoadingScreen")) or findReferenceCamera(loadingGui)
	local defaultFov = if ref then ref.FieldOfView else camera.FieldOfView

	local starterScreen = waitForStarterLoadingScreen()
	local export = findMoonCameraExport(loadingGui)
	local track = if export then loadMoonCameraTrack(export, defaultFov, ref) else nil

	local function stopGuard()
		endLoadingStreamingGuard(player)
	end

	if track then
		loadedMoonTrack = track
		if not cameraClipStartedAt then
			cameraClipStartedAt = os.clock()
		end
		local bindName = "LoadingScreenMoonCamera"
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
			stopGuard()
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
		stopGuard()
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
		stopCameraLock = startLoadingCameraLock(camera, loadingGui, player)
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

local function _beginLoadingCameraIfPossible()
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
	stopCameraLock = startLoadingCameraLock(camera, loadingGui, player)
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

		-- Do not PlayerGui:GetDescendants() here — HUD is huge and this loop ran every 50ms.
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
		PlayerGuiMain.hideAdminPanelUnlessAllowed(main)
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
		local states: { [ScreenGui]: boolean } = {}
		savedGuiStates = states
		for _, child in playerGui:GetChildren() do
			if child:IsA("ScreenGui") then
				states[child] = child.Enabled
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
				PlayerGuiMain.hideAdminPanelUnlessAllowed(child)
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
	PlayerGuiMain.hideAdminPanelUnlessAllowed(main)

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
		-- Safezone quick-nav (Sell / Base / Upgrade) — controller reveals after load.
		local buttons = top:FindFirstChild("Buttons")
		if buttons and buttons:IsA("GuiObject") then
			(buttons :: GuiObject).Visible = false
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
	endLoadingStreamingGuard(Players.LocalPlayer)

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
		PlayerGuiMain.hideAdminPanelUnlessAllowed(main)
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

	local touchGui = playerGui:FindFirstChild("TouchGui")
	if touchGui and touchGui:IsA("ScreenGui") then
		touchGui.Enabled = true
	end
	pcall(function()
		local MobileTouchGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))
		MobileTouchGate.restorePlayerMovement()
		MobileTouchGate.ensureTouchControlsVisible(true)
	end)

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

		local bottomHint = loadingGui:FindFirstChild("LoadingHint")
		if bottomHint then
			bottomHint:Destroy()
		end

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
			and child.Name ~= "LoadingHint"
			and child.Name ~= "GameNameImage"
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
		if
			desc.Name == "BarArea"
			or desc.Name == "LoadingBar"
			or desc.Name == "ProgressTrack"
			or desc.Name == "ProgressHost"
			or desc.Name == "ProgressGlow"
			or desc.Name == "ProgressFill"
			or desc.Name == "LoadingText"
		then
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

local function destroyLiquidLayers(loadingGui: ScreenGui)
	-- Strip any leftover Studio/legacy lava blob layers completely.
	local liquid = loadingGui:FindFirstChild("LiquidLayer")
	if liquid then
		liquid:Destroy()
	end
	local canvas = loadingGui:FindFirstChild("LoadingFadeCanvas")
	if canvas then
		local canvasLiquid = canvas:FindFirstChild("LiquidLayer")
		if canvasLiquid then
			canvasLiquid:Destroy()
		end
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
	destroyLiquidLayers(loadingGui)
	local stack = findOrCreateStack(loadingGui)

	-- Logo only in the center stack — strip bar / "Loading..." chrome.
	for _, name in { "LoadingText", "ProgressTrack", "ProgressHost", "ProgressGlow", "LoadingHint" } do
		local junk = stack:FindFirstChild(name)
		if junk then
			junk:Destroy()
		end
	end

	local parent = getCrispUiParent(loadingGui)
	local hintLabel = parent:FindFirstChild("LoadingHint")
	if not hintLabel or not hintLabel:IsA("TextLabel") then
		hintLabel = Instance.new("TextLabel")
		hintLabel.Name = "LoadingHint"
		hintLabel.BackgroundTransparency = 1
		hintLabel.BorderSizePixel = 0
		hintLabel.ZIndex = 25
		hintLabel.Text = "[" .. LOADING_HINTS[1] .. "]"
		hintLabel.TextColor3 = HINT_TEXT_COLOR
		hintLabel.TextTransparency = 0.05
		hintLabel.TextXAlignment = Enum.TextXAlignment.Center
		hintLabel.TextYAlignment = Enum.TextYAlignment.Bottom
		hintLabel.Parent = parent
	end
	local hintLbl = hintLabel :: TextLabel
	hintLbl.AnchorPoint = Vector2.new(0.5, 1)
	hintLbl.Position = UDim2.fromScale(0.5, HINT_BOTTOM_Y)
	hintLbl.Size = UDim2.new(0.92, 0, 0, 32)
	hintLbl.TextColor3 = HINT_TEXT_COLOR
	hintLbl.TextTransparency = 0.05
	hintLbl.Visible = true
	applyCrispLabel(hintLbl, HINT_TEXT_SIZE, false)
end

local function setLoadingProgress(alpha: number)
	_loadingProgress = math.clamp(alpha, 0, 1)
end

local function startGameNameSubtitleAnim(loadingGui: ScreenGui): () -> ()
	local logo = findGameNameImage(loadingGui)
	local hintLabel = loadingGui:FindFirstChild("LoadingHint")

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

	if hintLabel and hintLabel:IsA("TextLabel") then
		hintLabel.TextTransparency = 1
	end

	local entranceStart = os.clock()
	local entranceDone = false
	local idlePhase = 0
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
				if hintLabel and hintLabel:IsA("TextLabel") then
					hintLabel.TextTransparency = 0.08
				end
			end
			return
		end

		idlePhase += dt * WOBBLE_JUMP_SPEED
		local jumpWave = math.abs(math.sin(idlePhase * math.pi))
		local rotWave = math.sin(idlePhase * 1.65)
		local scaleWave = math.sin(idlePhase * 1.1)
		if logo and logo.Parent and wrapScale then
			logo.Position = UDim2.new(0.5, 0, 0.5, -jumpWave * WOBBLE_JUMP_PX)
			logo.Rotation = rotWave * WOBBLE_ROT_DEG
			wrapScale.Scale = 1 + scaleWave * WOBBLE_SCALE_AMOUNT + jumpWave * 0.012
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

	local tweens: { Tween } = {}

	local overlay = loadingGui:FindFirstChild("BlurOverlay")
	if overlay and overlay:IsA("GuiObject") then
		table.insert(tweens, TweenService:Create(overlay, FADE_TWEEN_INFO, { BackgroundTransparency = 1 }))
	end

	local solidCover = findSolidCover(loadingGui)
	if solidCover and solidCover:IsA("GuiObject") and solidCover.Visible then
		table.insert(tweens, TweenService:Create(solidCover, FADE_TWEEN_INFO, { BackgroundTransparency = 1 }))
	end

	local bottomHint = loadingGui:FindFirstChild("LoadingHint")
	if bottomHint and bottomHint:IsA("TextLabel") then
		table.insert(tweens, TweenService:Create(bottomHint, FADE_TWEEN_INFO, { TextTransparency = 1 }))
	end

	local canvas = fadeCanvas or loadingGui:FindFirstChild("LoadingFadeCanvas")
	if canvas and canvas:IsA("CanvasGroup") then
		table.insert(tweens, TweenService:Create(canvas, FADE_TWEEN_INFO, { GroupTransparency = 1 }))
	end

	-- Stack sits outside CanvasGroup for crisp text — fade it directly.
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

	-- Camera settle is owned by run() so fade + settle can overlap cleanly.
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
	PlayerGuiMain.hideAdminPanelUnlessAllowed(playerGui:FindFirstChild("Main"))

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

	destroyLiquidLayers(loadingGui)
	stopNameAnim = startGameNameSubtitleAnim(loadingGui)
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
		stopCameraLock = startLoadingCameraLock(camera, loadingGui, player)
	end

	releaseSolidCover(loadingGui)

	local _clipSec = if loadedMoonTrack
		then math.max(moonClipDurationSec(loadedMoonTrack), 0.05)
		else MIN_DISPLAY_SEC - HOLD_AT_FULL_SEC
	local minDisplaySec = math.min(_clipSec + HOLD_AT_FULL_SEC, MAX_LOADING_DISPLAY_SEC)
	if not loadedMoonTrack and not cameraClipStartedAt then
		cameraClipStartedAt = os.clock()
	end

	local startedAt = cameraClipStartedAt or os.clock()
	while os.clock() - startedAt < minDisplaySec do
		enterLoadingIsolation(playerGui)
		local elapsed = os.clock() - startedAt
		-- Ease toward ~92% during the clip, then finish on hold.
		local t = math.clamp(elapsed / math.max(minDisplaySec - HOLD_AT_FULL_SEC, 0.05), 0, 1)
		local eased = 1 - (1 - t) ^ 2
		setLoadingProgress(0.08 + eased * 0.84)
		task.wait(0.05)
	end
	setLoadingProgress(1)
	task.wait(math.min(HOLD_AT_FULL_SEC, 0.6))

	loadingActive = false
	cameraClipStartedAt = nil
	if stopCameraLock then
		stopCameraLock()
		stopCameraLock = nil
	end
	-- Always clear streaming pin even if stopCameraLock already did (idempotent).
	endLoadingStreamingGuard(player)

	-- Overlap UI fade with a soft camera drop into third-person.
	task.spawn(function()
		if camera then
			settleGameplayCamera(camera, player, 0.95)
		end
	end)
	fadeOutLoadingTogether(loadingGui, blur, camera, player)
	cleanupLoadingVisuals(playerGui, loadingGui, nil)

	if stopNameAnim then
		stopNameAnim()
		stopNameAnim = nil
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
