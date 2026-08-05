-- [ACTIVE] PlayerGuiMain
--[[
	Resolves PlayerGui.Main reliably:
	1. Wait for character so Roblox can replicate StarterGui → PlayerGui
	2. Prefer the replicated instance (never clone while one already exists)
	3. Remove duplicate Main ScreenGuis if both exist
	4. Clone from StarterGui.Main only as a last resort
--]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local PlayerGuiMain = {}

local function scoreMain(gui: ScreenGui): number
	local score = 0
	if gui:FindFirstChild("SideUI") then
		score += 500
	end
	if gui:FindFirstChild("Frames") then
		score += 250
	end
	if gui.Enabled then
		score += 100
	end
	return score
end

local function findAllMains(playerGui: PlayerGui): { ScreenGui }
	local mains: { ScreenGui } = {}
	for _, child in playerGui:GetChildren() do
		if child:IsA("ScreenGui") and child.Name == "Main" then
			table.insert(mains, child)
		end
	end
	return mains
end

-- Hide Studio-authored AdminFrame/button until AdminCommandBar opts in.
-- Call early during load so the join UI flash never shows it to everyone.
function PlayerGuiMain.hideAdminPanelUnlessAllowed(root: Instance?, _player: Player?)
	local main: Instance? = root
	if not main then
		local plr = Players.LocalPlayer
		local pg = plr and plr:FindFirstChild("PlayerGui")
		main = pg and pg:FindFirstChild("Main")
	end
	if not main then
		return
	end
	local sideUI = main:FindFirstChild("SideUI")
	local adminFrame = (sideUI and sideUI:FindFirstChild("AdminFrame"))
		or main:FindFirstChild("AdminFrame", true)
	if not adminFrame or not adminFrame:IsA("GuiObject") then
		return
	end
	local host = adminFrame:FindFirstChild("Admin Panel Button")
		or adminFrame:FindFirstChild("AdminPanelButton")
	;(adminFrame :: GuiObject).Visible = false
	if host and host:IsA("GuiObject") then
		host.Visible = false
		host.Active = false
	end
end

function PlayerGuiMain.dedupe(playerGui: PlayerGui): ScreenGui?
	local mains = findAllMains(playerGui)
	if #mains == 0 then
		return nil
	end
	if #mains == 1 then
		mains[1].ResetOnSpawn = false
		PlayerGuiMain.hideAdminPanelUnlessAllowed(mains[1])
		return mains[1]
	end

	table.sort(mains, function(a, b)
		return scoreMain(a) > scoreMain(b)
	end)

	local best = mains[1]
	for i = 2, #mains do
		mains[i]:Destroy()
	end
	best.ResetOnSpawn = false
	PlayerGuiMain.hideAdminPanelUnlessAllowed(best)
	return best
end

local function cloneFromStarter(playerGui: PlayerGui): ScreenGui?
	local template = StarterGui:FindFirstChild("Main")
	if not template or not template:IsA("ScreenGui") then
		template = StarterGui:WaitForChild("Main", 15)
	end
	if not template or not template:IsA("ScreenGui") then
		return nil
	end

	local clone = template:Clone()
	clone.Name = "Main"
	clone.ResetOnSpawn = false
	clone.Parent = playerGui
	return clone
end

function PlayerGuiMain.ensure(player: Player?, timeout: number?): ScreenGui
	local plr = player or Players.LocalPlayer
	local playerGui = plr:WaitForChild("PlayerGui")
	local waitSec = timeout or 120

	if not plr.Character then
		plr.CharacterAdded:Wait()
	end
	task.wait(0.1)

	local deadline = os.clock() + waitSec
	while os.clock() < deadline do
		local main = PlayerGuiMain.dedupe(playerGui)
		if main then
			return main
		end
		task.wait(0.05)
	end

	if #findAllMains(playerGui) == 0 then
		local cloned = cloneFromStarter(playerGui)
		if not cloned then
			error("[PlayerGuiMain] StarterGui.Main ScreenGui missing — add Main to StarterGui")
		end
	end

	local main = PlayerGuiMain.dedupe(playerGui)
	if main then
		return main
	end
	error("[PlayerGuiMain] Failed to resolve PlayerGui.Main")
end

function PlayerGuiMain.finalize(playerGui: PlayerGui?)
	local pg = playerGui
	if not pg then
		local plr = Players.LocalPlayer
		pg = plr and plr:FindFirstChild("PlayerGui") :: PlayerGui?
	end
	if not pg then
		return nil
	end

	local main = PlayerGuiMain.dedupe(pg)
	if main then
		PlayerGuiMain.hideAdminPanelUnlessAllowed(main)
		-- LoadingScreen keeps Main disabled until isolation exits; don't fight it here.
		local loading = pg:FindFirstChild("LoadingScreen")
		local loadingOn = loading and loading:IsA("ScreenGui") and loading.Enabled
		if not loadingOn then
			main.Enabled = true
		end
		main.ResetOnSpawn = false
	end
	return main
end

return PlayerGuiMain
