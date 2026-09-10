--!strict
--[[
	RoundEnd — the board, after the grate.

	Finishing a property paid a completion bonus split by ground actually
	cleared, and said so in a toast that scrolled away. The one number the
	whole co-op design rests on — *the person who did the mowing is the person
	who gets paid* — was a line of text nobody could read twice.

	So it gets a moment. The outro's shot plays first and this comes up over
	it: the time, the clock you had left, and one row per player showing what
	they cleared, what share of the pool that was, and what it paid.

	It shows only after a win. Running out of time is the outro's business —
	there is no split to read out, because there is no pool.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Remotes = require(Shared.Remotes)
local Worlds = require(Shared.Config.Worlds)
local Theme = require(script.Parent.Theme)

local RoundEnd = {}

local player = Players.LocalPlayer
local gui: ScreenGui
local scrim: Frame
--- A plain frame on a tablet, a `ScrollingFrame` on a phone; only its
--- children and its parent are ever touched, so the wider type is honest.
local column: GuiObject

--- How long the outro's shot gets before the numbers arrive over it.
local AFTER_THE_SHOT = 3.5

local shown = false
local generation = 0

local INK = Theme.colors.outline
local TRACK = Color3.fromRGB(217, 203, 176)

--------------------------------------------------------------------
-- Pieces
--------------------------------------------------------------------

--- One of the three figures across the top: a small heading over a big number.
--[[
	The screen has two shapes, and the phone one scrolls.

	Authored at 960 x 900, which `fitToViewport` draws at 0.415 on an
	844 x 390 phone: a player's name at nine points and a payout slab at
	eighteen. The board is the point of this screen — the handoff's own line
	is "give the contribution split a moment" — and nine points is not a
	moment.

	So on a phone every piece stands down to a size that reads, the column
	becomes a scroll, and BACK TO THE LOBBY comes out of that scroll and pins
	itself to the bottom, where it cannot be scrolled past.
]]
local phone = false

local function statBlock(order: number, heading: string, value: string, note: string?, gold: boolean): Frame
	local blockH = if phone then 62 else 108
	local block: Frame
	if gold then
		block = Theme.cardFace({
			name = heading,
			size = UDim2.fromOffset(0, blockH),
			parent = column,
			radius = 18,
			drop = 6,
			outline = 4,
			top = Color3.fromRGB(255, 217, 104),
			bottom = Color3.fromRGB(245, 168, 28),
			shadow = Color3.fromRGB(169, 110, 8),
		})
	else
		block = Theme.chunkPanel({
			name = heading,
			size = UDim2.fromOffset(0, blockH),
			parent = column,
			radius = 18,
			drop = 6,
			outline = 4,
			top = Color3.fromRGB(44, 33, 24),
			bottom = Color3.fromRGB(44, 33, 24),
		})
	end
	local seat = block.Parent :: Frame
	seat.LayoutOrder = order
	seat.Size = UDim2.new(1 / 3, -12, 0, blockH)
	Theme.pad(block, if phone then 8 else 14, if phone then 10 else 16, if phone then 8 else 14, if phone then 10 else 16)

	Theme.text({
		name = "Heading",
		text = heading,
		size = UDim2.new(1, 0, 0, 18),
		position = UDim2.fromOffset(0, 0),
		parent = block,
		align = Enum.TextXAlignment.Left,
		color = if gold then Color3.fromRGB(92, 60, 6) else Theme.colors.label,
		textSize = if phone then 11 else 14,
	})
	Theme.text({
		name = "Value",
		text = value,
		size = UDim2.new(1, 0, 0, if phone then 26 else 40),
		position = UDim2.fromOffset(0, if phone then 14 else 22),
		parent = block,
		align = Enum.TextXAlignment.Left,
		color = if gold then Color3.fromRGB(24, 18, 10) else Theme.colors.text,
		textSize = if phone then 22 else 34,
	})
	if note then
		Theme.text({
			name = "Note",
			text = note,
			size = UDim2.new(1, 0, 0, if phone then 14 else 20),
			position = UDim2.fromOffset(0, if phone then 40 else 62),
			parent = block,
			align = Enum.TextXAlignment.Left,
			color = if gold then Color3.fromRGB(92, 60, 6) else Theme.colors.label,
			textSize = if phone then 11 else 15,
			bold = false,
		})
	end
	return block
end

--- One player's line: who, how much ground, what share, what it paid.
local function playerRow(parent: Instance, order: number, row: any, units: number, top: boolean)
	local rowH = if phone then 48 else 66
	local card = Theme.cardFace({
		name = tostring(row.name),
		size = UDim2.new(1, -8, 0, rowH),
		parent = parent,
		radius = 16,
		drop = 4,
		outline = 4,
	})
	;(card.Parent :: Frame).LayoutOrder = order
	Theme.pad(card, 6, if phone then 10 else 14, 6, if phone then 10 else 14)

	local avatar = if phone then 32 else 42
	local nameLeft = avatar + 14
	local well = Instance.new("Frame")
	well.Name = "Face"
	well.Size = UDim2.fromOffset(avatar, avatar)
	well.Position = UDim2.fromScale(0, 0.5)
	well.AnchorPoint = Vector2.new(0, 0.5)
	well.BackgroundColor3 = Theme.colors.wellLight
	well.BorderSizePixel = 0
	well.Parent = card
	Theme.corner(well, 12)
	Theme.stroke(well, 3, INK, 0)

	--[[
		The player's own face, fetched off the main thread.

		`GetUserThumbnailAsync` is a web call and this screen is built in the
		middle of a run ending. The well is drawn either way, so a slow or
		failed fetch is a cream square rather than a hole in the row.
	]]
	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(
				row.userId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size48x48
			)
		end)
		if ok and typeof(image) == "string" and well.Parent then
			local picture = Instance.new("ImageLabel")
			picture.Name = "Head"
			picture.Size = UDim2.fromScale(1, 1)
			picture.BackgroundTransparency = 1
			picture.Image = image
			picture.Parent = well
			Theme.corner(picture, 12)
		end
	end)

	local name = Theme.text({
		name = "Name",
		text = tostring(row.name),
		size = UDim2.fromOffset(if phone then 140 else 190, if phone then 18 else 24),
		position = UDim2.fromOffset(nameLeft, if phone then 5 else 8),
		parent = card,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.ink,
		textSize = if phone then 16 else 21,
	})
	name.TextTruncate = Enum.TextTruncate.AtEnd

	--[[
		The pill goes in the name block, not beside it.

		Out to the right of the name it ran under the share bar, which starts
		at three hundred: the row is a name block, a bar and a price, and
		anything that is about the name belongs inside the first of those.
	]]
	if top then
		local pill = Theme.chip({
			name = "MostGround",
			size = UDim2.fromOffset(if phone then 88 else 112, if phone then 16 else 20),
			position = UDim2.fromOffset(nameLeft, if phone then 25 else 34),
			parent = card,
			radius = Theme.PILL,
		})
		pill.BackgroundColor3 = Theme.colors.tips
		Theme.stroke(pill, 2.5, INK, 0)
		Theme.text({
			name = "Text",
			text = "MOST GROUND",
			size = UDim2.fromScale(1, 1),
			position = UDim2.fromScale(0, 0),
			parent = pill,
			align = Enum.TextXAlignment.Center,
			color = Color3.fromRGB(24, 18, 10),
			textSize = if phone then 10 else 12,
		})
	end

	Theme.text({
		name = "Units",
		text = `{Format.tally(row.units)} units cleared`,
		size = UDim2.fromOffset(if top then 120 else 240, if phone then 16 else 20),
		position = UDim2.fromOffset(
			if top then nameLeft + (if phone then 94 else 118) else nameLeft,
			if phone then 26 else 34
		),
		parent = card,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.inkSoft,
		textSize = if phone then 12 else 15,
		bold = false,
	})

	local share = if units > 0 then row.units / units else 0

	--- The bar takes whatever is left between the name block and the numbers.
	local barLeft = if phone then 240 else 300
	local barRight = if phone then 190 else 260
	local bar = Instance.new("Frame")
	bar.Name = "Share"
	bar.Size = UDim2.new(1, -(barLeft + barRight), 0, if phone then 16 else 22)
	bar.Position = UDim2.new(0, barLeft, 0.5, 0)
	bar.AnchorPoint = Vector2.new(0, 0.5)
	bar.BackgroundColor3 = TRACK
	bar.BorderSizePixel = 0
	bar.ClipsDescendants = true
	bar.Parent = card
	Theme.corner(bar, 11)
	Theme.stroke(bar, 3, INK, 0)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(math.clamp(share, 0, 1), 1)
	fill.BackgroundColor3 = Theme.gradients.fill.top
	fill.BorderSizePixel = 0
	fill.Parent = bar
	Theme.corner(fill, 11)
	local grade = Instance.new("UIGradient")
	grade.Color = ColorSequence.new(Theme.gradients.fill.top, Theme.gradients.fill.bottom)
	grade.Rotation = 90
	grade.Parent = fill

	Theme.text({
		name = "Percent",
		text = Format.percent(share),
		size = UDim2.fromOffset(if phone then 60 else 84, 24),
		position = UDim2.new(1, if phone then -100 else -132, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		parent = card,
		align = Enum.TextXAlignment.Right,
		color = Theme.colors.inkSoft,
		textSize = if phone then 14 else 18,
	})

	local paid = Theme.chunkButton({
		name = "Paid",
		variant = "primary",
		text = `{Format.count(row.tips)} tips`,
		textSize = if phone then 15 else 19,
		size = UDim2.fromOffset(if phone then 92 else 120, if phone then 34 else 44),
		position = UDim2.fromScale(1, 0.5),
		anchor = Vector2.new(1, 0.5),
		parent = card,
		radius = 13,
		outline = 3,
	})
	paid.Active = false
	paid.AutoButtonColor = false
end

--- One of the three facts under the board.
local function factChip(parent: Instance, order: number, heading: string, value: string, colour: Color3)
	local chip = Theme.chip({
		name = heading,
		size = UDim2.new(1 / 3, -8, 0, if phone then 38 else 56),
		parent = parent,
		radius = 14,
	})
	chip.BackgroundColor3 = Color3.fromRGB(30, 22, 16)
	chip.LayoutOrder = order
	Theme.stroke(chip, 3, INK, 0)
	Theme.pad(chip, if phone then 5 else 8, if phone then 10 else 16, if phone then 5 else 8, if phone then 10 else 16)

	Theme.text({
		name = "Heading",
		text = heading,
		size = UDim2.new(1, 0, 0, if phone then 12 else 16),
		position = UDim2.fromOffset(0, 0),
		parent = chip,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.label,
		textSize = if phone then 10 else 13,
	})
	Theme.text({
		name = "Value",
		text = value,
		size = UDim2.new(1, 0, 0, if phone then 16 else 22),
		position = UDim2.fromOffset(0, if phone then 12 else 18),
		parent = chip,
		align = Enum.TextXAlignment.Left,
		color = colour,
		textSize = if phone then 15 else 20,
	})
end

--------------------------------------------------------------------
-- The board
--------------------------------------------------------------------

local function clear()
	if not column then
		return
	end
	for _, child in column:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	--- On a phone the button is pinned outside the scroll, so it is the one
	--- piece a redraw has to reach past the column for.
	local outside = column.Parent
	if outside then
		for _, child in outside:GetChildren() do
			if child:IsA("GuiObject") and child.Name == "BackHolder" then
				child:Destroy()
			end
		end
	end
end

local function draw(result: any)
	clear()

	local mine: any = nil
	for _, row in result.players do
		if row.userId == player.UserId then
			mine = row
		end
	end

	--- The eyebrow, between two diamonds, and the headline.
	local eyebrow = Instance.new("Frame")
	eyebrow.Name = "Eyebrow"
	eyebrow.Size = UDim2.new(1, 0, 0, if phone then 16 else 24)
	eyebrow.BackgroundTransparency = 1
	eyebrow.LayoutOrder = 1
	eyebrow.Parent = column
	local eyebrowFlow = Instance.new("UIListLayout")
	eyebrowFlow.FillDirection = Enum.FillDirection.Horizontal
	eyebrowFlow.HorizontalAlignment = Enum.HorizontalAlignment.Center
	eyebrowFlow.VerticalAlignment = Enum.VerticalAlignment.Center
	eyebrowFlow.SortOrder = Enum.SortOrder.LayoutOrder
	eyebrowFlow.Padding = UDim.new(0, 14)
	eyebrowFlow.Parent = eyebrow

	for order = 1, 3 do
		if order == 2 then
			local label = Theme.text({
				name = "Text",
				text = "THE GRATE IS OPEN",
				size = UDim2.fromOffset(280, 24),
				position = UDim2.fromScale(0, 0),
				parent = eyebrow,
				align = Enum.TextXAlignment.Center,
				color = Theme.colors.tips,
				textSize = if phone then 12 else 16,
			})
			label.LayoutOrder = 2
		else
			local mark = Instance.new("Frame")
			mark.Name = `Mark{order}`
			mark.Size = UDim2.fromOffset(if phone then 11 else 16, if phone then 11 else 16)
			mark.Rotation = 45
			mark.BackgroundColor3 = Theme.colors.tips
			mark.BorderSizePixel = 0
			mark.LayoutOrder = order
			mark.Parent = eyebrow
		end
	end

	local headline = Theme.text({
		name = "Headline",
		text = `{result.worldName}, cleared`,
		size = UDim2.new(1, 0, 0, if phone then 34 else 62),
		position = UDim2.fromScale(0, 0),
		parent = column,
		align = Enum.TextXAlignment.Center,
		textSize = if phone then 28 else 56,
	})
	headline.LayoutOrder = 2

	--- The three figures.
	local figures = Instance.new("Frame")
	figures.Name = "Figures"
	figures.Size = UDim2.new(1, 0, 0, if phone then 70 else 116)
	figures.BackgroundTransparency = 1
	figures.LayoutOrder = 3
	figures.Parent = column
	local figureFlow = Instance.new("UIListLayout")
	figureFlow.FillDirection = Enum.FillDirection.Horizontal
	figureFlow.SortOrder = Enum.SortOrder.LayoutOrder
	figureFlow.Padding = UDim.new(0, 18)
	figureFlow.Parent = figures

	local previous = if mine then mine.previousBest else nil
	local beat = previous == nil or result.elapsed < previous
	local note = if not beat and typeof(previous) == "number"
		then `BEST STANDS — {Format.clock(previous)}`
		elseif typeof(previous) == "number" then `NEW BEST — was {Format.clock(previous)}`
		else "YOUR FIRST TIME ON IT"

	local blocks: { { heading: string, value: string, note: string?, gold: boolean } } = {
		{ heading = "FINISHED IN", value = Format.clock(result.elapsed), note = note, gold = true },
		{ heading = "CLOCK LEFT", value = Format.clock(result.clockLeft), gold = false },
		{ heading = "UNITS CLEARED", value = Format.tally(result.units), gold = false },
	}
	for order, block in blocks do
		local made = statBlock(order, block.heading, block.value, block.note, block.gold)
		;(made.Parent :: Frame).Parent = figures
		if not block.gold then
			local value = made:FindFirstChild("Value")
			if value and value:IsA("TextLabel") then
				value.TextColor3 = if order == 2 then Theme.colors.cash else Theme.colors.tips
			end
		end
	end

	--- The board itself.
	local boardHead = if phone then 42 else 96
	local boardStep = if phone then 54 else 74
	local boardH = boardHead + #result.players * boardStep
	local board = Theme.chunkPanel({
		name = "Board",
		size = UDim2.new(1, 0, 0, boardH),
		parent = column,
		radius = 22,
		drop = 8,
		outline = 5,
	})
	;(board.Parent :: Frame).LayoutOrder = 4
	;(board.Parent :: Frame).Size = UDim2.new(1, 0, 0, boardH)
	Theme.pad(board, if phone then 12 else 18, if phone then 14 else 20, if phone then 12 else 18, if phone then 14 else 20)

	Theme.text({
		name = "BoardHeading",
		text = "Who did the work",
		size = UDim2.new(1, 0, 0, if phone then 20 else 28),
		position = UDim2.fromOffset(0, 0),
		parent = board,
		align = Enum.TextXAlignment.Left,
		textSize = if phone then 17 else 22,
	})
	--- The sentence under the heading is the one thing on this screen with no
	--- room on a phone; the bars underneath say the same thing in a picture.
	if not phone then
		Theme.text({
			name = "BoardNote",
			text = "the round bonus splits by ground actually cleared",
			size = UDim2.new(1, 0, 0, 22),
			position = UDim2.fromOffset(0, 28),
			parent = board,
			align = Enum.TextXAlignment.Left,
			color = Theme.colors.label,
			textSize = 15,
			bold = false,
		})
	end

	local rowsTop = if phone then 26 else 60
	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.Size = UDim2.new(1, 0, 1, -rowsTop)
	rows.Position = UDim2.fromOffset(0, rowsTop)
	rows.BackgroundTransparency = 1
	rows.Parent = board
	local rowFlow = Instance.new("UIListLayout")
	rowFlow.SortOrder = Enum.SortOrder.LayoutOrder
	rowFlow.Padding = UDim.new(0, if phone then 6 else 10)
	rowFlow.Parent = rows

	for order, row in result.players do
		playerRow(rows, order, row, result.units, order == 1)
	end

	--- The three facts, outside the board: there is no free space inside it.
	local facts = Instance.new("Frame")
	facts.Name = "Facts"
	facts.Size = UDim2.new(1, 0, 0, if phone then 38 else 56)
	facts.BackgroundTransparency = 1
	facts.LayoutOrder = 5
	facts.Parent = column
	local factFlow = Instance.new("UIListLayout")
	factFlow.FillDirection = Enum.FillDirection.Horizontal
	factFlow.SortOrder = Enum.SortOrder.LayoutOrder
	factFlow.Padding = UDim.new(0, if phone then 8 else 12)
	factFlow.Parent = facts

	factChip(facts, 1, "CLEAN STRIPES", Format.tally(result.stripes), Theme.colors.tips)
	factChip(facts, 2, "GOLDEN BLADES", Format.tally(result.blades), Theme.colors.tips)
	factChip(facts, 3, "WAVES PER SECTION", tostring(result.waves), Theme.colors.cash)

	--[[
		What just opened, and the way out.

		The handoff draws two buttons here — ON TO THE MANSION beside BACK TO
		THE LOBBY — and the first of them cannot be true: a run is started by
		standing on a pad in the lobby, so a button that claims to take you
		straight to the next property would either lie or reach past the pads.
		The unlock is worth saying, so it is said, and the one button does the
		one thing there is to do.
	]]
	local nextWorld: string? = nil
	for _, world in Worlds.list do
		if world.requiresWorld == result.worldId then
			nextWorld = world.name
			break
		end
	end

	if nextWorld then
		local opened = Theme.chunkPanel({
			name = "Opened",
			size = UDim2.new(1, 0, 0, if phone then 38 else 56),
			parent = column,
			radius = 16,
			drop = 5,
			outline = 4,
			top = Color3.fromRGB(255, 217, 104),
			bottom = Color3.fromRGB(245, 168, 28),
			shadow = Color3.fromRGB(169, 110, 8),
		})
		;(opened.Parent :: Frame).LayoutOrder = 6
		;(opened.Parent :: Frame).Size = UDim2.new(1, 0, 0, if phone then 38 else 56)
		Theme.text({
			name = "Text",
			text = `{string.upper(nextWorld)} IS OPEN — PICK IT FROM A PAD`,
			size = UDim2.fromScale(1, 1),
			position = UDim2.fromScale(0, 0),
			parent = opened,
			align = Enum.TextXAlignment.Center,
			color = Color3.fromRGB(24, 18, 10),
			textSize = if phone then 15 else 22,
		})
	end

	--[[
		Out of the scroll on a phone, and pinned under it.

		Everything above it scrolls there, and the one control on the screen
		is not something a player should have to scroll to find.
	]]
	local back = Theme.chunkButton({
		name = "Back",
		variant = "primary",
		text = "BACK TO THE LOBBY",
		textSize = if phone then 18 else 24,
		size = if phone
			then UDim2.new(1, 0, 0, 44)
			else UDim2.new(1, 0, 0, 62),
		position = if phone then UDim2.fromScale(0.5, 1) else UDim2.fromOffset(0, 0),
		anchor = if phone then Vector2.new(0.5, 1) else Vector2.zero,
		parent = if phone then (column.Parent :: Instance) else column,
		radius = 16,
		outline = 4,
	})
	if not phone then
		local seat = back.Parent :: Frame
		seat.LayoutOrder = 7
		seat.Size = UDim2.new(1, 0, 0, 62)
	end
	back.Modal = true
	back.Activated:Connect(function()
		RoundEnd.hide()
	end)
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MowRoundEnd"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	--- Above the outro's bars: the shot is what this is drawn over.
	gui.DisplayOrder = 12
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")

	scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = Color3.fromRGB(20, 14, 8)
	scrim.BackgroundTransparency = 0.3
	scrim.BorderSizePixel = 0
	scrim.Parent = gui

	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.Size = if phone then UDim2.fromOffset(796, 350) else UDim2.fromOffset(960, 900)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	Theme.fitToViewport(holder, if phone then 844 else 1000, if phone then 390 else 940, nil, nil, nil, phone)

	--[[
		A scroll on a phone, a column on anything larger.

		Even at phone sizes the pieces come to about four hundred and fifty:
		three figures, a board of up to twelve, three facts and the line
		saying what just opened. That is a short scroll rather than a screen,
		and a short scroll is the honest answer — the alternative is cutting
		one of them, and every one of them is somebody's result.
	]]
	if phone then
		local scroll = Instance.new("ScrollingFrame")
		scroll.Name = "Column"
		scroll.Size = UDim2.new(1, 0, 1, -52)
		scroll.BackgroundTransparency = 1
		scroll.BorderSizePixel = 0
		scroll.ScrollBarThickness = 6
		scroll.ScrollBarImageColor3 = Color3.fromRGB(24, 18, 10)
		scroll.ScrollBarImageTransparency = 0.2
		scroll.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
		scroll.CanvasSize = UDim2.new()
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		scroll.Parent = holder
		column = scroll
	else
		local plain = Instance.new("Frame")
		plain.Name = "Column"
		plain.Size = UDim2.fromScale(1, 1)
		plain.BackgroundTransparency = 1
		plain.Parent = holder
		column = plain
	end

	local flow = Instance.new("UIListLayout")
	flow.SortOrder = Enum.SortOrder.LayoutOrder
	flow.Padding = UDim.new(0, if phone then 8 else 20)
	flow.HorizontalAlignment = Enum.HorizontalAlignment.Center
	flow.Parent = column
end

function RoundEnd.show(result: any)
	if shown or not gui or type(result) ~= "table" or type(result.players) ~= "table" then
		return
	end
	shown = true
	draw(result)
	gui.Enabled = true
	Theme.holdCursor(true)

	scrim.BackgroundTransparency = 1
	TweenService:Create(
		scrim,
		TweenInfo.new(0.45, Enum.EasingStyle.Quad),
		{ BackgroundTransparency = 0.3 }
	):Play()
end

function RoundEnd.hide()
	if not shown then
		return
	end
	shown = false
	gui.Enabled = false
	Theme.holdCursor(false)
	clear()
end

--- The screen's two shapes, chosen before it is built.
local function rebuild()
	local small = Theme.isPhone()
	if gui and small == phone then
		return
	end
	xpcall(function()
		phone = small
		local previous = gui
		if previous then
			previous:Destroy()
		end
		build()
	end, function(err)
		warn(`[RoundEnd] rebuilding for a {if small then "phone" else "tablet"} failed: {err}`)
	end)
end

function RoundEnd.start()
	Theme.onScreenChange(rebuild)

	local last = ""
	Remotes.event(Remotes.ROUND_STATE).OnClientEvent:Connect(function(state: any)
		if type(state) ~= "table" then
			return
		end
		local phase = tostring(state.phase)
		if phase ~= last then
			last = phase
			generation += 1
			local mine = generation

			if phase == "won" and type(state.result) == "table" then
				--- After the shot, not over the top of it: the fly-out is the
				--- last look at the property and this is the reckoning.
				local result = state.result
				task.delay(AFTER_THE_SHOT, function()
					if generation == mine then
						RoundEnd.show(result)
					end
				end)
			else
				RoundEnd.hide()
			end
		end
	end)
end

return RoundEnd
