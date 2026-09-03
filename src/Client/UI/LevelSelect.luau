--!strict
--[[
	LevelSelect — the two panels you set a game up in.

	Built to the shape of the reference game's lobby, which is what this room
	was missing: a SELECT MAP list on one side and a GAME SETTINGS panel on the
	other with the party size on it. The complaint that produced this was
	exact — "where's the box that selects how many players in my group?" — and
	the answer was that there wasn't one. Four pads told you how many were
	standing on them; nothing let you say how many you meant to play with, and
	nothing told a lone player that standing on one pad was already a game.

	It opens when you step on a pad in the lobby, and closes on Confirm, on the
	X, or on walking off. It takes the cursor while it is up, because a
	first-person camera with the mouse locked to the middle of the screen
	cannot press a button.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local LobbyPad = require(Shared.LobbyPad)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)
local Worlds = require(Shared.Config.Worlds)
local Theme = require(script.Parent.Theme)
local Intro = require(script.Parent.Intro)
local PlayerState = require(script.Parent.Parent.PlayerState)

local LevelSelect = {}

local MAX_PARTY = 4

local player = Players.LocalPlayer
local confirmRemote: RemoteEvent
local gui: ScreenGui
local mapHolder: ScrollingFrame
local partyValue: TextLabel
local difficultyValue: TextLabel
local clockValue: TextLabel
local isOpen = false
--- Set when the player closes the panel while still standing on the pad, so
--- it does not spring straight back up at them.
local dismissedOnPad = false

--- What the panels are set to. The map defaults to the first one the player
--- can actually play, so Confirm is never a dead button.
local chosen: string? = nil
local party = 1

local INK = Color3.fromRGB(38, 44, 58)
local PANEL = Color3.fromRGB(48, 56, 72)
local HEAD = Color3.fromRGB(64, 154, 232)
local FIELD = Color3.fromRGB(238, 236, 228)
local GREEN = Color3.fromRGB(96, 186, 88)
local RED = Color3.fromRGB(206, 74, 66)
local LOCKED = Color3.fromRGB(116, 122, 136)

--------------------------------------------------------------------
-- Pieces
--------------------------------------------------------------------

--- A panel with a blue title bar across the top, like the reference's.
local function titled(name: string, title: string, size: UDim2, position: UDim2): (Frame, Frame)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.Position = position
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundColor3 = PANEL
	frame.BorderSizePixel = 0
	frame.Parent = gui
	Theme.corner(frame, 12)
	Theme.stroke(frame, 3, INK, 0.15)

	local bar = Instance.new("Frame")
	bar.Name = "TitleBar"
	bar.Size = UDim2.new(1, 0, 0, 44)
	bar.BackgroundColor3 = HEAD
	bar.BorderSizePixel = 0
	bar.Parent = frame
	Theme.corner(bar, 12)

	Theme.text({
		name = "TitleText",
		text = title,
		size = UDim2.new(1, -80, 1, 0),
		position = UDim2.fromOffset(16, 0),
		parent = bar,
		align = Enum.TextXAlignment.Left,
		textSize = 25,
	})

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, -20, 1, -56)
	body.Position = UDim2.fromOffset(10, 50)
	body.BackgroundTransparency = 1
	body.Parent = frame
	return frame, body
end

local function button(parent: Instance, text: string, size: UDim2, position: UDim2, colour: Color3): TextButton
	local b = Instance.new("TextButton")
	b.Name = "Button"
	b.Text = text
	b.Size = size
	b.Position = position
	b.BackgroundColor3 = colour
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Theme.font
	b.TextColor3 = Color3.fromRGB(252, 250, 244)
	b.TextSize = 24
	b.Parent = parent
	Theme.corner(b, 8)
	Theme.outline(b, 2)
	return b
end

--- A labelled row with a value box in the middle, the way the reference draws
--- MAX PLAYERS and DIFFICULTY.
local function field(parent: Instance, y: number, heading: string): TextLabel
	Theme.text({
		name = heading,
		text = heading,
		size = UDim2.new(1, 0, 0, 26),
		position = UDim2.fromOffset(0, y),
		parent = parent,
		textSize = 22,
	})

	local box = Instance.new("Frame")
	box.Name = heading .. "Value"
	box.Size = UDim2.new(0, 132, 0, 40)
	box.Position = UDim2.new(0.5, 0, 0, y + 30)
	box.AnchorPoint = Vector2.new(0.5, 0)
	box.BackgroundColor3 = FIELD
	box.BorderSizePixel = 0
	box.Parent = parent
	Theme.corner(box, 7)

	local value = Theme.text({
		name = "Value",
		text = "",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = box,
		align = Enum.TextXAlignment.Center,
		color = INK,
		textSize = 26,
	})

	--[[
		Dark text on a pale box wants no outline.

		`Theme.text` gives every label a heavy dark stroke, and it is right to:
		the world behind this UI is a sunlit lawn and plain white text
		disappears into it. Inside one of these boxes the background is cream
		and the text is nearly black, so the same stroke just thickens the
		glyphs into a smudge.
	]]
	local stroke = value:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke:Destroy()
	end
	return value
