--// < Made by: MikePlayz163 >

-->> || Services || <<--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-->> || Variables || <<--

local Player = Players.LocalPlayer or Players:GetPropertyChangedSignal("LocalPlayer"):Wait() :: Player
local _PlayerGui = Player:WaitForChild("PlayerGui") :: PlayerGui

-->> || Modules || <<--

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Maid = require(Packages.Maid)
local Promise = require(Packages.Promise)
local _Functions = require(Shared.Functions)

-->> || Types || <<--

export type Controller = {
	Cleanup: (self: Controller) -> (),
	Render: (self: Controller, deltaTime: number) -> (),
	Setup: (self: Controller) -> any,
	Init: (self: Controller) -> any,
}

type InternalController = Controller & {
	-->> Internal Variables

	_CONFIG: {
		debugMode: boolean,
		renderInterval: number?,
		_passedTime: number,
	},

	_MAID: any,

	_RUNNING: boolean,
	_SETUP_COMPLETE: boolean,
	_SETUP_PROMISE: any?,

	-->> Private API

	-->> none... yet!
}

-->> || Configuration || <<--

local _CONFIG = {
	debugMode = false,
	renderInterval = 1 / 12,
	_passedTime = 0,
}

-->> || Main ~ Utilities || <<--

local Main = {
	_CONFIG = _CONFIG,
	_MAID = Maid.new(),

	_RUNNING = false,
	_SETUP_COMPLETE = false,
	_SETUP_PROMISE = nil,
} :: InternalController

Main.__index = Main

-->> || Private ~ API || <<--

-->> none... yet!

-->> || Public ~ API || <<--

function Main:Render(deltaTime: number)
	if not self._RUNNING then
		return
	end

	if not self._SETUP_COMPLETE then
		return
	end

	self._CONFIG._passedTime += deltaTime

	if self._CONFIG.renderInterval and self._CONFIG._passedTime >= self._CONFIG.renderInterval then
		self._CONFIG._passedTime -= self._CONFIG.renderInterval

		-- Add render logic here.
	end
end

function Main:Setup()
	if self._SETUP_COMPLETE then
		return Promise.resolve()
	end

	if self._SETUP_PROMISE then
		return self._SETUP_PROMISE
	end

	self._SETUP_PROMISE = Promise.try(function()
		-- Add setup logic here.

		self._SETUP_COMPLETE = true
	end)
		:catch(function(issue)
			self:_logger(`Failed to setup controller, generated issue: {tostring(issue)}`, "warn")
		end)
		:finally(function()
			self._SETUP_PROMISE = nil
		end)

	return self._SETUP_PROMISE
end

function Main:Cleanup()
	self._RUNNING = false
	self._SETUP_COMPLETE = false
	self._CONFIG._passedTime = 0

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
				self:Render(deltaTime)
			end))
		end)
		:catch(function(issue)
			self:_logger(`Failed to initialize controller, generated issue: {tostring(issue)}`, "warn")
		end)
end

return Main :: Controller
