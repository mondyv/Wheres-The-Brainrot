--[[
	LuckyBlockController
	Client side of the Star-Rainbow lucky block tool.

	When the equipped lucky block is activated:
	• Fires LuckyBlockRoll to the server.
	• On LuckyBlockShakeStart from the server, shakes the tool (Handle local CFrame offset) +
	  starts the Secret/Godly bush aura SFX as the build-up.
	• After the shake duration, the server grants + auto-equips the rolled brainrot through the
	  existing inventory flow; the brainrot SFX comes through the standard PlayBrainrotSFX path.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local ClientSFXVolume = require(script.Parent.ClientSFXVolume)
local GameSoundEffects = require(script.Parent.GameSoundEffects)

local player = Players.LocalPlayer

local SHAKE_RADIUS_STUDS = 0.45
local SHAKE_FREQ_HZ = 22
local SHAKE_ROT_DEG = 35

local LuckyBlockController = {}

local rollRE: RemoteEvent? = nil
local shakeStartRE: RemoteEvent? = nil
local activeAuraSound: Sound? = nil
local activeShakeToken = 0
local activeShakeConn: RBXScriptConnection? = nil

local function isLuckyBlockTool(tool: Instance): boolean
	return tool:IsA("Tool") and tool:GetAttribute("LuckyBlockTool") == true
end

local function bushAuraTemplate(): Sound?
	local root = SoundService:FindFirstChild("SoundEffects")
	local aura = root and root:FindFirstChild("BushAura")
	if not aura then
		return nil
	end
	local s = aura:FindFirstChild("Secret/Godly Bush Aura")
	if s and s:IsA("Sound") then
		return s
	end
	return nil
end

local function stopAura()
	if activeAuraSound then
		pcall(function()
			activeAuraSound:Stop()
		end)
		activeAuraSound:Destroy()
		activeAuraSound = nil
	end
end

local function startAura()
	stopAura()
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	local template = bushAuraTemplate()
	if not template then
		return
	end
	local originalVolume = template.Volume
	local clone = template:Clone()
	local sfxGroup = ClientSFXVolume.getSoundGroup()
	if sfxGroup then
		clone.SoundGroup = sfxGroup
		clone.Volume = originalVolume
	else
		clone.Volume = originalVolume * ClientSFXVolume.getVolume()
	end
	clone.Looped = true
	clone.Parent = SoundService
	clone:Play()
	activeAuraSound = clone
end

local function stopShake()
	if activeShakeConn then
		activeShakeConn:Disconnect()
		activeShakeConn = nil
	end
end

local function startShake(tool: Tool, durationSec: number)
	stopShake()
	activeShakeToken += 1
	local token = activeShakeToken
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	if not handle then
		return
	end
	local startedAt = os.clock()
	local baseGrip = tool.Grip
	local rotPhase = math.random() * math.pi * 2
	activeShakeConn = RunService.Heartbeat:Connect(function()
		if token ~= activeShakeToken then
			return
		end
		if not tool.Parent or not handle.Parent then
			stopShake()
			return
		end
		local elapsed = os.clock() - startedAt
		local frac = math.clamp(elapsed / durationSec, 0, 1)
		-- Ramp the amplitude up so the shake builds rather than slamming.
		local amp = 0.15 + frac * 0.85
		local t = elapsed * math.pi * 2 * SHAKE_FREQ_HZ
		local jitterX = (math.noise(t * 0.13, rotPhase, 0) - 0.5) * 2 * SHAKE_RADIUS_STUDS * amp
		local jitterY = (math.noise(rotPhase, t * 0.13, 0.5) - 0.5) * 2 * SHAKE_RADIUS_STUDS * amp
		local jitterZ = (math.noise(t * 0.13, 0.5, rotPhase + 1) - 0.5) * 2 * SHAKE_RADIUS_STUDS * amp
		local rot = math.sin(t) * math.rad(SHAKE_ROT_DEG) * amp
		tool.Grip = baseGrip
			* CFrame.new(jitterX, jitterY, jitterZ)
			* CFrame.Angles(rot, rot * 0.5, rot * 0.3)
		if elapsed >= durationSec then
			tool.Grip = baseGrip
			stopShake()
		end
	end)
end

local function handleShakeStart(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local duration = if typeof(payload.durationSec) == "number" then math.max(0.2, payload.durationSec) else 2.0
	local char = player.Character
	if not char then
		return
	end
	local tool = nil
	for _, c in ipairs(char:GetChildren()) do
		if c:IsA("Tool") and c:GetAttribute("LuckyBlockTool") == true then
			tool = c :: Tool
			break
		end
	end
	if not tool then
		local bp = player:FindFirstChildOfClass("Backpack")
		if bp then
			for _, c in ipairs(bp:GetChildren()) do
				if c:IsA("Tool") and c:GetAttribute("LuckyBlockTool") == true then
					tool = c :: Tool
					break
				end
			end
		end
	end
	if tool then
		startShake(tool, duration)
	end
	startAura()
	task.delay(duration, function()
		stopAura()
		stopShake()
		-- Drop shake camera shake comes from the standard harvest-drop FX once the brainrot is granted;
		-- play a one-shot purchase shake so the player feels the reveal.
		GameSoundEffects.playPurchaseShake()
	end)
end

local function bindTool(tool: Tool)
	if tool:GetAttribute("__LuckyBlockBound") == true then
		return
	end
	tool:SetAttribute("__LuckyBlockBound", true)
	tool.Activated:Connect(function()
		if tool:GetAttribute("LuckyBlockRolling") == true then
			return
		end
		if not rollRE then
			return
		end
		rollRE:FireServer()
	end)
end

local function watchTool(tool: Instance)
	if not isLuckyBlockTool(tool) then
		return
	end
	bindTool(tool :: Tool)
end

local function watchContainer(container: Instance?)
	if not container then
		return
	end
	for _, c in ipairs(container:GetChildren()) do
		watchTool(c)
	end
	container.ChildAdded:Connect(watchTool)
end

local function bindToCharacter(char: Model)
	watchContainer(char)
end

local function bindToBackpack(bp: Instance)
	watchContainer(bp)
end

function LuckyBlockController.init()
	-- Wait for the server-side remotes.
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("LuckyBlockRemotes", 60)
		if not folder then
			warn("[LuckyBlockController] LuckyBlockRemotes folder missing")
			return
		end
		rollRE = folder:WaitForChild("LuckyBlockRoll", 30) :: RemoteEvent?
		shakeStartRE = folder:WaitForChild("LuckyBlockShakeStart", 30) :: RemoteEvent?
		if shakeStartRE then
			shakeStartRE.OnClientEvent:Connect(handleShakeStart)
		end
	end)

	if player.Character then
		bindToCharacter(player.Character)
	end
	player.CharacterAdded:Connect(bindToCharacter)

	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then
		bindToBackpack(bp)
	end
	player.ChildAdded:Connect(function(c)
		if c:IsA("Backpack") then
			bindToBackpack(c)
		end
	end)
end

return LuckyBlockController
