-- [ACTIVE] init.client
-- Entry point – boots all client-side controllers.
-- Yield immediately so Roblox core (PlayerModule / ClickToMove / UIBlox) can finish loading.
task.defer(function()
	for _ = 1, 4 do
		task.wait()
	end

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

	-- Client streaming radii (server Workspace values do not drive the local streamer).
	pcall(function()
		local Workspace = game:GetService("Workspace")
		if Workspace.StreamingEnabled == true then
			(Workspace :: any).StreamingMinRadius = 112
			(Workspace :: any).StreamingTargetRadius = 280
		end
	end)

	LoadingScreenController.showEarly()

	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		StarterGui:SetCore("ResetButtonCallback", false)
	end)

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

	-- Fire each step in its own thread so one WaitForChild can't stall the rest.
	local function runBootStepsParallel(steps: { () -> () })
		for _, step in steps do
			task.spawn(function()
				local ok, err = pcall(step)
				if not ok then
					warn("[init.client] boot step failed:", err)
				end
			end)
		end
	end

	-- Core HUD (cash, sidebar) — shown as soon as loading dismisses.
	local function bootCoreUI()
		require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate")).init()
		require(script.HUDController).init()
		require(script.TopNotifController).init()
		require(script.CashBoostController).init()
		-- Before SideUI is visible: hide unowned gamepass icons (place file defaults Visible).
		require(script.BoostIconsController).init()
		require(script.UIEffectsBootstrap).init()
		require(script.TabScreenController).init()
		require(script.ReturnController).init()
		require(script.RandomBrainrotController):Init()
	end

	-- Panel innards (Store buy buttons, Index tabs, etc.) — must be ready as soon as HUD opens.
	local function bootPanelUI()
		runBootStepsParallel({
			function()
				require(script.GiftController).init()
			end,
			function()
				require(script.StoreController).init()
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
				require(script.SettingsController).init()
			end,
			function()
				require(script.SellController).init()
			end,
			function()
				require(script.UpgradesController).init()
			end,
			function()
				require(script.DealerShopController).init()
			end,
		})
	end

	local function bootCriticalForRedWall()
		-- Stagger map walkers so they don't all scan Workspace in the same frames.
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
				require(script.ProximityPromptEffects).init()
			end,
			function()
				require(script.BrainrotStandController).init()
			end,
			function()
				require(script.BrainrotHeaderController).init()
			end,
			function()
				require(script.BushHoldInteraction).init()
			end,
			function()
				require(script.VegetationSwayController).init()
			end,
			function()
				require(script.GrassCullController).init()
			end,
			function()
				require(script.BushSpiderEncounterController).init()
			end,
			function()
				require(script.CurrentAreaController).init()
			end,
			function()
				require(script.ComingSoonZoneController).init()
			end,
			function()
				require(script.BaseFloorUnlockClick).init()
			end,
		}, 1)
	end

	-- Everything else — never block panel boot on these.
	local function bootBackgroundUI()
		runBootStepsParallel({
			function()
				require(script.ReviveController).init()
			end,
			function()
				require(script.OfflineEarningsController).init()
			end,
			function()
				require(script.LuckyBlockController).init()
			end,
			function()
				require(script.BrainrotVisualSettings).init()
			end,
			function()
				require(script.BrainrotRainbowMutationEffect).init()
			end,
			function()
				require(script.AutoCollectController).init()
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
				require(script.LeaderboardRankController).init()
			end,
			function()
				require(script.ChatTagsController).init()
			end,
			function()
				require(script.ServerChatTipsController).init()
			end,
			function()
				require(script.CustomBubbleChatController).init()
			end,
			function()
				require(script.AdminCommandBar).init()
			end,
			function()
				require(script.AdminFlyController).init()
			end,
			function()
				require(script.AdminSpectateController).init()
			end,
			function()
				require(script.TutorialController).init()
			end,
			function()
				require(script.JumpButtonSwingRing).init()
			end,
			function()
				require(script.TimCheeseQuestController).init()
			end,
			function()
				local shared = ReplicatedStorage:WaitForChild("EssentialsShared", 10)
				if not shared then
					return
				end
				require(shared:WaitForChild("PurchaseEffect"):WaitForChild("PurchaseEffectClient")):init()
				local productHandlerClient =
					require(shared:WaitForChild("ProductHandler"):WaitForChild("ProductHandlerClient"))
				productHandlerClient:init()
				local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui", 30)
				if not playerGui then
					return
				end
				local main = PlayerGuiMain.finalize(playerGui)
				if main then
					productHandlerClient:autoBindPurchaseButtons(main)
				end
				local hud = playerGui:FindFirstChild("Hud")
				if hud then
					productHandlerClient:autoBindPurchaseButtons(hud)
				end
			end,
		})
	end

	task.spawn(function()
		local loadOk, loadErr = pcall(function()
			LoadingScreenController.run()
		end)
		if not loadOk then
			warn("[init.client] LoadingScreenController.run failed:", loadErr)
		end

		pcall(function()
			local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
			local main = pg and pg:FindFirstChild("Main")
			if main and main:IsA("ScreenGui") then
				main.Enabled = true
				local sideUI = main:FindFirstChild("SideUI")
				if sideUI and sideUI:IsA("GuiObject") then
					(sideUI :: GuiObject).Visible = true
				end
			end
			require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate")).ensureTouchControlsVisible()
		end)

		local coreOk, coreErr = pcall(bootCoreUI)
		if not coreOk then
			warn("[init.client] Core UI boot failed:", coreErr)
		end

		LoadingScreenController.registerOnGameplayReady(function()
			pcall(function()
				require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate")).ensureTouchControlsVisible()
			end)
		end)

		-- Panels immediately after HUD — do not wait for Offline/Revive remotes.
		local panelOk, panelErr = pcall(bootPanelUI)
		if not panelOk then
			warn("[init.client] Panel UI boot failed:", panelErr)
		end

		-- Heavy map scanners AFTER loading + HUD. Running them during load starved
		-- CoreScripts (ExpChat) and caused "exhausted allowed execution time".
		task.spawn(function()
			task.wait()
			local critOk, critErr = pcall(bootCriticalForRedWall)
			if not critOk then
				warn("[init.client] Critical world boot failed:", critErr)
			end
		end)

		task.spawn(function()
			task.wait(0.5)
			local bgOk, bgErr = pcall(bootBackgroundUI)
			if not bgOk then
				warn("[init.client] Background UI boot failed:", bgErr)
			end
		end)
	end)

	task.spawn(function()
		-- Warm assigned plot ASAP so join teleport lands on streamed collision.
		task.wait(0.25)
		local warmOk, warmErr = pcall(function()
			require(script.SpawnAreaWarmup).runAsync()
		end)
		if not warmOk then
			warn("[init.client] SpawnAreaWarmup failed:", warmErr)
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
		-- Do not destroy PanelModalBlur here — HUDController owns panel blur lifetime.
	end)

	-- World / gameplay controllers — after loading window so ExpChat/core can finish.
	task.spawn(function()
		task.wait(2)
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
				require(script.SafeZoneLightingController).init()
			end,
			function()
				require(script.SafeZoneBeaconController).init()
			end,
			function()
				require(script.PlotOutlineController).init()
			end,
			function()
				require(script.FireflyController).init()
			end,
			function()
				require(script.LowGraphicsController).init()
			end,
			function()
				require(script.WebTrapController).init()
			end,
			function()
				require(script.BushFloatingClaimController).init()
			end,
			function()
				require(script.BaseReturnGuideController).init()
			end,
			function()
				require(script.GlobalRaritySpawnController).init()
			end,
			function()
				require(script.LeaderboardsController).init()
			end,
		}, 1)
	end)
end)
