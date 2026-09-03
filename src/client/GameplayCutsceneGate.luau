-- [ACTIVE] GameplayCutsceneGate
--[[
	Lazy cutscene-active checks — keeps heavy controllers out of modules near the Luau local register cap.
]]

local GameplayCutsceneGate = {}

local cache: { [string]: any } = {}

local function controller(name: string): any
	if cache[name] == nil then
		local modScript = script.Parent:FindFirstChild(name)
		if not modScript then
			cache[name] = false
		else
			local ok, mod = pcall(require, modScript)
			cache[name] = if ok then mod else false
		end
	end
	local mod = cache[name]
	return if mod ~= false then mod else nil
end

function GameplayCutsceneGate.isSpiderEncounterActive(): boolean
	local mod = controller("BushSpiderEncounterController")
	return mod ~= nil and mod.isActive() == true
end

function GameplayCutsceneGate.isWaveWebChaseActive(): boolean
	local mod = controller("WaveWebChaseController")
	if not mod then
		return false
	end
	if typeof(mod.isChaseActive) == "function" then
		return mod.isChaseActive() == true
	end
	return mod.isActive() == true
end

function GameplayCutsceneGate.isAmbushOrChaseActive(): boolean
	return GameplayCutsceneGate.isSpiderEncounterActive() or GameplayCutsceneGate.isWaveWebChaseActive()
end

function GameplayCutsceneGate.isLastLandShowcaseActive(): boolean
	local mod = controller("LastLandShowcaseCutscene")
	return mod ~= nil and typeof(mod.isActive) == "function" and mod.isActive() == true
end

return GameplayCutsceneGate
