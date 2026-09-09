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
local beatenValue: TextLabel
local tipsValue: TextLabel
local isOpen = false
--- Set when the player closes the panel while still standing on the pad, so
--- it does not spring straight back up at them.
local dismissedOnPad = false

--- How many the player means to play with. The property is not a setting any
--- more — pressing START A RUN on a card is the whole choice.
local party = 1

--- The dark wood every panel in this game is cut from.
local PANEL_TOP = Color3.fromRGB(66, 49, 31)
local PANEL_BOTTOM = Color3.fromRGB(42, 31, 21)

--------------------------------------------------------------------
-- Pieces
--------------------------------------------------------------------

--[[
	A panel with its name written across the top of it.

	It was a flat blue title bar on a flat slate box, which is the one piece
	of the old lobby that did not survive the redesign. Everything else on
	this screen is a slab of dark wood with a drop under it and a bevel across
	the top; two flat rectangles in the middle of that read as a different
	game's menu that had been pasted over this one.

	`blurb` is the line under the title, for the panel that needs to say what
	the player is looking at as well as what it is called.
]]
local function titled(
	parent: Instance,
	name: string,
	title: string,
	size: UDim2,
	position: UDim2,
	blurb: string?
): (Frame, Frame)
	local panel = Theme.chunkPanel({
		name = name,
		size = size,
		position = position,
		anchor = Vector2.new(0.5, 0.5),
		parent = parent,
		radius = 26,
		drop = 12,
		outline = 5,
		top = PANEL_TOP,
		bottom = PANEL_BOTTOM,
	})

	--- The same gold diamond that heads the run panel and the journal.
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.fromOffset(13, 13)
	badge.Position = UDim2.fromOffset(22, 26)
	badge.Rotation = 45
	badge.BackgroundColor3 = Theme.colors.tips
	badge.BorderSizePixel = 0
	badge.Parent = panel

	Theme.text({
		name = "TitleText",
		text = title,
		size = UDim2.new(1, -130, 0, 26),
		position = UDim2.fromOffset(46, 20),
		parent = panel,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.tips,
		textSize = 21,
	})

	if blurb then
		Theme.text({
			name = "Blurb",
			text = blurb,
			size = UDim2.new(1, -130, 0, 20),
			position = UDim2.fromOffset(46, 45),
			parent = panel,
			align = Enum.TextXAlignment.Left,
			color = Theme.colors.label,
			textSize = 15,
		})
	end

	local top = if blurb then 78 else 56
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, -40, 1, -(top + 18))
	body.Position = UDim2.fromOffset(20, top)
	body.BackgroundTransparency = 1
	body.Parent = panel
	return panel, body
end

--- Every button on this screen is one of the game's slabs now; the caller
--- says which colour it wears rather than handing over a raw Color3.
local function button(
	parent: Instance,
	text: string,
	size: UDim2,
	position: UDim2,
	variant: string
): TextButton
	local b = Theme.chunkButton({
		name = "Button",
		text = text,
		variant = variant :: any,
		textSize = 24,
		size = size,
		position = position,
		parent = parent,
		radius = 13,
		outline = 3,
	})
	--- The cursor is held while this panel is up; without `Modal` the buttons
	--- under it never see the click.
	b.Modal = true
	return b
end

--[[
	A small heading over a dark well with the number in it.

	`inset` is how far in from the panel's edges the well sits, which is only
	ever used by MAX PLAYERS: its minus and plus buttons stand in that margin
	so the three of them read as one stepper rather than as a box with two
	unrelated buttons beside it.
]]
local function field(parent: Instance, y: number, heading: string, inset: number?): TextLabel
	local margin = inset or 0

	Theme.text({
		name = heading,
		text = heading,
		size = UDim2.new(1, 0, 0, 18),
		position = UDim2.fromOffset(0, y),
		parent = parent,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.label,
		textSize = 15,
	})

	local box = Theme.chip({
		name = heading .. "Value",
		size = UDim2.new(1, -margin * 2, 0, 48),
		position = UDim2.fromOffset(margin, y + 24),
		parent = parent,
		radius = 14,
	})
	Theme.stroke(box, 3, Theme.colors.outline, 0)

	return Theme.text({
		name = "Value",
		text = "",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = box,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.body,
		textSize = 28,
	})