end

--------------------------------------------------------------------
-- What a player may pick
--------------------------------------------------------------------

local function isUnlocked(world: Types.WorldDef): boolean
	local required = world.requiresWorld
	if not required then
		return true
	end
	return PlayerState.get().worldsBeaten[required] == true
end

--- The first world the player can play, so the panel never opens on a locked
--- map with a Confirm that would be refused.
local function firstPlayable(): string?
	for _, world in Worlds.list do
		if isUnlocked(world) then
			return world.id
		end
	end
	return nil
end

--------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------

local function refreshSettings()
	partyValue.Text = tostring(party)
	local world = if chosen then Worlds.get(chosen) else nil
	difficultyValue.Text = if world then string.upper(world.difficulty) else "—"
	clockValue.Text = if world then `{math.floor(world.runSeconds / 60)}m` else "—"
end

local function drawCard(world: Types.WorldDef, order: number)
	local open = isUnlocked(world)
	local state = PlayerState.get()

	local card = Instance.new("TextButton")
	card.Name = world.id
	card.Text = ""
	card.Size = UDim2.new(1, -14, 0, 96)
	card.BackgroundColor3 = if open then Color3.fromRGB(70, 80, 100) else Color3.fromRGB(56, 60, 70)
	card.BorderSizePixel = 0
	card.AutoButtonColor = open
	card.LayoutOrder = order
	card.Parent = mapHolder
	Theme.corner(card, 10)
	Theme.stroke(card, 3, if chosen == world.id then GREEN else INK, if chosen == world.id then 0 else 0.4)

	Theme.text({
		name = "Name",
		text = world.name,
		size = UDim2.new(1, -24, 0, 32),
		position = UDim2.fromOffset(14, 44),
		parent = card,
		align = Enum.TextXAlignment.Left,
		color = if open then Color3.fromRGB(252, 250, 244) else LOCKED,
		textSize = 25,
	})

	--[[
		The personal best, in green above the name.

		The reference puts it there and it is the one number that makes a map
		card worth looking at twice: it is the only thing on this screen that
		says you have been here before.
	]]
	local best = state.bestTimes[world.id]
	Theme.text({
		name = "Best",
		text = if not open
			then `Needs {Worlds.expect(world.requiresWorld :: string).name}`
			elseif best then `Best : {Format.clock(best)}`
			else "Best : —",
		size = UDim2.new(1, -24, 0, 24),
		position = UDim2.fromOffset(14, 14),
		parent = card,
		align = Enum.TextXAlignment.Left,
		color = if not open then LOCKED else GREEN,
		textSize = 19,
	})

	Theme.text({
		name = "Difficulty",
		text = string.upper(world.difficulty),
		size = UDim2.new(0, 120, 0, 24),
		position = UDim2.new(1, -134, 0, 44),
		parent = card,
		align = Enum.TextXAlignment.Right,
		color = if open then Color3.fromRGB(214, 218, 228) else LOCKED,
		textSize = 19,
	})

	if chosen == world.id then
		Theme.text({
			name = "Tick",
			text = "✓",
			size = UDim2.fromOffset(40, 40),
			position = UDim2.new(1, -46, 0, 8),
			parent = card,
			color = GREEN,
			textSize = 34,
		})
	end

	if open then
		card.Activated:Connect(function()
			chosen = world.id
			LevelSelect.refresh()
		end)
	end
end

