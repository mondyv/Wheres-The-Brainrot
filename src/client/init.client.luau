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
	local RunService = game:GetService("RunService")

	-- Play-solo is server+client in one process at Automatic/max quality. Live
	-- Roblox already streams and quality-scales; Studio does not. Session-only.
	-- Do not strip shadows/bloom here — that made Studio lighting look wrong.
	if RunService:IsStudio() then
		pcall(function()
			local q = Enum.QualityLevel
			settings().Rendering.QualityLevel = q.Level08 or q.Level8 or q.Level01
		end)
	end

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

	-- Only flatten leftover Index/Toolbar Icon ViewportFrames — never the
	-- whole PlayerGui (that used to wipe LoadingScreen + live gear previews).
	pcall(function()
		local starterMain = StarterGui:FindFirstChild("Main")
		if starterMain then
			PlayerGuiMain.stripHeavy3D(starterMain)
		end
		local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
		local playerMain = pg and pg:FindFirstChild("Main")
		if playerMain then
			PlayerGuiMain.stripHeavy3D(playerMain)
		end
	end)

	-- Client streaming (place file 256/512 + LowMemory does not get overwritten
	-- by server Workspace values — the local streamer reads these on the client).
	pcall(function()
		local Workspace = game:GetService("Workspace")
		if Workspace.StreamingEnabled == true then
			local StreamingSettings = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StreamingSettings"))
			StreamingSettings.apply(Workspace)
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
				warn("[init.client] boot step failed:", i, err)
			end
			if yieldEvery > 0 and i % yieldEvery == 0 then
				task.wait()
			end
		end
	end

	local function initClientModule(name: string)
		local child = script:FindFirstChild(name)
		if not child then
			error(name .. " missing")
		end
		local ok, mod = pcall(require, child)
		if not ok then
			error(name .. " failed to load: " .. tostring(mod))
		end
		if typeof(mod) ~= "table" then
			error(name .. " did not return a table")
		end
		local initFn = (mod :: any).init or (mod :: any).Init
		if typeof(initFn) ~= "function" then
			error(name .. " has no init")
		end
		initFn(mod)
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
		local coreMods = {
			"HUDController",
			"TopNotifController",
			"ServerResetHud",
			"CashBoostController",
			"BoostIconsController",
			"UIEffectsBootstrap",
			"TabScreenController",
			"ReturnController",
			"SafezoneTopButtonsController",
			"LandActivityStripController",
			"LandLocksController",
			"RandomBrainrotController",
			"SafeZoneLightingController",
		}
		for _, name in coreMods do
			local ok, err = pcall(initClientModule, name)
			if not ok then
				warn("[init.client] Core module failed:", name, err)
			end
		end
		-- Quest ticket is HUD chrome — don't wait for background boot / streamed NPCs.
		task.spawn(function()
			local ok, err = pcall(initClientModule, "TimCheeseQuestController")
			if not ok then
				warn("[init.client] Core module failed:", "TimCheeseQuestController", err)
			end
		end)
	end

	-- Panel innards (Store buy buttons, Index tabs, etc.).
	local panelBootSteps: { () -> () } = {
		function()
			initClientModule("GiftController")
		end,
		function()
			initClientModule("StoreController")
		end,
		function()
			initClientModule("IndexController")
		end,
		function()
			initClientModule("RebirthController")
		end,
		function()
			initClientModule("DailyController")
		end,
		function()
			initClientModule("SettingsController")
		end,
		function()
			initClientModule("SellController")
		end,
		function()
			initClientModule("UpgradesController")
			initClientModule("WorkoutController")
			initClientModule("LevelController")
		end,
		function()
			initClientModule("DealerShopController")
		end,
	}

	local function bootPanelUI()
		runBootStepsParallel(panelBootSteps)
	end

	local function bootCriticalForRedWall()
		-- Stagger map walkers so they don't all scan Workspace in the same frames.
		runBootSteps({
			function()
				initClientModule("StandController")
			end,
			function()
				initClientModule("ToolbarController")
			end,
			function()
				initClientModule("PlotMarkerVisibility")
			end,
			function()
				initClientModule("ProximityPromptEffects")
			end,
			function()
				initClientModule("BrainrotStandController")
			end,
			function()
				initClientModule("BrainrotHeaderController")
			end,
			function()
				initClientModule("BushHoldInteraction")
			end,
			function()
				initClientModule("VegetationSwayController")
			end,
			function()
				-- Studio play overlay (quality/cull) before land parking starts.
				initClientModule("LowGraphicsController")
			end,
			function()
				initClientModule("GrassCullController")
			end,
			function()
				initClientModule("BushSpiderEncounterController")
			end,
			function()
				initClientModule("WaveWebChaseController")
			end,
			function()
				initClientModule("CurrentAreaController")
			end,
			function()
				initClientModule("ComingSoonZoneController")
			end,
			function()
				initClientModule("BaseFloorUnlockClick")
			end,
		}, 1)
	end

	-- Everything else — never block panel boot on these.
	local function bootBackgroundUI()
		runBootStepsParallel({
			function()
				initClientModule("ReviveController")
			end,
			function()
				initClientModule("OfflineEarningsController")
			end,
			function()
				initClientModule("LuckyBlockController")
			end,
			function()
				initClientModule("BrainrotVisualSettings")
			end,
			function()
				initClientModule("BrainrotRainbowMutationEffect")
			end,
			function()
				initClientModule("AutoCollectController")
			end,
			function()
				initClientModule("BoosterPackShowersController")
			end,
			function()
				initClientModule("MailboxFeedbackController")
			end,
			function()
				initClientModule("EventBillboardController")
			end,
			function()
				initClientModule("StealController")
			end,
			function()
				initClientModule("XrayController")
			end,
			function()
				initClientModule("LeaderboardRankController")
			end,
			function()
				initClientModule("ChatTagsController")
			end,
			function()
				initClientModule("ServerChatTipsController")
			end,
			function()
				initClientModule("CustomBubbleChatController")
			end,
			function()
				initClientModule("AdminCommandBar")
			end,
			function()
				initClientModule("AdminPollController")
			end,
			function()
				initClientModule("AdminPollComposer")
			end,
			function()
				initClientModule("AdminGiftDropController")
			end,
			function()
				initClientModule("AdminFlyController")
			end,
			function()
				initClientModule("AdminSpectateController")
			end,
			function()
				initClientModule("TutorialController")
			end,
			function()
				initClientModule("JumpButtonSwingRing")
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
				local gate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))
				gate.ensureTouchControlsVisible(true)
				gate.restorePlayerMovement()
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
				initClientModule("BackgroundMusicController")
			end,
			function()
				initClientModule("UIInteractionSounds")
			end,
			function()
				initClientModule("GameSoundEffects")
			end,
			function()
				initClientModule("BrainrotSFX")
			end,
			function()
				initClientModule("SafeZoneFlashController")
			end,
			function()
				initClientModule("SafeZoneLightingController")
			end,
			function()
				initClientModule("SafeZoneBeaconController")
			end,
			function()
				initClientModule("PlotOutlineController")
			end,
			function()
				initClientModule("FireflyController")
			end,
			function()
				initClientModule("LowGraphicsController")
			end,
			function()
				initClientModule("WebTrapController")
			end,
			function()
				initClientModule("BushFloatingClaimController")
			end,
			function()
				initClientModule("BaseReturnGuideController")
			end,
			function()
				initClientModule("GlobalRaritySpawnController")
			end,
			function()
				initClientModule("LeaderboardsController")
			end,
		}, 1)
	end)
end)
