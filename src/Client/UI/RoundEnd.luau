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
local column: Frame

--- How long the outro's shot gets before the numbers arrive over it.
local AFTER_THE_SHOT = 3.5

local shown = false
local generation = 0

local INK = Theme.colors.outline
local CARD_INK = Color3.fromRGB(46, 36, 24)
local CARD_SOFT = Color3.fromRGB(110, 96, 80)
local TRACK = Color3.fromRGB(217, 203, 176)

--------------------------------------------------------------------
-- Pieces
--------------------------------------------------------------------

--- One of the three figures across the top: a small heading over a big number.
local function statBlock(order: number, heading: string, value: string, note: string?, gold: boolean): Frame
	local block: Frame
	if gold then
		block = Theme.cardFace({
			name = heading,
			size = UDim2.fromOffset(0, 108),
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
			size = UDim2.fromOffset(0, 108),
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
	seat.Size = UDim2.new(1 / 3, -12, 0, 108)
	Theme.pad(block, 14, 16, 14, 16)

	Theme.text({
		name = "Heading",
		text = heading,
		size = UDim2.new(1, 0, 0, 18),
		position = UDim2.fromOffset(0, 0),
		parent = block,
		align = Enum.TextXAlignment.Left,
		color = if gold then Color3.fromRGB(92, 60, 6) else Theme.colors.label,
		textSize = 14,
	})
	Theme.text({
		name = "Value",
		text = value,
		size = UDim2.new(1, 0, 0, 40),
		position = UDim2.fromOffset(0, 22),
		parent = block,
		align = Enum.TextXAlignment.Left,
		color = if gold then Color3.fromRGB(24, 18, 10) else Theme.colors.text,
		textSize = 34,
	})
	if note then
		Theme.text({
			name = "Note",
			text = note,
			size = UDim2.new(1, 0, 0, 20),
			position = UDim2.fromOffset(0, 62),
			parent = block,
			align = Enum.TextXAlignment.Left,
			color = if gold then Color3.fromRGB(92, 60, 6) else Theme.colors.label,
			textSize = 15,
			bold = false,
		})
	end
	return block
end

--- One player's line: who, how much ground, what share, what it paid.
local function playerRow(parent: Instance, order: number, row: any, units: number, top: boolean)
	local card = Theme.cardFace({
		name = tostring(row.name),
		size = UDim2.new(1, -8, 0, 66),
		parent = parent,
		radius = 16,
		drop = 4,
		outline = 4,
	})
	;(card.Parent :: Frame).LayoutOrder = order
	Theme.pad(card, 6, 14, 6, 14)

	local well = Instance.new("Frame")
	well.Name = "Face"
	well.Size = UDim2.fromOffset(42, 42)
	well.Position = UDim2.fromScale(0, 0.5)
	well.AnchorPoint = Vector2.new(0, 0.5)
	well.BackgroundColor3 = Color3.fromRGB(232, 219, 194)
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
		size = UDim2.fromOffset(190, 24),
		position = UDim2.fromOffset(56, 8),
		parent = card,
		align = Enum.TextXAlignment.Left,
		color = CARD_INK,
		textSize = 21,
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
			size = UDim2.fromOffset(112, 20),
			position = UDim2.fromOffset(56, 34),
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
			textSize = 12,
		})
	end

	Theme.text({
		name = "Units",
		text = `{Format.tally(row.units)} units cleared`,
		size = UDim2.fromOffset(if top then 120 else 240, 20),
		position = UDim2.fromOffset(if top then 174 else 56, 34),
		parent = card,
		align = Enum.TextXAlignment.Left,
		color = CARD_SOFT,
		textSize = 15,
		bold = false,
	})

	local share = if units > 0 then row.units / units else 0

	local bar = Instance.new("Frame")
	bar.Name = "Share"
	bar.Size = UDim2.new(1, -560, 0, 22)
	bar.Position = UDim2.new(0, 300, 0.5, 0)
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
	fill.BackgroundColor3 = Color3.fromRGB(143, 224, 124)
	fill.BorderSizePixel = 0
	fill.Parent = bar
	Theme.corner(fill, 11)
	local grade = Instance.new("UIGradient")
	grade.Color = ColorSequence.new(Color3.fromRGB(143, 224, 124), Color3.fromRGB(79, 184, 60))
	grade.Rotation = 90
	grade.Parent = fill

	Theme.text({
		name = "Percent",
		text = Format.percent(share),
		size = UDim2.fromOffset(84, 24),
		position = UDim2.new(1, -132, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		parent = card,
		align = Enum.TextXAlignment.Right,
		color = CARD_SOFT,
		textSize = 18,
	})

	local paid = Theme.chunkButton({
		name = "Paid",
		variant = "primary",
		text = `{Format.count(row.tips)} tips`,
		textSize = 19,
		size = UDim2.fromOffset(120, 44),
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
		size = UDim2.new(1 / 3, -8, 0, 56),
		parent = parent,
		radius = 14,
	})
	chip.BackgroundColor3 = Color3.fromRGB(30, 22, 16)
	chip.LayoutOrder = order
	Theme.stroke(chip, 3, INK, 0)
	Theme.pad(chip, 8, 16, 8, 16)

	Theme.text({
		name = "Heading",
		text = heading,
		size = UDim2.new(1, 0, 0, 16),
		position = UDim2.fromOffset(0, 0),
		parent = chip,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.label,
		textSize = 13,
	})
	Theme.text({
		name = "Value",
		text = value,
		size = UDim2.new(1, 0, 0, 22),
		position = UDim2.fromOffset(0, 18),
		parent = chip,
		align = Enum.TextXAlignment.Left,
		color = colour,
		textSize = 20,
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
	eyebrow.Size = UDim2.new(1, 0, 0, 24)
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
				textSize = 16,
			})
			label.LayoutOrder = 2
		else
			local mark = Instance.new("Frame")
			mark.Name = `Mark{order}`
			mark.Size = UDim2.fromOffset(16, 16)
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
		size = UDim2.new(1, 0, 0, 62),
		position = UDim2.fromScale(0, 0),
		parent = column,
		align = Enum.TextXAlignment.Center,
		textSize = 56,
	})
	headline.LayoutOrder = 2

	--- The three figures.
	local figures = Instance.new("Frame")
	figures.Name = "Figures"
	figures.Size = UDim2.new(1, 0, 0, 116)
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
	local board = Theme.chunkPanel({
		name = "Board",
		size = UDim2.new(1, 0, 0, 96 + #result.players * 74),
		parent = column,
		radius = 22,
		drop = 8,
		outline = 5,
	})
	;(board.Parent :: Frame).LayoutOrder = 4
	;(board.Parent :: Frame).Size = UDim2.new(1, 0, 0, 96 + #result.players * 74)
	Theme.pad(board, 18, 20, 18, 20)

	Theme.text({
		name = "BoardHeading",
		text = "Who did the work",
		size = UDim2.new(1, 0, 0, 28),
		position = UDim2.fromOffset(0, 0),
		parent = board,
		align = Enum.TextXAlignment.Left,
		textSize = 22,
	})
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

	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.Size = UDim2.new(1, 0, 1, -60)
	rows.Position = UDim2.fromOffset(0, 60)
	rows.BackgroundTransparency = 1
	rows.Parent = board
	local rowFlow = Instance.new("UIListLayout")
	rowFlow.SortOrder = Enum.SortOrder.LayoutOrder
	rowFlow.Padding = UDim.new(0, 10)
	rowFlow.Parent = rows

	for order, row in result.players do
		playerRow(rows, order, row, result.units, order == 1)
	end

	--- The three facts, outside the board: there is no free space inside it.
	local facts = Instance.new("Frame")
	facts.Name = "Facts"
	facts.Size = UDim2.new(1, 0, 0, 56)
	facts.BackgroundTransparency = 1
	facts.LayoutOrder = 5
	facts.Parent = column
	local factFlow = Instance.new("UIListLayout")
	factFlow.FillDirection = Enum.FillDirection.Horizontal
	factFlow.SortOrder = Enum.SortOrder.LayoutOrder
	factFlow.Padding = UDim.new(0, 12)
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
			size = UDim2.new(1, 0, 0, 56),
			parent = column,
			radius = 16,
			drop = 5,
			outline = 4,
			top = Color3.fromRGB(255, 217, 104),
			bottom = Color3.fromRGB(245, 168, 28),
			shadow = Color3.fromRGB(169, 110, 8),
		})
		;(opened.Parent :: Frame).LayoutOrder = 6
		;(opened.Parent :: Frame).Size = UDim2.new(1, 0, 0, 56)
		Theme.text({
			name = "Text",
			text = `{string.upper(nextWorld)} IS OPEN — PICK IT FROM A PAD`,
			size = UDim2.fromScale(1, 1),
			position = UDim2.fromScale(0, 0),
			parent = opened,
			align = Enum.TextXAlignment.Center,
			color = Color3.fromRGB(24, 18, 10),
			textSize = 22,
		})
	end

	local back = Theme.chunkButton({
		name = "Back",
		variant = "primary",
		text = "BACK TO THE LOBBY",
		textSize = 24,
		size = UDim2.new(1, 0, 0, 62),
		parent = column,
		radius = 16,
		outline = 4,
	})
	;(back.Parent :: Frame).LayoutOrder = 7
	;(back.Parent :: Frame).Size = UDim2.new(1, 0, 0, 62)
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
	holder.Size = UDim2.fromOffset(960, 900)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	Theme.fitToViewport(holder, 1000, 940)

	column = Instance.new("Frame")
	column.Name = "Column"
	column.Size = UDim2.fromScale(1, 1)
	column.BackgroundTransparency = 1
	column.Parent = holder

	local flow = Instance.new("UIListLayout")
	flow.SortOrder = Enum.SortOrder.LayoutOrder
	flow.Padding = UDim.new(0, 20)
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

function RoundEnd.start()
	build()

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
