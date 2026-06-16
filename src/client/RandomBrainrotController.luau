--// < Made by: MikePlayz163 >

-->> || Services || <<--

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-->> || Variables || <<--

local Player = Players.LocalPlayer or Players:GetPropertyChangedSignal("LocalPlayer"):Wait() :: Player
local _Character = Player.Character or Player.CharacterAdded:Wait() :: Model
local PlayerGui = Player:WaitForChild("PlayerGui") :: PlayerGui

local Gui = PlayerGui:WaitForChild("Main") :: ScreenGui
local Frames = Gui:WaitForChild("Frames") :: Frame
local SideUi = Gui:WaitForChild("SideUI") :: Frame

local RightSide = SideUi.Right :: Frame
local Frame = RightSide.RandomBrainrot :: Frame
local ChancesFrame = Frames.Chances :: Frame

local ContainerFrame = ChancesFrame.Container
local Activation = Frame.Activation :: ImageButton
local ChancesButton = Activation.Chances

-->> || Modules || <<--

local EssentialsShared = ReplicatedStorage:WaitForChild("EssentialsShared") :: Folder
local EssentialAssets = ReplicatedStorage:WaitForChild("EssentialAssets") :: Folder

local Remotes = EssentialAssets.Events :: Folder
local ProductHandlerConfetti = Remotes.ProductHandlerConfetti :: RemoteEvent

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Prompter = require(EssentialsShared.PurchasePrompt)
local Effects = require(EssentialsShared.EffectsController)

local BrainrotsConfig = require(Shared.BrainrotsConfig)
local StoreConfig = require(Shared.StoreConfig)

local HUDController = require(script.Parent.HUDController)

local Maid = require(Packages.Maid)
local Promise = require(Packages.Promise)

-->> || Configuration || <<--

local _CONFIG = {
	debugMode = false,
	renderInterval = 1 / 12,
}

-->> || Main ~ Utilities || <<--

local Main = {}
Main.__index = Main

Main._CONFIG = _CONFIG
Main._MAID = Maid.new()

Main._RUNNING = false
Main._SETUP_COMPLETE = false
Main._SETUP_PROMISE = nil

-->> || Private ~ API || <<--

function Main:_logger(message: string, type: "info" | "warn" | "error"?): (boolean, string?)
	if not message then
		return false, "No message was provided."
	end

	if not type then
		type = "info"
	end

	local function obtainScriptInfo()
		local traceback = debug.traceback()
		local pattern = "([^\n]+):(%d+)"
		local count = 0
		for source, line in string.gmatch(traceback, pattern) do
			count = count + 1
			if count == 4 then
				source = source:match("([^%.]+)$") or source
				return source, tonumber(line) or 0
			end
		end
		return "Unknown", 0
	end

	local function log(level, message, bypassStudioCheck, ...)
		local scriptName, lineNumber = obtainScriptInfo()
		local formattedMessage =
			string.format("[%s] [%s:%d] %s", level, scriptName, lineNumber, string.format(message, ...))

		if level == "ERROR" or level == "WARN" or bypassStudioCheck or RunService:IsStudio() then
			if level == "ERROR" or level == "WARN" then
				warn(formattedMessage)
			else
				print(formattedMessage)
			end
		end
	end

	if type == "info" then
		log("INFO", message, false)
	elseif type == "warn" then
		log("WARN", message, true)
	else
		log("ERROR", message, true)
	end

	return true
end

function Main:_celebrate(): any
	return Effects.celebratePurchase(Player)
end

function Main:_linkButtons(): boolean
	Activation.Activated:Connect(function()
		Prompter.promptProduct(StoreConfig.PRODUCT.RANDOM_BRAINROT)
	end)

	HUDController.applyHoverAndClick(ChancesButton, function()
		local current = HUDController.getCurrentFrame()

		if current and current.Name == "Chances" then
			HUDController.closeFrameByName("Chances")
		else
			HUDController.openFrameByName("Chances")
		end
	end)

	return true
end

-->> || Public ~ API || <<--

function Main:Render(deltaTime: number)
	if not self._RUNNING then
		return
	end

	if not self._SETUP_COMPLETE then
		return
	end

	return
end

function Main:Setup()
	if self._SETUP_COMPLETE then
		return Promise.resolve()
	end

	if self._SETUP_PROMISE then
		return self._SETUP_PROMISE
	end

	self._SETUP_PROMISE = Promise.try(function()
		self:_linkButtons()

		self._SETUP_COMPLETE = true
	end)
		:catch(function(issue)
			self:_logger(`Failed to setup environment client, generated issue: {tostring(issue)}`, "warn")
		end)
		:finally(function()
			self._SETUP_PROMISE = nil
		end)

	return self._SETUP_PROMISE
end

function Main:Cleanup() -->> only in specifc situations
	self._RUNNING = false
	self._SETUP_COMPLETE = false

	self._MAID:DoCleaning()
	self._MAID = Maid.new()
end

function Main:Init()
	return Promise.try(function()
		return self:Setup()
	end)
		:andThen(function()
			if self._RUNNING then
				return
			end

			self._RUNNING = true

			self._MAID:GiveTask(RunService.RenderStepped:Connect(function(deltaTime)
				if not self._RUNNING then
					return
				end

				self:Render(deltaTime)
			end))
		end)
		:catch(function(issue)
			self:_logger(`Failed to initialize environment client, generated issue: {tostring(issue)}`, "warn")
		end)
end

return Main
