-- [ACTIVE] init.client
-- Entry point – boots all client-side controllers
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LoadingScreenController = require(script.LoadingScreenController)
local PlayerGuiMain = require(script.PlayerGuiMain)

LoadingScreenController.showEarly()

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

-- Core HUD (cash, sidebar buttons) — shown as soon as the loading screen dismisses
local function bootCoreUI()
	require(script.HUDController).init()
	require(script.TopNotifController).init()
	require(script.CashBoostController).init()
	require(script.UIEffectsBootstrap).init()
	require(script.TabScreenController).init()
end

-- Store panels, boost icons, gamepass checks, etc. — deferred after core is visible
local function bootDeferredUI()
	require(script.UpgradesController).init()
	require(script.SellController).init()
	require(script.ReviveController).init()
	require(script.IndexController).init()
	require(script.RebirthController).init()
	require(script.DailyController).init()
	require(script.LuckyBlockController).init()
	require(script.BrainrotVisualSettings).init()
	require(script.SettingsController).init()
	require(script.StandController).init()
	require(script.BrainrotHeaderController).init()
	require(script.ToolbarController).init()
	require(script.PlotMarkerVisibility).init()
	require(script.BaseFloorUnlockClick).init()
	require(script.BrainrotStandController).init()
	require(script.CurrentAreaController).init()
	require(script.StoreController).init()
	require(script.BoostIconsController).init()
	require(script.BoosterPackShowersController).init()
	require(script.StealController).init()
	require(script.XrayController).init()
	require(script.ChatTagsController).init()
	require(script.RandomBrainrotController):Init()
	local adminOk, adminErr = pcall(function()
		require(script.AdminCommandBar).init()
	end)
	if not adminOk then
		warn("[init.client] AdminCommandBar init failed:", adminErr)
	end

	local shared = ReplicatedStorage:WaitForChild("EssentialsShared", 10)
	if shared then
		require(shared:WaitForChild("PurchaseEffect"):WaitForChild("PurchaseEffectClient")):init()
		local productHandlerClient = require(shared:WaitForChild("ProductHandler"):WaitForChild("ProductHandlerClient"))
		productHandlerClient:init()

		local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui", 30)
		if playerGui then
			local main = PlayerGuiMain.finalize(playerGui)
			if main then
				productHandlerClient:autoBindPurchaseButtons(main)
			end
			local hud = playerGui:FindFirstChild("Hud")
			if hud then
				productHandlerClient:autoBindPurchaseButtons(hud)
			end
		end
	end
end

task.spawn(function()
	local loadOk, loadErr = pcall(function()
		LoadingScreenController.run()
	end)
	if not loadOk then
		warn("[init.client] LoadingScreenController.run failed:", loadErr)
	end

	local coreOk, coreErr = pcall(bootCoreUI)
	if not coreOk then
		warn("[init.client] Core UI boot failed:", coreErr)
	end

	task.defer(function()
		local deferOk, deferErr = pcall(bootDeferredUI)
		if not deferOk then
			warn("[init.client] Deferred UI boot failed:", deferErr)
		end
	end)
end)

task.spawn(function()
	local player = Players.LocalPlayer
	local pg = player:WaitForChild("PlayerGui", 30)
	if not pg then
		return
	end
	local function disableBlurGui(gui: Instance)
		if gui:IsA("ScreenGui") and gui.Name == "Blur" then
			gui.Enabled = false
		end
	end
	for _, ch in pg:GetChildren() do
		disableBlurGui(ch)
	end
	pg.ChildAdded:Connect(disableBlurGui)
	local modalBlur = Lighting:FindFirstChild("UIModalBlur")
	if modalBlur and modalBlur:IsA("BlurEffect") then
		modalBlur:Destroy()
	end
end)

require(script.BackgroundMusicController).init()
require(script.UIInteractionSounds).init()
require(script.GameSoundEffects).init()

require(script.BrainrotSFX).init()
require(script.SafeZoneFlashController).init()
require(script.BushHoldInteraction).init()
require(script.ProximityPromptEffects).init()
require(script.BushFloatingClaimController).init()
require(script.GlobalRaritySpawnController).init()
require(script.LeaderboardsController).init()