end

--[[
	One of the two counters on the settings panel.

	A cream card with a small heading and a big number, which is the shape the
	design uses everywhere a fact is worth reading at a glance: it is the
	property card's own face, at a quarter of the size.
]]
local function statBlock(parent: Instance, heading: string, size: UDim2, position: UDim2): TextLabel
	local face = Theme.cardFace({
		name = heading,
		size = size,
		position = position,
		parent = parent,
		radius = 16,
		drop = 5,
		outline = 4,
	})
	Theme.pad(face, 12, 14, 12, 14)

	Theme.text({
		name = "Heading",
		text = heading,
		size = UDim2.new(1, 0, 0, 16),
		position = UDim2.fromOffset(0, 0),
		parent = face,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.inkSoft,
		textSize = 13,
	})

	return Theme.text({
		name = "Value",
		text = "—",
		size = UDim2.new(1, 0, 0, 36),
		position = UDim2.fromOffset(0, 20),
		parent = face,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.ink,
		textSize = 32,
	})
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

--------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------

local function refreshSettings()
	partyValue.Text = tostring(party)

	local state = PlayerState.get()
	local beaten = 0
	for _, world in Worlds.list do
		if state.worldsBeaten[world.id] then
			beaten += 1
		end
	end
	beatenValue.Text = `{beaten} / {#Worlds.list}`
	tipsValue.Text = Format.count(state.tips)
end

--[[
	How long a run is, in the units a run is actually measured in.

	`Format.clock` is right for a stopwatch and wrong for this: every world's
	clock is whole hours, and it printed The House's as "02:00:00", which
	reads as a stopwatch that has been running for two hours rather than as
	the two hours you are being given.
]]
local function span(seconds: number): string
	local minutes = math.floor(seconds / 60)
	local hours = minutes // 60
	if hours == 0 then
		return `{minutes}m`
	elseif minutes % 60 == 0 then
		return `{hours}h`
	end
	return `{hours}h {minutes % 60}m`
end

--- What each difficulty is painted, and the ink that reads on it.
local GRADE: { [string]: { fill: Color3, ink: Color3 } } = {
	Easy = { fill = Color3.fromRGB(79, 184, 60), ink = Color3.fromRGB(14, 50, 8) },
	Medium = { fill = Theme.colors.warn, ink = Color3.fromRGB(58, 28, 0) },
	Hard = { fill = Theme.colors.danger, ink = Color3.fromRGB(255, 240, 238) },
	--- The Cemetery. Four difficulties exist and this table listed three, so
	--- the hardest property in the game wore the same dead brown as a
	--- property you cannot play.
	Nightmare = { fill = Color3.fromRGB(142, 86, 200), ink = Color3.fromRGB(250, 240, 255) },
}

