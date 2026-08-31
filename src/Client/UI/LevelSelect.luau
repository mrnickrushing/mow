--!strict
--[[
	LevelSelect — the screen between runs.

	Beating a world sends everyone back here rather than dropping them into the
	same lawn again, which is what makes the three properties a ladder instead
	of one lawn on a loop. It shows every world, marks the ones still locked
	with what unlocks them, and asks the server to load whichever is picked.

	It is the only screen in the game that appears without being asked for, so
	it takes the cursor while it is up: the camera is pinned to first person and
	the mouse is locked to the middle of the screen unless something frees it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local Theme = require(script.Parent.Theme)
local PlayerState = require(script.Parent.Parent.PlayerState)

local LevelSelect = {}

local player = Players.LocalPlayer
local selectRemote: RemoteEvent
local gui: ScreenGui
local rowHolder: Frame
local subtitle: TextLabel
local isOpen = false

type WorldRow = {
	id: string,
	name: string,
	tagline: string,
	difficulty: string,
	requires: string?,
}

local worlds: { WorldRow } = {}

--- How the last run ended, so the level select can say the right thing about
--- it. The lobby snapshot no longer carries the outcome — by then the phase is
--- "lobby" — so it is remembered as the run ends.
local lastOutcome: string? = nil
local lastWorldName: string? = nil

local DIFFICULTY_COLOR: { [string]: Color3 } = {
	Easy = Color3.fromRGB(126, 226, 108),
	Medium = Color3.fromRGB(255, 196, 84),
	Hard = Color3.fromRGB(240, 116, 96),
}

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MowLevelSelect"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 10
	gui.Parent = player:WaitForChild("PlayerGui")

	local shade = Instance.new("Frame")
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.35
	shade.BorderSizePixel = 0
	shade.Parent = gui

	local panel = Theme.panel({
		name = "Panel",
		size = UDim2.fromOffset(620, 460),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = gui,
		transparency = 0.02,
	})
	Theme.fitToViewport(panel, 660, 500)

	Theme.text({
		name = "Title",
		text = "PICK A PROPERTY",
		size = UDim2.new(1, -40, 0, 34),
		position = UDim2.fromOffset(20, 18),
		parent = panel,
		textSize = 26,
	})

	subtitle = Theme.text({
		name = "Subtitle",
		text = "",
		size = UDim2.new(1, -40, 0, 22),
		position = UDim2.fromOffset(20, 52),
		parent = panel,
		color = Theme.colors.subtext,
		textSize = 16,
	})

	rowHolder = Instance.new("Frame")
	rowHolder.Name = "Worlds"
	rowHolder.Size = UDim2.new(1, -40, 1, -100)
	rowHolder.Position = UDim2.fromOffset(20, 84)
	rowHolder.BackgroundTransparency = 1
	rowHolder.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = rowHolder
end

--- The display name for a world id, for saying what unlocks a locked row.
function LevelSelect.nameOf(worldId: string?): string
	if not worldId then
		return "the world before it"
	end
	for _, world in worlds do
		if world.id == worldId then
			return world.name
		end
	end
	return worldId
end

--- Draws one world as a row you can press, or as a locked row that says why.
local function drawRow(world: WorldRow, order: number, unlocked: boolean)
	local row = Instance.new("TextButton")
	row.Name = world.id
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, 78)
	row.BackgroundColor3 = if unlocked then Color3.fromRGB(58, 46, 36) else Color3.fromRGB(42, 36, 32)
	row.BackgroundTransparency = if unlocked then 0.05 else 0.35
	row.AutoButtonColor = unlocked
	row.Text = ""
	row.BorderSizePixel = 0
	row.Parent = rowHolder
	Theme.corner(row, 10)
	Theme.stroke(row, 2, if unlocked then Theme.colors.text else Color3.fromRGB(90, 80, 70), 0.4)

	Theme.text({
		name = "Name",
		text = world.name,
		size = UDim2.new(1, -140, 0, 26),
		position = UDim2.fromOffset(16, 12),
		parent = row,
		color = if unlocked then Theme.colors.text else Theme.colors.subtext,
		textSize = 22,
	})

	Theme.text({
		name = "Tagline",
		text = if unlocked then world.tagline else `Beat {LevelSelect.nameOf(world.requires)} first`,
		size = UDim2.new(1, -140, 0, 20),
		position = UDim2.fromOffset(16, 42),
		parent = row,
		color = Theme.colors.subtext,
		textSize = 15,
	})

	Theme.text({
		name = "Difficulty",
		text = if unlocked then world.difficulty else "LOCKED",
		size = UDim2.fromOffset(110, 24),
		position = UDim2.new(1, -16, 0, 16),
		anchor = Vector2.new(1, 0),
		parent = row,
		align = Enum.TextXAlignment.Right,
		color = if unlocked then (DIFFICULTY_COLOR[world.difficulty] or Theme.colors.text) else Theme.colors.subtext,
		textSize = 18,
	})

	if unlocked then
		row.Activated:Connect(function()
			selectRemote:FireServer(world.id)
		end)
	end
end

local function render()
	if not rowHolder then
		return
	end
	for _, child in rowHolder:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local beaten = PlayerState.get().worldsBeaten or {}
	local order = 0
	for _, world in worlds do
		order += 1
		drawRow(world, order, world.requires == nil or beaten[world.requires] == true)
	end
end

--[[
	The screens that only mean something during a run.

	The level select is the one screen that appears without being asked for, and
	it used to appear on top of all of these: the wave counter, the objective
	from the run just finished, the bag, and a clock still visibly counting
	down. Reading "Collect 5 leaves (0/5)" behind "PICK A PROPERTY", over a
	timer running out on nothing, is a menu that looks like a game still in
	progress. They stand down while it is up.
]]
local PLAY_SCREENS = { "MowRound", "MowHud", "MowHotbar" }

local function setPlayScreens(visible: boolean)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	for _, name in PLAY_SCREENS do
		local screen = playerGui:FindFirstChild(name)
		if screen and screen:IsA("ScreenGui") then
			screen.Enabled = visible
		end
	end
end

function LevelSelect.setOpen(open: boolean)
	if open == isOpen then
		return
	end
	isOpen = open
	gui.Enabled = open
	Theme.holdCursor(open)
	setPlayScreens(not open)
	if open then
		render()
	end
end

function LevelSelect.start()
	selectRemote = Remotes.event(Remotes.SELECT_WORLD)
	build()

	Remotes.event(Remotes.ROUND_STATE).OnClientEvent:Connect(function(snapshot: any)
		if type(snapshot) ~= "table" then
			return
		end
		if type(snapshot.worlds) == "table" then
			worlds = snapshot.worlds
		end

		if snapshot.phase == "won" or snapshot.phase == "lost" then
			lastOutcome = snapshot.phase
			lastWorldName = snapshot.worldName
		end

		local lobby = snapshot.phase == "lobby"
		if lobby then
			local name = lastWorldName
			local opener = ""
			if name and lastOutcome == "won" then
				opener = `You cleared {name}.`
			elseif name and lastOutcome == "lost" then
				-- Losing used to be congratulated on the clearing it had not done.
				opener = `The clock beat you on {name}.`
			end
			subtitle.Text = if opener == "" then "Where next?" else `{opener} Where next?`
		end
		LevelSelect.setOpen(lobby)
		if lobby and isOpen then
			render()
		end
	end)

	PlayerState.Changed:Connect(function()
		if isOpen then
			render()
		end
	end)
end

return LevelSelect
