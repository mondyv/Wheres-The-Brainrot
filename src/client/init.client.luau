-- Entry point – boots all client-side controllers
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

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
-- Bush targeting + custom card; ProximityPromptEffects styles stands and wires bush FX/harvest.
require(script.BushHoldInteraction).init()
require(script.ProximityPromptEffects).init()
require(script.UpgradesController).init()
require(script.SellController).init()
require(script.HUDController).init()
require(script.IndexController).init()
require(script.SettingsController).init()
require(script.StandController).init()
require(script.BrainrotHeaderController).init()
require(script.ToolbarController).init()
require(script.PlotMarkerVisibility).init()
require(script.BaseFloorUnlockClick).init()
require(script.BrainrotStandController).init()
require(script.CurrentAreaController).init()
