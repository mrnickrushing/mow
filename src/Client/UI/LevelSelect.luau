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
local Palette = require(Shared.Config.Palette)
local Loop = require(Shared.Util.Loop)
local GameConfig = require(Shared.Config.GameConfig)
local LobbyPad = require(Shared.LobbyPad)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)
local Worlds = require(Shared.Config.Worlds)
local Theme = require(script.Parent.Theme)
local Intro = require(script.Parent.Intro)
local PlayerState = require(script.Parent.Parent.PlayerState)

local LevelSelect = {}

local MAX_PARTY = GameConfig.MAX_PARTY

local player = Players.LocalPlayer
local confirmRemote: RemoteEvent
local gui: ScreenGui
local mapHolder: ScrollingFrame
local partyValue: TextLabel
local difficultyValue: TextLabel
local clockValue: TextLabel
local payoutValue: TextLabel
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
local function titled(parent: Instance, name: string, title: string, size: UDim2, position: UDim2): (Frame, Frame)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.Position = position
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundColor3 = PANEL
	frame.BorderSizePixel = 0
	frame.Parent = parent
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
	payoutValue.Text = if world then `{world.payoutMultiplier}x cash` else "—"
end

local function drawCard(world: Types.WorldDef, order: number)
	local open = isUnlocked(world)
	local state = PlayerState.get()

	--[[
		A banner card, the way the reference draws one.

		Its cards are photographs of the property with the best time in green
		across the top, the name across the bottom and a green tick in the
		corner of the one you have picked. A photograph is not something this
		can produce, so the banner is the property's own ground colour — the
		three of them are a lawn, a gravel drive and a forecourt, which is
		enough to tell the three cards apart at a glance the way the photos
		do. Everything else about the card is the reference's.
	]]
	local card = Instance.new("TextButton")
	card.Name = world.id
	card.Text = ""
	card.Size = UDim2.new(1, -14, 0, 118)
	card.BackgroundColor3 = Color3.fromRGB(44, 47, 56)
	card.BorderSizePixel = 0
	card.AutoButtonColor = open
	card.LayoutOrder = order
	card.ClipsDescendants = true
	card.Parent = mapHolder
	Theme.corner(card, 10)
	-- Gold on the one that is picked, the way the reference rings its choice.
	Theme.stroke(card, 3, if chosen == world.id then Color3.fromRGB(252, 206, 74) else INK, if chosen == world.id then 0 else 0.4)

	--[[
		The property itself, drawn.

		This was the world's `baseGround` as a flat wash, which fell over the
		moment two properties shared one: The House and The Mansion are both
		`ground.lawn`, so two of the three cards were the same green rectangle
		and the card did nothing the name was not already doing. Each property
		now has its own picture — the teal-trimmed house, the mansion's three
		gables, the station's red canopy — drawn in this game's palette so the
		row of cards reads the way the reference's photographs do.
	]]
	local banner = Instance.new("ImageLabel")
	banner.Name = "Banner"
	banner.Size = UDim2.fromScale(1, 1)
	banner.BackgroundColor3 = Palette.color(world.baseGround)
	banner.Image = world.art or ""
	banner.ScaleType = Enum.ScaleType.Crop
	banner.BorderSizePixel = 0
	banner.Parent = card
	Theme.corner(banner, 10)

	-- Darkened towards the bottom so the name sits on it and stays readable.
	local shade = Instance.new("UIGradient")
	shade.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(226, 226, 226)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(96, 96, 96)),
	})
	shade.Rotation = 90
	shade.Parent = banner

	if not open then
		-- A property you have not earned is dimmed, not hidden: the picture is
		-- most of what makes it worth earning.
		shade.Color = ColorSequence.new(Color3.fromRGB(104, 104, 104), Color3.fromRGB(54, 54, 54))
	end

	--[[
		The personal best, in green on a dark pill along the top.

		It is the one number that makes a map card worth looking at twice: the
		only thing on this screen that says you have been here before.
	]]
	local best = state.bestTimes[world.id]
	local pill = Instance.new("Frame")
	pill.Name = "BestPill"
	pill.Size = UDim2.new(0, 168, 0, 26)
	pill.Position = UDim2.fromOffset(10, 10)
	pill.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
	pill.BackgroundTransparency = 0.15
	pill.BorderSizePixel = 0
	pill.Parent = card
	Theme.corner(pill, 6)

	Theme.text({
		name = "Best",
		text = if not open
			then `Needs {Worlds.expect(world.requiresWorld :: string).name}`
			elseif best then `Best : {Format.clock(best)}`
			else "Best : —",
		size = UDim2.new(1, -12, 1, 0),
		position = UDim2.fromOffset(8, 0),
		parent = pill,
		align = Enum.TextXAlignment.Left,
		color = if not open then LOCKED else GREEN,
		textSize = 18,
	})

	Theme.text({
		name = "Name",
		text = world.name,
		size = UDim2.new(1, -24, 0, 34),
		position = UDim2.new(0, 14, 1, -42),
		parent = card,
		align = Enum.TextXAlignment.Left,
		color = if open then Color3.fromRGB(252, 250, 244) else LOCKED,
		textSize = 27,
	})

	Theme.text({
		name = "Difficulty",
		text = string.upper(world.difficulty),
		size = UDim2.new(0, 120, 0, 26),
		position = UDim2.new(1, -134, 1, -38),
		parent = card,
		align = Enum.TextXAlignment.Right,
		color = if open then Color3.fromRGB(236, 238, 244) else LOCKED,
		textSize = 19,
	})

	if chosen == world.id then
		-- A green disc with a white tick, not a bare character.
		local badge = Instance.new("Frame")
		badge.Name = "Tick"
		badge.Size = UDim2.fromOffset(40, 40)
		badge.Position = UDim2.new(1, -50, 0, 8)
		badge.BackgroundColor3 = Color3.fromRGB(74, 190, 92)
		badge.BorderSizePixel = 0
		badge.Parent = card
		Theme.corner(badge, 20)
		Theme.stroke(badge, 2, Color3.fromRGB(252, 250, 244), 0.15)
		Theme.text({
			name = "Mark",
			text = "✓",
			size = UDim2.fromScale(1, 1),
			position = UDim2.fromScale(0, 0),
			parent = badge,
			color = Color3.fromRGB(255, 255, 255),
			textSize = 28,
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
	mapHolder.CanvasSize = UDim2.fromOffset(0, #Worlds.list * 126)
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

	--[[
		Both panels live in one frame, and that frame is what gets scaled.

		They used to be parented to the screen and scaled separately, each
		fitted against the full width. A `UIScale` shrinks a panel but leaves
		its position offset alone, and the two sat at a fixed 232 pixels either
		side of centre — so as the screen narrowed the panels got smaller while
		the gulf between them grew, and the pair got wider relative to the room
		it had. Measured on the real thing:

		    scale 1.00   panels 440 wide   gap  24   pair 904
		    scale 0.65   panels 287 wide   gap 177   pair 751
		    scale 0.35   panels 154 wide   gap 310   pair 618

		At the 0.653 a portrait phone lands on, that is 751 pixels of panel on
		a 640 pixel screen: 55 cut off either side, and shrinking it further
		made it worse rather than better.

		One frame, one scale, and the gap shrinks with everything else.
	]]
	local PAIR_W, PAIR_H = 904, 430
	local holder = Instance.new("Frame")
	holder.Name = "Panels"
	holder.Size = UDim2.fromOffset(PAIR_W, PAIR_H)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	Theme.fitToViewport(holder, PAIR_W + 40, PAIR_H + 60)

	----------------------------------------------------------------
	-- Left: the settings, and the number that started all this
	----------------------------------------------------------------
	local settings, body = titled(
		holder,
		"GameSettings",
		"⚙  GAME SETTINGS",
		UDim2.fromOffset(440, 430),
		UDim2.new(0.5, -232, 0.5, 0)
	)

	partyValue = field(body, 10, "MAX PLAYERS")
	button(body, "−", UDim2.fromOffset(46, 40), UDim2.new(0.5, -120, 0, 40), HEAD).Activated:Connect(function()
		party = math.max(party - 1, 1)
		refreshSettings()
	end)
	button(body, "+", UDim2.fromOffset(46, 40), UDim2.new(0.5, 74, 0, 40), HEAD).Activated:Connect(function()
		party = math.min(party + 1, MAX_PARTY)
		refreshSettings()
	end)

	difficultyValue = field(body, 86, "DIFFICULTY")
	clockValue = field(body, 162, "TIME ON THE CLOCK")
	--[[
		What the property pays, beside what it gives you to do it in.

		The reference pairs its clock with a gem multiplier on the same row,
		which is most of what stops its settings panel reading half-empty.
		This game has no gems, but every property does multiply what the work
		is worth, and that is the number a player choosing between three maps
		actually wants next to the clock.
	]]
	payoutValue = field(body, 238, "PAYOUT")

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

	--[[
		A round red button with a white cross, on the title bar.

		The reference's is a disc, and a square one on a rounded bar reads as
		a placeholder next to it — this is the only control on the panel that
		is pure furniture, so it is the one where matching the shape is most
		of the work.
	]]
	local close = button(settings, "✕", UDim2.fromOffset(40, 40), UDim2.new(1, -48, 0, 2), RED)
	-- `button` already put a UICorner on it, and Roblox honours the first one
	-- it finds — a second is ignored, so the radius is set on the one there.
	local closeCorner = close:FindFirstChildOfClass("UICorner")
	if closeCorner then
		closeCorner.CornerRadius = UDim.new(0.5, 0)
	end
	Theme.stroke(close, 2.5, Color3.fromRGB(252, 250, 244), 0.2)
	close.Activated:Connect(function()
		dismissedOnPad = true
		LevelSelect.setOpen(false)
	end)

	----------------------------------------------------------------
	-- Right: the maps
	----------------------------------------------------------------
	local _, mapBody = titled(
		holder,
		"SelectMap",
		"🗺  SELECT MAP",
		UDim2.fromOffset(440, 430),
		UDim2.new(0.5, 232, 0.5, 0)
	)

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
	Loop.forever("LevelSelect.pad", function()
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
	end)

end

return LevelSelect
