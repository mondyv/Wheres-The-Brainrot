-- [ACTIVE] init.client
-- Entry point – boots all client-side controllers.
-- Yield immediately so Roblox core (UIBlox/Foundation StarterScript) can finish loading.
task.defer(function()
	task.wait()

	local Players = game:GetService("Players")
	local Lighting = game:GetService("Lighting")
	local StarterGui = game:GetService("StarterGui")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	task.spawn(function()
		local shared = ReplicatedStorage:WaitForChild("Shared", 30)
		if shared then
			local ok, err = pcall(function()
				require(shared:WaitForChild("SafezoneUtil")).warmCacheAsync()
			end)
			if not ok then
				warn("[init.client] SafezoneUtil warmCacheAsync failed:", err)
			end
		end
	end)

	local LoadingScreenController = require(script.LoadingScreenController)
	local PlayerGuiMain = require(script.PlayerGuiMain)

	LoadingScreenController.showEarly()

	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		StarterGui:SetCore("ResetButtonCallback", false)
	end)

	-- Core HUD (cash, sidebar buttons) — shown as soon as the loading screen dismisses
	local function bootCoreUI()
		require(script.HUDController).init()
		require(script.TopNotifController).init()
		require(script.CashBoostController).init()
		require(script.UIEffectsBootstrap).init()
		require(script.TabScreenController).init()
		require(script.ReturnController).init()
		require(script.RandomBrainrotController):Init()
	end

	-- Store panels, boost icons, gamepass checks, etc. — deferred after core is visible.
	-- Yield every few inits so Roblox core (UIBlox/Foundation) isn't starved during boot.
	local function runBootSteps(steps: { () -> () }, yieldEvery: number)
		for i, step in steps do
			local ok, err = pcall(step)
			if not ok then
				warn("[init.client] boot step failed:", err)
			end
			if yieldEvery > 0 and i % yieldEvery == 0 then
				task.wait()
			end
		end
	end

	local function bootCriticalForRedWall()
		runBootSteps({
			function()
				require(script.StandController).init()
			end,
			function()
				require(script.ToolbarController).init()
			end,
			function()
				require(script.PlotMarkerVisibility).init()
			end,
			function()
				require(script.BrainrotStandController).init()
			end,
			function()
				require(script.ProximityPromptEffects).init()
			end,
			function()
				require(script.BushHoldInteraction).init()
			end,
			function()
				require(script.CurrentAreaController).init()
			end,
		}, 1)
	end

	local function bootDeferredUI()
		runBootSteps({
			function()
				require(script.UpgradesController).init()
			end,
			function()
				require(script.SellController).init()
			end,
			function()
				require(script.ReviveController).init()
			end,
			function()
				require(script.IndexController).init()
			end,
			function()
				require(script.RebirthController).init()
			end,
			function()
				require(script.DailyController).init()
			end,
			function()
				require(script.LuckyBlockController).init()
			end,
			function()
				require(script.BrainrotVisualSettings).init()
			end,
			function()
				require(script.SettingsController).init()
			end,
			function()
				require(script.BrainrotHeaderController).init()
			end,
			function()
				require(script.AutoCollectController).init()
			end,
			function()
				require(script.StoreController).init()
			end,
			function()
				require(script.BoostIconsController).init()
			end,
			function()
				require(script.BoosterPackShowersController).init()
			end,
			function()
				require(script.StealController).init()
			end,
			function()
				require(script.XrayController).init()
			end,
			function()
				require(script.ChatTagsController).init()
			end,
		}, 2)

		task.wait()
		runBootSteps({
			function()
				require(script.AdminCommandBar).init()
			end,
		}, 1)

		local shared = ReplicatedStorage:WaitForChild("EssentialsShared", 10)
		if shared then
			require(shared:WaitForChild("PurchaseEffect"):WaitForChild("PurchaseEffectClient")):init()
			local productHandlerClient = require(shared:WaitForChild("ProductHandler"):WaitForChild("ProductHandlerClient"))
			productHandlerClient:init()

			task.wait()
			local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui", 30)
			if playerGui then
				local main = PlayerGuiMain.finalize(playerGui)
				if main then
					productHandlerClient:autoBindPurchaseButtons(main)
				end
				task.wait()
				local hud = playerGui:FindFirstChild("Hud")
				if hud then
					productHandlerClient:autoBindPurchaseButtons(hud)
				end
			end
		end
	end

	task.spawn(function()
		task.spawn(function()
			local warmOk, warmErr = pcall(function()
				require(script.SpawnAreaWarmup).runAsync()
			end)
			if not warmOk then
				warn("[init.client] SpawnAreaWarmup failed:", warmErr)
			end
		end)

		task.spawn(function()
			local critOk, critErr = pcall(bootCriticalForRedWall)
			if not critOk then
				warn("[init.client] bootCriticalForRedWall failed:", critErr)
			end
		end)

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

		local deferOk, deferErr = pcall(function()
			runBootSteps({
				function()
					require(script.BaseFloorUnlockClick).init()
				end,
			}, 1)
			bootDeferredUI()
		end)
		if not deferOk then
			warn("[init.client] Deferred UI boot failed:", deferErr)
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

	-- World / gameplay controllers — staggered so client boot doesn't block UIBlox/Foundation.
	task.spawn(function()
		runBootSteps({
			function()
				require(script.BackgroundMusicController).init()
			end,
			function()
				require(script.UIInteractionSounds).init()
			end,
			function()
				require(script.GameSoundEffects).init()
			end,
			function()
				require(script.BrainrotSFX).init()
			end,
			function()
				require(script.SafeZoneFlashController).init()
			end,
			function()
				require(script.WebTrapController).init()
			end,
			function()
				require(script.BushFloatingClaimController).init()
			end,
			function()
				require(script.GlobalRaritySpawnController).init()
			end,
			function()
				require(script.LeaderboardsController).init()
			end,
		}, 2)
	end)
end)
