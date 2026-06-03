-- Entry point – boots all client-side controllers
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")

local LoadingScreenController = require(script.LoadingScreenController)

LoadingScreenController.showEarly()

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

task.spawn(function()
	local loadOk, loadErr = pcall(function()
		LoadingScreenController.run()
	end)
	if not loadOk then
		warn("[LoadingScreenController] run failed:", loadErr)
	end

	local bootOk, bootErr = pcall(function()
		require(script.UpgradesController).init()
		require(script.CashBoostController).init()
		require(script.SellController).init()
		require(script.HUDController).init()
		require(script.ReviveController).init()
		require(script.UIEffectsBootstrap).init()
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
		require(script.TabScreenController).init()
		require(script.StoreController).init()
		require(script.BoostIconsController).init()
		require(script.StealController).init()
		require(script.XrayController).init()
		require(script.VipChatController).init()

		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local shared = ReplicatedStorage:WaitForChild("EssentialsShared", 10)
		if shared then
			require(shared:WaitForChild("PurchaseEffect"):WaitForChild("PurchaseEffectClient")):init()
			local productHandlerClient = require(shared:WaitForChild("ProductHandler"):WaitForChild("ProductHandlerClient"))
			productHandlerClient:init()

			local PlayerGuiMain = require(script.PlayerGuiMain)
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
	end)
	if not bootOk then
		warn("[Client] UI controller boot failed:", bootErr)
	end
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