function LevelSelect.refresh()
	if not gui then
		return
	end
	for _, child in mapHolder:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for order, world in Worlds.list do
		drawCard(world, order)
	end
	mapHolder.CanvasSize = UDim2.fromOffset(0, #Worlds.list * 104)
	refreshSettings()
end

--------------------------------------------------------------------
-- Build
--------------------------------------------------------------------

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MowLevelSelect"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 10
	gui.Parent = player:WaitForChild("PlayerGui")

	local shade = Instance.new("Frame")
	shade.Name = "Shade"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.4
	shade.BorderSizePixel = 0
	shade.Parent = gui

	----------------------------------------------------------------
	-- Left: the settings, and the number that started all this
	----------------------------------------------------------------
	local settings, body = titled(
		"GameSettings",
		"⚙  GAME SETTINGS",
		UDim2.fromOffset(440, 430),
		UDim2.new(0.5, -232, 0.5, 0)
	)
	Theme.fitToViewport(settings, 980, 500)

	partyValue = field(body, 10, "MAX PLAYERS")
	button(body, "−", UDim2.fromOffset(46, 40), UDim2.new(0.5, -120, 0, 40), HEAD).Activated:Connect(function()
		party = math.max(party - 1, 1)
		refreshSettings()
	end)
	button(body, "+", UDim2.fromOffset(46, 40), UDim2.new(0.5, 74, 0, 40), HEAD).Activated:Connect(function()
		party = math.min(party + 1, MAX_PARTY)
		refreshSettings()
	end)

	difficultyValue = field(body, 106, "DIFFICULTY")
	clockValue = field(body, 202, "TIME ON THE CLOCK")

	--[[
		Confirm is green and says what it does.

		A lone player pressing it with MAX PLAYERS on 1 is the answer to "how
		do I get in if I'm only one person", and it wants to be the most
		obvious control on the screen.
	]]
	local confirm = button(body, "Confirm", UDim2.new(1, -20, 0, 48), UDim2.fromOffset(10, 316), GREEN)
	confirm.TextSize = 28
	confirm.Activated:Connect(function()
		if chosen then
			confirmRemote:FireServer({ worldId = chosen, maxPlayers = party })
			dismissedOnPad = true
			LevelSelect.setOpen(false)
		end
	end)

	local close = button(settings, "✕", UDim2.fromOffset(38, 38), UDim2.new(1, -46, 0, 3), RED)
	close.Activated:Connect(function()
		dismissedOnPad = true
		LevelSelect.setOpen(false)
	end)

	----------------------------------------------------------------
	-- Right: the maps
	----------------------------------------------------------------
	local maps, mapBody = titled(
		"SelectMap",
		"🗺  SELECT MAP",
		UDim2.fromOffset(440, 430),
		UDim2.new(0.5, 232, 0.5, 0)
	)
	Theme.fitToViewport(maps, 980, 500)

	mapHolder = Instance.new("ScrollingFrame")
	mapHolder.Name = "Maps"
	mapHolder.Size = UDim2.fromScale(1, 1)
	mapHolder.BackgroundTransparency = 1
	mapHolder.BorderSizePixel = 0
	mapHolder.ScrollBarThickness = 6
	mapHolder.CanvasSize = UDim2.new()
	mapHolder.Parent = mapBody

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = mapHolder
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

--- The display name for a world id, for saying what unlocks a locked row.
function LevelSelect.nameOf(worldId: string?): string
	local world = if worldId then Worlds.get(worldId) else nil
	return if world then world.name else "—"
end

function LevelSelect.isOpen(): boolean
	return isOpen
end

function LevelSelect.setOpen(open: boolean)
	if not gui or isOpen == open then
		return
	end
	isOpen = open
	gui.Enabled = open
	Theme.holdCursor(open)
	if open then
		if not chosen or not isUnlocked(Worlds.expect(chosen)) then
			chosen = firstPlayable()
		end
		LevelSelect.refresh()
	end
end

--[[
	Standing on a pad is what opens this.

	Watched on the client rather than announced by the server, because the
	server already knows and says nothing a player can see: the pad turns green
	and a board two hundred studs away changes its line. "Literally nothing
	happens when I stand on the pad" was the report, and it was accurate about
	the experience while being wrong about the machinery — the machinery worked
	perfectly and quietly.

	Distance is measured flat, so standing on a pad and looking up does not
	close the panel.
]]
local function padUnderfoot(): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local lobby = workspace:FindFirstChild("MowLobby")
	if not lobby then
		return false
	end
	for _, part in lobby:GetChildren() do
		if part:IsA("BasePart") and LobbyPad.isPad(part.Name) and LobbyPad.partCovers(part, root.Position) then
			return true
		end
	end
	return false
end

function LevelSelect.start()
	confirmRemote = Remotes.event(Remotes.LOBBY_CONFIRM)
	build()
	chosen = firstPlayable()

	PlayerState.Changed:Connect(function()
		if isOpen then
			LevelSelect.refresh()
		end
	end)

	--[[
		Opened by walking on, closed by walking off, and not reopened until
		the player has actually left the pad — so pressing Confirm or the X
		does not put the panel straight back up under their feet.
	]]
	task.spawn(function()
		while true do
			task.wait(0.2)
			--[[
				Not while the opening is running.

				The intro takes the camera and hides the rest of the screen,
				and a player can still walk during it — so without this, the
				first thing anybody ever sees is a settings panel opening on
				top of the story, over a camera pointing somewhere else
				entirely.
			]]
			local on = padUnderfoot() and not Intro.isPlaying()
			if not on then
				dismissedOnPad = false
				if isOpen then
					LevelSelect.setOpen(false)
				end
			elseif not isOpen and not dismissedOnPad then
				LevelSelect.setOpen(true)
			end
		end
	end)

end

return LevelSelect