--[[
	A property card: a picture of the place, its name, and one button.

	It used to be a hundred-pixel banner with the name written across the
	bottom of the photograph and a tick in the corner of the one you had
	picked — which meant the row said what each property *was* and nothing
	about what you were signing up for. Half a card of picture and half of
	facts is the shape the design asks for, and the facts are the ones a
	player choosing between four maps actually wants: how many sections, how
	long the clock is, and what it pays.

	The button is the choice. A card you select and a start button somewhere
	else is two decisions for one action.
]]
local function drawCard(world: Types.WorldDef, order: number)
	local open = isUnlocked(world)
	local state = PlayerState.get()
	local best = state.bestTimes[world.id]

	local card = Theme.cardFace({
		name = world.id,
		size = UDim2.fromOffset(0, 0),
		parent = mapHolder,
		radius = 22,
		drop = 8,
		outline = 5,
		top = if open then Color3.fromRGB(255, 252, 241) else Color3.fromRGB(58, 46, 34),
		bottom = if open then Color3.fromRGB(237, 225, 200) else Color3.fromRGB(36, 27, 19),
	})
	card.ClipsDescendants = true
	local seat = card.Parent :: Frame
	seat.LayoutOrder = order

	--[[
		The property itself, drawn.

		Each has its own picture — the teal-trimmed house, the mansion's three
		gables, the station's red canopy, the churchyard after dark — so the
		grid reads the way a shelf of photographs does rather than as four
		rectangles of ground colour, two of which used to be the same green.
	]]
	local hero = Instance.new("ImageLabel")
	hero.Name = "Hero"
	hero.Size = UDim2.fromScale(1, 0.42)
	hero.BackgroundColor3 = Palette.color(world.baseGround)
	hero.Image = world.art or ""
	hero.ScaleType = Enum.ScaleType.Crop
	hero.BorderSizePixel = 0
	hero.Parent = card

	--- A four-pixel ink line under the picture, which is the border the
	--- design draws between the two halves of the card.
	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.Size = UDim2.new(1, 0, 0, 4)
	rule.Position = UDim2.new(0, 0, 1, -4)
	rule.BackgroundColor3 = Theme.colors.outline
	rule.BorderSizePixel = 0
	rule.Parent = hero

	if not open then
		--[[
			A property you have not earned is dimmed, not hidden: the picture
			is most of what makes it worth earning. Dark enough to read as
			locked and light enough to leave the moon and the lit windows on
			the one night picture visible.
		]]
		local dim = Instance.new("UIGradient")
		dim.Color = ColorSequence.new(Color3.fromRGB(120, 120, 120), Color3.fromRGB(64, 64, 64))
		dim.Rotation = 90
		dim.Parent = hero
	end

	local facts = Instance.new("Frame")
	facts.Name = "Facts"
	facts.Size = UDim2.fromScale(1, 0.58)
	facts.Position = UDim2.fromScale(0, 0.42)
	facts.BackgroundTransparency = 1
	facts.Parent = card
	Theme.pad(facts, 14, 18, 16, 18)

	Theme.text({
		name = "Name",
		text = world.name,
		size = UDim2.new(1, 0, 0, 30),
		position = UDim2.fromOffset(0, 0),
		parent = facts,
		align = Enum.TextXAlignment.Left,
		color = if open then Theme.colors.ink else Theme.colors.body,
		textSize = 27,
	})

	--- The difficulty, on a pill in its own colour, dimmed on a property you
	--- have not opened yet.
	local grade = GRADE[world.difficulty]
	local pillFill = if open and grade then grade.fill else Color3.fromRGB(44, 33, 24)
	local pillInk = if open and grade then grade.ink else Theme.colors.label
	--[[
		On the picture, not beside the name.

		Beside it, the pill took a hundred pixels off a card two hundred and
		sixty wide and cut three of the four names in half — "The Mansio",
		"The Gas Sta", "The Cemete". The photograph has room for it in the
		corner and nothing there to hide.
	]]
	local pill = Instance.new("Frame")
	pill.Name = "Grade"
	pill.Size = UDim2.fromOffset(86, 24)
	pill.Position = UDim2.new(1, -10, 1, -14)
	pill.AnchorPoint = Vector2.new(1, 1)
	pill.BackgroundColor3 = pillFill
	pill.BorderSizePixel = 0
	--- No ZIndex of its own: on this project's `Global` guis a child at the
	--- default 1 would then render *behind* it, which is where the word on
	--- the pill went the first time it was lifted to 2.
	pill.Parent = hero
	Theme.corner(pill, 12)
	Theme.stroke(pill, 2.5, Theme.colors.outline, 0)

	--- Always the difficulty, even locked: the button under it already says
	--- LOCKED, and saying it twice tells you less than knowing that the
	--- property you cannot play yet is the Medium one.
	Theme.text({
		name = "GradeWord",
		text = string.upper(world.difficulty),
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = pill,
		align = Enum.TextXAlignment.Center,
		color = pillInk,
		textSize = 13,
	})

	--[[
		The sentence the world was written with.

		Every property has a tagline in `Worlds.luau` — "Somebody let it go for
		a whole autumn", "Nobody has cut it since the last funeral" — and the
		card showed none of them. They do more to make a property worth
		choosing than any stat on the card, which is the handoff's point about
		them. Upright rather than italic: FredokaOne has no italic face and a
		skewed label is worse than a plain one.
	]]
	local tagline = Theme.text({
		name = "Tagline",
		text = world.tagline,
		size = UDim2.new(1, 0, 0, 18),
		position = UDim2.fromOffset(0, 32),
		parent = facts,
		align = Enum.TextXAlignment.Left,
		color = if open then Color3.fromRGB(74, 62, 48) else Theme.colors.label,
		textSize = 14,
		bold = false,
	})
	--- The card clips, so without this a long tagline is sliced through a
	--- letter at the edge rather than ending in an ellipsis.
	tagline.TextTruncate = Enum.TextTruncate.AtEnd

	--[[
		One line saying what you are signing up for.

		The required count, because an optional garage is not "section three of
		six" to anybody; the optional ones after it, because they are worth
		knowing about and not worth counting; the clock; and then your own best
		time if you have one or what the place pays if you have not.
	]]
	local required = #Worlds.requiredSections(world)
	local optional = #world.sections - required
	--- "6 + 2 sections", not "6 sections + 2 optional": the card is two
	--- hundred and forty pixels wide inside its padding and the longer form
	--- ran off the end of it.
	local summary = if optional > 0
		then `{required} + {optional} sections`
		else `{required} sections`
	summary ..= ` · {span(world.runSeconds)}`
	if best then
		summary ..= ` · best {Format.clock(best)}`
	else
		summary ..= ` · {string.format("%.1f", world.payoutMultiplier)}× cash`
	end
	local summaryLabel = Theme.text({
		name = "Summary",
		text = summary,
		size = UDim2.new(1, 0, 0, 18),
		position = UDim2.fromOffset(0, 52),
		parent = facts,
		align = Enum.TextXAlignment.Left,
		color = if open then Theme.colors.inkSoft else Theme.colors.label,
		textSize = 15,
	})
	summaryLabel.TextTruncate = Enum.TextTruncate.AtEnd

	--[[
		A locked card's button says what to go and do.

		It said LOCKED, which the dark face, the dimmed picture and the dead
		button had already said three times between them. What a player cannot
		see is which property opens this one, so that is what the button is
		for — with a padlock on it, so the word BEAT is not doing the work of
		saying it is shut.
	]]
	local gateName = if open
		then ""
		else Worlds.expect(world.requiresWorld :: string).name
	local start = Theme.chunkButton({
		name = "Start",
		variant = if open then "primary" else "disabled",
		text = if open then "START A RUN" else `BEAT {string.upper(gateName)}`,
		textSize = if open then 20 else 16,
		size = UDim2.new(1, 0, 0, 42),
		position = UDim2.fromScale(0, 1),
		anchor = Vector2.new(0, 1),
		parent = facts,
		radius = 14,
		outline = 4,
	})
	start.Modal = true

	if not open then
		--- Left of the words, in the button's own dead ink.
		Theme.icon({
			name = "Lock",
			prop = "Padlock",
			size = UDim2.fromOffset(26, 26),
			position = UDim2.new(0, 12, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			parent = start,
		})
		start.TextXAlignment = Enum.TextXAlignment.Center
	end

	if open then
		--[[
			The card is the whole decision.

			It used to pick the property, and then a Confirm button on the
			other panel started the game — two presses for one intention, and
			the first of them looked like the one that did something. The
			settings panel keeps the only setting there is, and pressing START
			A RUN on a property sends you to it.
		]]
		start.Activated:Connect(function()
			confirmRemote:FireServer({ worldId = world.id, maxPlayers = party })
			dismissedOnPad = true
			LevelSelect.setOpen(false)
		end)
	end
end

--[[
	What the cards are drawn from, as a string.

	`refresh` is wired to `PlayerState.Changed`, which fires several times a
	second while the panel is up, and it used to tear down all four cards and
	build them again every time. Nothing on a card had changed — but the
	button under the player's cursor was destroyed between the press and the
	release, so START A RUN did nothing at all, forever. Redraw when what is
	printed on them actually changes.
]]
local function cardSignature(): string
	local state = PlayerState.get()
	local parts = {}
	for _, world in Worlds.list do
		local open = if isUnlocked(world) then 1 else 0
		table.insert(parts, `{world.id}:{open}:{state.bestTimes[world.id] or 0}`)
	end
	return table.concat(parts, "|")
end

--- The signature the cards on screen were built from, or nil for none.
local drawnSignature: string? = nil

function LevelSelect.refresh()
	if not gui then
		return
	end

	local signature = cardSignature()
	if signature == drawnSignature then
		refreshSettings()
		return
	end
	drawnSignature = signature

	for _, child in mapHolder:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for order, world in Worlds.list do
		drawCard(world, order)
	end
	-- Card plus the layout's padding, less the padding the last one does not
	-- need; the exact height means the list stops where the cards do.
	--- Two per row, so the canvas grows by a row every second world.
	mapHolder.CanvasSize = UDim2.fromOffset(0, math.ceil(#Worlds.list / 2) * 272 - 16)
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
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")

	--[[
		Ground, not a shade over the lobby.

		This was forty per cent black over whatever the camera happened to be
		pointing at, which is the shape of a dialogue box — and the thing it is
		asking for is a two-hour commitment. The handoff gives world select and
		the store the same treatment for that reason, and gives it a name: it
		is a destination. `Theme.backdrop` is that ground, and the store stands
		on the same one so the two read as rooms in one building.
	]]
	Theme.backdrop(gui)

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
	--- Bigger than the pair of banner lists it replaces, because the map panel
	--- is now four picture cards two across and each of them is a card rather
	--- than a row.
	local PAIR_W, PANEL_H = 1040, 638
	--- The band above the panels: what this screen is, and the sentence the
	--- whole game is built on, said where the player commits to a run.
	local HEADER = 104
	local PAIR_H = HEADER + PANEL_H
	local holder = Instance.new("Frame")
	holder.Name = "Panels"
	holder.Size = UDim2.fromOffset(PAIR_W, PAIR_H)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	Theme.fitToViewport(holder, PAIR_W + 40, PAIR_H + 60)

	--[[
		"You arrive with nothing."

		The premise of the game, in the one place a player is deciding whether
		to spend two hours on it. It was a fifteen-point line under a panel
		title; the design puts it at the top of the screen at three times the
		size, and it is the only sentence here that is not an instruction.
	]]
	Theme.text({
		name = "Eyebrow",
		text = "PICK A PROPERTY",
		size = UDim2.new(1, 0, 0, 20),
		position = UDim2.fromOffset(6, 6),
		parent = holder,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.tips,
		textSize = 16,
	})
	Theme.text({
		name = "Headline",
		text = "You arrive with nothing.",
		size = UDim2.new(1, 0, 0, 54),
		position = UDim2.fromOffset(6, 30),
		parent = holder,
		align = Enum.TextXAlignment.Left,
		textSize = 44,
	})

	----------------------------------------------------------------
	-- Left: the settings, and the number that started all this
	----------------------------------------------------------------
	local settings, body = titled(
		holder,
		"GameSettings",
		"GAME SETTINGS",
		UDim2.fromOffset(400, PANEL_H),
		UDim2.new(0.5, -300, 0, HEADER + PANEL_H * 0.5)
	)

	--[[
		The number that started all this.

		"Where's the box that selects how many players in my group?" was the
		complaint, and the answer was that there wasn't one — four pads told
		you how many were standing on them and nothing let you say how many
		you meant to play with. Minus and plus in the margins either side of
		the well, so the three of them read as one control.
	]]
	partyValue = field(body, 14, "MAX PLAYERS", 56)
	button(body, "−", UDim2.fromOffset(48, 48), UDim2.fromOffset(0, 38), "gold").Activated:Connect(function()
		party = math.max(party - 1, 1)
		refreshSettings()
	end)
	button(body, "+", UDim2.fromOffset(48, 48), UDim2.new(1, -48, 0, 38), "gold").Activated:Connect(function()
		party = math.min(party + 1, MAX_PARTY)
		refreshSettings()
	end)

	--[[
		Two counters, because the panel had nothing else true to say.

		It used to repeat the chosen property's difficulty, clock and payout
		back at you in three boxes — all three of which are now printed on the
		property's own card, where you are looking when you choose it. What is
		worth a panel of its own is the part that carries between runs: how
		much of the map you have taken, and the tips you kept while taking it.
	]]
	Theme.text({
		name = "RecordHeading",
		text = "YOUR RECORD",
		size = UDim2.new(1, 0, 0, 18),
		position = UDim2.fromOffset(0, 130),
		parent = body,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.label,
		textSize = 15,
	})
	beatenValue = statBlock(
		body,
		"WORLDS BEATEN",
		UDim2.new(0.5, -8, 0, 104),
		UDim2.fromOffset(0, 156)
	)
	tipsValue = statBlock(
		body,
		"TIPS KEPT",
		UDim2.new(0.5, -8, 0, 104),
		UDim2.new(0.5, 8, 0, 156)
	)

	--[[
		What a run is, in three lines, for the player standing on their first
		pad. The lobby says none of this anywhere else, and the third line is
		the one nobody works out on their own: run cash is spent inside the
		run and tips are what leaves with you.
	]]
	local guide = Theme.chip({
		name = "Guide",
		size = UDim2.new(1, 0, 0, PANEL_H - 70 - 310 - 28),
		position = UDim2.fromOffset(0, 310),
		parent = body,
		radius = 18,
	})
	Theme.stroke(guide, 3, Theme.colors.outline, 0)
	Theme.pad(guide, 16, 18, 16, 18)

	Theme.text({
		name = "GuideHeading",
		text = "HOW A RUN WORKS",
		size = UDim2.new(1, 0, 0, 18),
		position = UDim2.fromOffset(0, 0),
		parent = guide,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.tips,
		textSize = 15,
	})

	local STEPS = {
		"Pick a property and start the run.",
		"Clear every section before the clock runs out.",
		"Run cash stays in the run. Tips come home with you.",
	}
	for index, line in STEPS do
		local y = 30 + (index - 1) * 46

		--- A gold diamond for a bullet, the same mark as the panel headings.
		local dot = Instance.new("Frame")
		dot.Name = `Dot{index}`
		dot.Size = UDim2.fromOffset(9, 9)
		dot.Position = UDim2.fromOffset(2, y + 7)
		dot.Rotation = 45
		dot.BackgroundColor3 = Theme.colors.tips
		dot.BorderSizePixel = 0
		dot.Parent = guide

		local text = Theme.text({
			name = `Step{index}`,
			text = line,
			size = UDim2.new(1, -24, 0, 40),
			position = UDim2.fromOffset(24, y),
			parent = guide,
			align = Enum.TextXAlignment.Left,
			color = Theme.colors.body,
			textSize = 16,
		})
		--- Two lines when it needs them, which the last one does.
		text.TextWrapped = true
		text.TextYAlignment = Enum.TextYAlignment.Top
	end

	--[[
		The same cross the book closes with, on a red disc in the corner.

		It is the only control on the panel that is pure furniture, so it is
		the one where matching the shape is most of the work.
	]]
	local close = Theme.chunkButton({
		name = "Close",
		variant = "danger",
		size = UDim2.fromOffset(46, 46),
		position = UDim2.new(1, -18, 0, 18),
		anchor = Vector2.new(1, 0),
		parent = settings,
		radius = Theme.PILL,
		drop = 4,
		outline = 4,
	})
	close.Modal = true
	Theme.icon({
		name = "Mark",
		prop = "Cross",
		size = UDim2.fromScale(0.62, 0.62),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = close,
	})
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
		"THE PROPERTIES",
		UDim2.fromOffset(580, PANEL_H),
		UDim2.new(0.5, 210, 0, HEADER + PANEL_H * 0.5)
	)

	mapHolder = Instance.new("ScrollingFrame")
	mapHolder.Name = "Maps"
	mapHolder.Size = UDim2.fromScale(1, 1)
	mapHolder.BackgroundTransparency = 1
	mapHolder.BorderSizePixel = 0
	-- Wide enough and light enough to be seen against the panel: it is half
	-- of what says the list goes on past the bottom of the frame.
	mapHolder.ScrollBarThickness = 8
	mapHolder.ScrollBarImageColor3 = Color3.fromRGB(196, 200, 210)
	mapHolder.ScrollBarImageTransparency = 0.25
	mapHolder.CanvasSize = UDim2.new()
	mapHolder.Parent = mapBody

	--[[
		Two across, not a list one deep.

		A hundred-pixel banner stacked four high needed a scrollbar and put
		the fourth property under the fold, where The Cemetery did not exist
		as far as the screen was concerned. Two columns fit four cards with no
		scrolling at all, and a card that is half picture needs the width more
		than the list needed the height.
	]]
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0.5, -8, 0, 256)
	grid.CellPadding = UDim2.fromOffset(16, 16)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = mapHolder
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
