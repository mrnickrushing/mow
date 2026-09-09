--!strict
--[[
	Journal — the menu, as a physical book.

	A dark floating panel reads as a settings dialogue. An open book with paper
	tab bookmarks, parchment pages and hand-drawn cards reads as part of the
	world, and that difference is most of what makes this genre feel warm rather
	than administrative.

	Five tabs down the left spine: what to do, what to buy for yourself, what to
	buy for your tools, what you have found, and how any of it works.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Types = require(Shared.Types)
local ToolUpgrades = require(Shared.Config.ToolUpgrades)
local Monetization = require(Shared.Config.Monetization)
local Prices = require(Shared.Prices)
local Upgrades = require(Shared.Config.Upgrades)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Theme = require(script.Parent.Theme)
local Palette = require(Shared.Config.Palette)
local Props = require(Shared.Config.Props)

local Journal = {}

local player = Players.LocalPlayer
local purchaseRemote: RemoteEvent
local promptRemote: RemoteEvent
local questRemote: RemoteEvent

local gui: ScreenGui
local upgradeBadge: Frame? = nil
local leftPage: Frame
local rightPage: Frame
local moneyLabel: TextLabel
local tabButtons: { [string]: TextButton } = {}
local bookTitle: TextLabel
local tabBlurb: TextLabel
local railCash: TextLabel
local railTips: TextLabel
local purseHeading: TextLabel
local activeTab = "objectives"
local isOpen = false
local questState: { any } = {}

--[[
	The book is gone.

	It was a cream book with a blue cover, paper pages and a spine shadow
	down the middle, with the tab strip hanging a hundred and sixty-four
	pixels off its left edge. That reads as a different game from the HUD in
	front of it — and the overhang is why it needed a scale hack to survive a
	narrow screen at all. It is a panel in the same chrome as everything else
	now, and the parchment survives only as the face of the cards on it,
	which is where a warm surface actually helps: dark type on cream is the
	one combination in this palette that reads at fifteen points.
]]
local PAPER = Color3.fromRGB(255, 252, 241)
local PAPER_EDGE = Color3.fromRGB(237, 225, 200)
local INK = Theme.colors.ink
--[[
	Greys dark enough to read.

	Every one of these was a pale grey, chosen to look inactive, and measured
	against what it actually sits on none of them cleared three to one: the
	"(0/5)" counters and locked "?" prices at 2.4 on the paper, and white
	lettering on the can't-afford and MAX buttons at 1.7 — a "Buy — $10"
	that could not be read on the button it was printed on. Inactive still
	has to be legible, so each is the same hue two shades darker, which puts
	the counters at 4.2 and the button lettering above 4.
]]
local LOCKED = Color3.fromRGB(118, 112, 104)
--- A brighter, opaque card on the parchment page it sits on.
local CARD = Color3.fromRGB(255, 252, 241)

--[[
	The looks a price wears, and the one rule behind them.

	Colour means one thing everywhere in this game: green is run cash, gold is
	tips, blue is Robux for this run and purple is Robux forever. So a price
	you can pay in cash is green, a price you can pay in tips is gold, one you
	cannot pay is flat, and a thing there is nothing left to buy on is flat
	with MAXED written on it — a dead button should not look pressable.

	These are the slab buttons the rest of the game uses, and a slab is four
	things — a face, a gradient, a drop and its ink. The pages repaint them
	inside a `live` poll rather than rebuilding the row, so the colour has to
	be swappable in place; `wear` is what swaps it.
]]
local LOOK_AFFORD = {
	top = Color3.fromRGB(143, 224, 124),
	bottom = Color3.fromRGB(79, 184, 60),
	shadow = Color3.fromRGB(46, 122, 36),
	ink = Color3.fromRGB(18, 58, 12),
}
local LOOK_TIPS = {
	top = Color3.fromRGB(255, 217, 104),
	bottom = Color3.fromRGB(245, 168, 28),
	shadow = Color3.fromRGB(169, 110, 8),
	ink = Color3.fromRGB(24, 18, 10),
}
local LOOK_BROKE = {
	top = Color3.fromRGB(179, 166, 142),
	bottom = Color3.fromRGB(179, 166, 142),
	shadow = Color3.fromRGB(150, 138, 116),
	ink = Color3.fromRGB(74, 64, 52),
}
local LOOK_DONE = LOOK_BROKE

local function wear(button: TextButton, look: { top: Color3, bottom: Color3, shadow: Color3, ink: Color3 })
	button.BackgroundColor3 = look.top
	button.TextColor3 = look.ink
	local grade = button:FindFirstChildOfClass("UIGradient")
	if grade then
		grade.Color = ColorSequence.new(look.top, look.bottom)
	end
	local holder = button.Parent
	local drop = if holder then holder:FindFirstChild("Drop") else nil
	if drop and drop:IsA("Frame") then
		drop.BackgroundColor3 = look.shadow
	end
end

--[[
	The tabs, in the order a player needs them.

	"Upgrades" used to mean the per-tool trees and nothing else, which left the
	bag — the first and most important thing anybody buys — with no tab at all.
	The word now sits on the page that actually sells the bag, and the tool
	trees are "Tools", which is what they were always about.
]]
local TABS = {
	--- "Objectives", not "Journal": a tab inside the journal called Journal
	--- named the book rather than the page, and the page it opened was headed
	--- Objectives anyway.
	{ id = "objectives", label = "Objectives", icon = "Scroll", color = Color3.fromRGB(226, 198, 150) },
	{ id = "stats", label = "Upgrades", icon = "Sack", color = Color3.fromRGB(178, 214, 168) },
	{ id = "upgrades", label = "Tools", icon = "Toolbox", color = Color3.fromRGB(190, 210, 226) },
	{ id = "collection", label = "Collection", icon = "LeafMaple", color = Color3.fromRGB(232, 196, 156) },
	--[[
		"Help", not "Tips".

		Tips are a currency — the number in the corner of the screen — and
		this tab was hints and key bindings under the same word. One of the
		two had to give, and the currency cannot: it is printed on every
		price in the Tools page.
	]]
	{ id = "tips", label = "Help", icon = "QuestionSign", color = Color3.fromRGB(200, 200, 216) },
}

--------------------------------------------------------------------
-- Page furniture
--------------------------------------------------------------------

local function clear(page: Frame)
	for _, child in page:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("ScrollingFrame") then
			child:Destroy()
		end
	end
end

--[[
	The numbers on the open spread that move on their own.

	The server pushes state five times a second, and the book used to redraw
	itself from scratch on every one of those pushes — every card, every avatar,
	every button destroyed and rebuilt two hundred milliseconds apart. That is
	what made the journal blink, and it is why buying was so hard: a button only
	counts a click if it receives both the press and the release, and the one
	under the cursor rarely survived long enough for both.

	So a page is built once, and anything on it that tracks cash or progress
	registers here instead. `render` reruns these in place; it only tears the
	spread down when what is actually *on* it has changed.
]]
local liveBits: { () -> () } = {}

local function live(update: () -> ())
	table.insert(liveBits, update)
	update()
end

--- A page heading in the book's ink colour.
local function heading(page: Frame, text: string)
	local label = Instance.new("TextLabel")
	label.Name = "Heading"
	label.Text = text:upper()
	label.Size = UDim2.new(1, -8, 0, 24)
	label.Position = UDim2.fromOffset(4, 0)
	label.BackgroundTransparency = 1
	label.Font = Theme.font
	--- On the panel now rather than on paper, so it takes the small-label
	--- colour the rest of the dark chrome uses.
	label.TextColor3 = Theme.colors.label
	label.TextSize = 15
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = page
end

--[[
	A row's own card, so it reads as a thing rather than as text floating on
	the page.

	Objectives and the zone list used to be `BackgroundTransparency = 1` —
	nothing behind the words at all, on a page whose whole point is warm
	parchment rather than a settings list. The card is brighter than the page
	it sits on rather than a translucent tint of it, because a tint of PAPER
	over PAPER is the page: the two are close enough in both hue and value
	that the "card" was there in the tree and invisible on the screen.
]]
local function card(parent: Instance, height: number): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -12, 0, height)
	row.BackgroundColor3 = CARD
	row.BorderSizePixel = 0
	row.Parent = parent
	Theme.corner(row, 16)
	--- The same four-pixel ink border every card face in the game wears; the
	--- pale hairline this had was invisible the moment the page went dark.
	Theme.stroke(row, 4, Theme.colors.outline, 0)
	local grade = Instance.new("UIGradient")
	grade.Color = ColorSequence.new(PAPER, PAPER_EDGE)
	grade.Rotation = 90
	grade.Parent = row
	return row
end

--- A scrolling body area under the heading.
local function body(page: Frame): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Body"
	scroll.Size = UDim2.new(1, -8, 1, -30)
	scroll.Position = UDim2.fromOffset(0, 28)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	--[[
		A bar you can actually see, on paper.

		At four pixels in the paper's own edge colour the bar was invisible
		against the page, so a column taller than the window — the Help page's
		hints are five hundred pixels in a four hundred pixel frame — simply
		looked like a sentence that had been cut off mid-word. The page was
		scrolling the whole time and nothing said so. Ink at a distance is a
		mark on the edge of the paper, which is what a scrollbar is.
	]]
	scroll.ScrollBarThickness = 7
	scroll.ScrollBarImageColor3 = Theme.colors.outline
	scroll.ScrollBarImageTransparency = 0.15
	-- And a gutter of its own, so the bar does not lie across the last word
	-- of every line it passes.
	scroll.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = page

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 12)
	layout.Parent = scroll
	return scroll
end

--------------------------------------------------------------------
-- Objectives
--------------------------------------------------------------------

local function renderObjectives()
	heading(leftPage, "Objectives")
	local scroll = body(leftPage)

	for order, entry in questState do
		local row = card(scroll, 66)
		row.Name = entry.id
		row.LayoutOrder = order

		--[[
			A drawn checkbox rather than a tick character, so an unfinished
			objective still reads as something waiting to be done.

			It was filled with `PAPER` while unchecked, which was the page's
			own colour sitting on a card that is now a different colour again
			— an empty box no longer merely blended into the parchment, it sat
			there as a small parchment-coloured island on a white one. White
			reads as "not yet" against a filled green the same way an unchecked
			real-world checkbox does.
		]]
		local box = Instance.new("Frame")
		box.Size = UDim2.fromOffset(28, 28)
		box.Position = UDim2.fromOffset(14, 19)
		box.BackgroundColor3 = if entry.done then Color3.fromRGB(126, 186, 108) else Color3.fromRGB(255, 255, 255)
		box.BorderSizePixel = 0
		box.Parent = row
		Theme.corner(box, 8)
		Theme.stroke(box, 3, Theme.colors.outline, 0)

		if entry.done then
			Theme.icon({
				name = "Tick",
				prop = "Tick",
				size = UDim2.fromScale(0.9, 0.9),
				position = UDim2.fromScale(0.5, 0.5),
				anchor = Vector2.new(0.5, 0.5),
				parent = box,
			})
		end

		local title = Instance.new("TextLabel")
		title.Text = entry.text
		title.Size = UDim2.new(1, -158, 0, 24)
		title.Position = UDim2.fromOffset(52, 12)
		title.BackgroundTransparency = 1
		title.Font = Theme.font
		title.TextColor3 = if entry.done then Theme.colors.inkSoft else INK
		title.TextSize = 19
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.Parent = row

		--[[
			What it pays, on the row that asks for it.

			The page's own blurb says to tick these off "for tips and cash",
			and not one row said how much of either — so the whole list read
			as chores. Fifty cents is not much; being told it is fifty cents
			before you go and do it is the difference between a job and a
			request.
		]]
		local reward = Instance.new("TextLabel")
		reward.Name = "Reward"
		reward.Text = if type(entry.reward) == "number" and entry.reward > 0
			then `Pays {Format.cash(entry.reward)}`
			else ""
		reward.Size = UDim2.new(1, -158, 0, 20)
		reward.Position = UDim2.fromOffset(52, 36)
		reward.BackgroundTransparency = 1
		reward.Font = Theme.fontRegular
		reward.TextColor3 = Theme.colors.inkSoft
		reward.TextSize = 15
		reward.TextXAlignment = Enum.TextXAlignment.Left
		reward.Parent = row

		local progress = Instance.new("TextLabel")
		-- Read back out of `questState` by position rather than closing over
		-- `entry`: a quest push replaces the whole table, so the row this was
		-- built from is a stale copy the moment the next snapshot lands.
		local slot = order
		live(function()
			local current = questState[slot]
			if current then
				progress.Text = `{Format.tally(current.progress)} / {Format.tally(current.target)}`
			end
		end)
		--- Right-aligned, where a list is scanned for its numbers.
		progress.Size = UDim2.fromOffset(96, 24)
		progress.Position = UDim2.new(1, -16, 0.5, 0)
		progress.AnchorPoint = Vector2.new(1, 0.5)
		progress.BackgroundTransparency = 1
		progress.Font = Theme.font
		progress.TextColor3 = Theme.colors.inkSoft
		progress.TextSize = 18
		progress.TextXAlignment = Enum.TextXAlignment.Right
		progress.Parent = row
	end
end

--- The right-hand page of the objectives spread: who else is on the world.
local function renderPlayers()
	heading(rightPage, "Players")
	local scroll = body(rightPage)

	local others = Players:GetPlayers()
	for order = 1, GameConfig.MAX_PARTY do
		local subject = others[order]

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -12, 0, 62)
		row.BackgroundTransparency = 1
		row.LayoutOrder = order
		row.Parent = scroll

		local avatar = Instance.new("Frame")
		avatar.Size = UDim2.fromOffset(48, 48)
		avatar.Position = UDim2.fromOffset(4, 6)
		avatar.BackgroundColor3 = if subject then PAPER else Color3.fromRGB(224, 218, 206)
		avatar.BorderSizePixel = 0
		avatar.Parent = row
		Theme.corner(avatar, 24)

		if subject then
			local image = Instance.new("ImageLabel")
			image.Size = UDim2.fromScale(1, 1)
			image.BackgroundTransparency = 1
			image.Image = `rbxthumb://type=AvatarHeadShot&id={subject.UserId}&w=60&h=60`
			image.Parent = avatar
			Theme.corner(image, 24)
		else
			local mark = Instance.new("TextLabel")
			mark.Text = "?"
			mark.Size = UDim2.fromScale(1, 1)
			mark.BackgroundTransparency = 1
			mark.Font = Theme.font
			mark.TextColor3 = LOCKED
			mark.TextSize = 26
			mark.Parent = avatar
		end

		--[[
			An empty seat says it is empty.

			The party has four places and this draws all four, which is worth
			doing — it is how a player learns there is room for friends. But
			an unfilled one read `Player 2`, with a question mark for a face
			and dashes for its numbers, which is not an empty seat: it is a
			player called Player 2 whose score has not loaded. Three of those
			under your own name make a working solo game look broken.
		]]
		local name = Instance.new("TextLabel")
		name.Text = if subject then subject.DisplayName else "Waiting for a player"
		name.Size = UDim2.new(1, -64, 0, 26)
		name.Position = UDim2.fromOffset(60, 6)
		name.BackgroundTransparency = 1
		name.Font = Theme.font
		name.TextColor3 = if subject then Color3.fromRGB(64, 134, 208) else LOCKED
		name.TextSize = 20
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Parent = row

		local stats = Instance.new("TextLabel")
		local isSelf = subject == player
		-- The coin and the leaf are models sat beside the numbers, so the row
		-- reads the same on every device. See `Theme.icon`.
		if isSelf then
			live(function()
				local mine = PlayerState.get()
				stats.Text = `    {Format.cash(mine.cash)}       {Format.count(mine.bagWeight)}`
			end)
		else
			stats.Text = "    —       —"
		end
		stats.Size = UDim2.new(1, -64, 0, 24)
		stats.Position = UDim2.fromOffset(60, 30)
		Theme.icon({
			name = "CoinMark",
			prop = "Coin",
			size = UDim2.fromOffset(18, 18),
			position = UDim2.fromOffset(60, 33),
			parent = row,
		})
		Theme.icon({
			name = "BagMark",
			prop = "LeafMaple",
			size = UDim2.fromOffset(18, 18),
			position = UDim2.fromOffset(148, 33),
			parent = row,
		})
		stats.BackgroundTransparency = 1
		stats.Font = Theme.fontRegular
		stats.TextColor3 = LOCKED
		stats.TextSize = 17
		stats.TextXAlignment = Enum.TextXAlignment.Left
		stats.Parent = row
	end
end

--[[
	A level as a row of slabs rather than as a fraction.

	The rows said "Lv 3" and nothing else, and a player comparing seven lines
	reads seven fractions one at a time. Filled slabs are countable at a
	glance and they show the whole ladder — how far along you are *and* how
	much of it is left, which the number on its own never said.

	Fifteen rungs get thinner slabs rather than a row that runs under the
	price button. Built once and repainted, because the page polls.
]]
--- How much width a ladder has on the upgrades page, where the rows are wide.
local PIP_ROOM = 210

local function levelPips(
	parent: Instance,
	maxLevel: number,
	x: number,
	y: number,
	--- Narrower on the tool pane, which is a 284-wide column rather than a
	--- page. Slabs sized against the wrong room run under the price button.
	room: number?
): { Frame }
	local space = room or PIP_ROOM
	local gap = if maxLevel > 10 then 3 else 4
	local width = math.min(15, (space - gap * (maxLevel - 1)) / maxLevel)
	local pips: { Frame } = {}
	for step = 1, maxLevel do
		local pip = Instance.new("Frame")
		pip.Name = `Pip{step}`
		pip.Size = UDim2.fromOffset(width, 22)
		pip.Position = UDim2.fromOffset(x + (step - 1) * (width + gap), y)
		pip.BackgroundColor3 = Color3.fromRGB(207, 192, 166)
		pip.BorderSizePixel = 0
		pip.Parent = parent
		Theme.corner(pip, 4)
		Theme.stroke(pip, 2.5, Theme.colors.outline, 0)

		local grade = Instance.new("UIGradient")
		grade.Color = ColorSequence.new(Color3.fromRGB(143, 224, 124), Color3.fromRGB(79, 184, 60))
		grade.Rotation = 90
		grade.Enabled = false
		grade.Parent = pip

		table.insert(pips, pip)
	end
	return pips
end

local function paintPips(pips: { Frame }, level: number)
	for step, pip in pips do
		local earned = step <= level
		pip.BackgroundColor3 = if earned then Color3.fromRGB(143, 224, 124) else Color3.fromRGB(207, 192, 166)
		local grade = pip:FindFirstChildOfClass("UIGradient")
		if grade then
			grade.Enabled = earned
		end
	end
end

--------------------------------------------------------------------
-- Tools: the shed, as a shelf you pick from
--------------------------------------------------------------------

--[[
	Which tool is being read about.

	The page used to be a column of sixteen tall panels, each carrying its own
	three upgrade cards and its own buy buttons — about two hundred and forty
	studs of scroll to compare two tools, and no way to see more than one and
	a half of them at a time. It is a shelf now: every tool as a card in a
	grid on the left, and one pane on the right that says everything about
	whichever one you tapped.
]]
local selectedTool: string? = nil

--- A small dark pill with a number on it, for a stat that fits in two words.
local function statPill(parent: Instance, order: number, text: string, colour: Color3): Frame
	local pill = Theme.chip({
		name = "Stat",
		size = UDim2.fromOffset(0, 20),
		parent = parent,
		radius = Theme.PILL,
		autoSize = Enum.AutomaticSize.X,
	})
	pill.LayoutOrder = order

	local label = Theme.text({
		name = "Text",
		text = text,
		size = UDim2.fromOffset(0, 20),
		position = UDim2.fromScale(0, 0),
		parent = pill,
		align = Enum.TextXAlignment.Center,
		color = colour,
		textSize = 13,
	})
	label.AutomaticSize = Enum.AutomaticSize.X
	Theme.pad(pill, 0, 9, 0, 9)
	return pill
end

--[[
	One tool on the shelf: a picture, a name, what it cuts, and what it costs.

	The footer is the tool's whole status in one line — OWNED, or the price in
	the colour that says whether you can pay it — because a grid is read by
	scanning down one column, not by reading each card.
]]
local function toolCard(parent: Instance, order: number, tool: Types.ToolDef, state: PlayerState.State)
	local owned = state.ownedTools[tool.id] == true
	local picked = selectedTool == tool.id

	local face = Theme.cardFace({
		name = tool.id,
		size = UDim2.fromScale(1, 1),
		parent = parent,
		radius = 16,
		drop = 5,
		outline = 4,
	})
	local seat = face.Parent :: Frame
	seat.LayoutOrder = order
	if picked then
		local ring = face:FindFirstChildOfClass("UIStroke")
		if ring then
			ring.Color = Theme.colors.tips
		end
	end
	Theme.pad(face, 10, 10, 10, 10)

	local well = Instance.new("Frame")
	well.Name = "Well"
	well.Size = UDim2.new(1, 0, 0, 68)
	well.BackgroundColor3 = Color3.fromRGB(44, 33, 24)
	well.BorderSizePixel = 0
	well.Parent = face
	Theme.corner(well, 11)
	Theme.stroke(well, 3, Theme.colors.outline, 0)

	Theme.icon({
		name = "Icon",
		prop = Props.forTool(tool.id, tool.category),
		size = UDim2.fromScale(0.84, 0.84),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = well,
	})

	local name = Theme.text({
		name = "Name",
		text = tool.name,
		size = UDim2.new(1, 0, 0, 20),
		position = UDim2.fromOffset(0, 74),
		parent = face,
		align = Enum.TextXAlignment.Left,
		color = INK,
		textSize = 16,
	})
	name.TextTruncate = Enum.TextTruncate.AtEnd

	local stats = Instance.new("Frame")
	stats.Name = "Stats"
	stats.Size = UDim2.new(1, 0, 0, 20)
	stats.Position = UDim2.fromOffset(0, 96)
	stats.BackgroundTransparency = 1
	stats.Parent = face
	local statFlow = Instance.new("UIListLayout")
	statFlow.FillDirection = Enum.FillDirection.Horizontal
	statFlow.SortOrder = Enum.SortOrder.LayoutOrder
	statFlow.Padding = UDim.new(0, 5)
	statFlow.Parent = stats

	--- Deck first and in gold: the width of the swath is the headline number
	--- of every tool in this game.
	statPill(stats, 1, `{tool.deck} wide`, Theme.colors.tips)
	statPill(stats, 2, `×{tool.power}`, Palette.color(Palette.grass.blade))

	--- The footer says the one thing a scan is looking for.
	local footer
	if owned then
		footer = Theme.chunkButton({
			name = "Footer",
			variant = "disabled",
			text = "OWNED",
			textSize = 15,
			size = UDim2.new(1, 0, 0, 34),
			position = UDim2.fromScale(0, 1),
			anchor = Vector2.new(0, 1),
			parent = face,
			radius = 11,
			outline = 3,
		})
	else
		footer = Theme.chunkButton({
			name = "Footer",
			variant = "primary",
			text = if tool.cost > 0 then Format.cash(tool.cost) else "FREE",
			textSize = 16,
			size = UDim2.new(1, 0, 0, 34),
			position = UDim2.fromScale(0, 1),
			anchor = Vector2.new(0, 1),
			parent = face,
			radius = 11,
			outline = 3,
		})
		live(function()
			wear(footer, if PlayerState.get().cash >= tool.cost then LOOK_AFFORD else LOOK_BROKE)
		end)
	end
	footer.Active = false

	--[[
		The whole card is the button.

		A footer that reads as a price and a card that has to be tapped
		somewhere else is two targets for one intention, and on a tablet the
		one you hit is whichever your thumb landed on.
	]]
	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.Size = UDim2.fromScale(1, 1)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.Modal = true
	hit.ZIndex = face.ZIndex + 2
	hit.Parent = face
	hit.Activated:Connect(function()
		selectedTool = tool.id
		Journal.refresh()
	end)
end

--- A label and a value on a dark row, for the detail pane's numbers.
local function statRow(parent: Instance, order: number, label: string, value: string, colour: Color3)
	local row = Theme.chip({
		name = label,
		size = UDim2.new(1, 0, 0, 34),
		parent = parent,
		radius = 10,
	})
	row.LayoutOrder = order
	Theme.pad(row, 0, 11, 0, 11)

	Theme.text({
		name = "Label",
		text = label,
		size = UDim2.fromScale(0.55, 1),
		position = UDim2.fromScale(0, 0),
		parent = row,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.label,
		textSize = 14,
	})
	Theme.text({
		name = "Value",
		text = value,
		size = UDim2.fromScale(0.45, 1),
		position = UDim2.fromScale(1, 0),
		anchor = Vector2.new(1, 0),
		parent = row,
		align = Enum.TextXAlignment.Right,
		color = colour,
		textSize = 16,
	})
end

--- One of the tool's three upgrade slots, as a row you can buy from directly.
local function slotRow(parent: Instance, order: number, slot: any, level: number)
	local row = card(parent, 78)
	row.Name = slot.key
	row.LayoutOrder = order

	local well = Instance.new("Frame")
	well.Name = "Well"
	well.Size = UDim2.fromOffset(44, 44)
	well.Position = UDim2.fromOffset(12, 17)
	well.BackgroundColor3 = Color3.fromRGB(252, 250, 246)
	well.BorderSizePixel = 0
	well.Parent = row
	Theme.corner(well, 10)
	Theme.stroke(well, 2.5, Theme.colors.outline, 0)

	if slot.icon then
		local picture = Instance.new("ImageLabel")
		picture.Name = "Icon"
		picture.Size = UDim2.fromScale(0.82, 0.82)
		picture.Position = UDim2.fromScale(0.5, 0.5)
		picture.AnchorPoint = Vector2.new(0.5, 0.5)
		picture.BackgroundTransparency = 1
		picture.Image = slot.icon
		picture.ScaleType = Enum.ScaleType.Fit
		picture.Parent = well
	end

	local slotName = Theme.text({
		name = "Name",
		text = slot.name,
		size = UDim2.new(1, -190, 0, 20),
		position = UDim2.fromOffset(66, 12),
		parent = row,
		align = Enum.TextXAlignment.Left,
		color = INK,
		textSize = 17,
	})
	slotName.TextTruncate = Enum.TextTruncate.AtEnd

	local pips = levelPips(row, slot.maxLevel, 66, 38, 148)
	paintPips(pips, level)

	local cost = ToolUpgrades.costAt(slot, level)
	local buy = Theme.chunkButton({
		name = "Buy",
		variant = "primary",
		text = if cost then Format.cash(cost) else "MAXED",
		textSize = 16,
		size = UDim2.fromOffset(96, 40),
		position = UDim2.new(1, -12, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		parent = row,
		radius = 12,
		outline = 3,
	})
	if cost then
		live(function()
			wear(buy, if PlayerState.get().cash >= cost then LOOK_AFFORD else LOOK_BROKE)
		end)
		buy.Activated:Connect(function()
			purchaseRemote:FireServer("toolUpgrade", slot.key)
		end)
	else
		wear(buy, LOOK_DONE)
	end
end

--[[
	Which tool the pane opens on.

	The equipped one, because that is the one the player is holding and the
	one whose upgrades they are most likely to be here for.
]]
local function defaultTool(state: PlayerState.State): Types.ToolDef
	local equipped = if state.equippedTool ~= "" then Tools.get(state.equippedTool) else nil
	return equipped or Tools.list[1]
end

local function renderUpgrades()
	local state = PlayerState.get()

	--------------------------------------------------------------
	-- Left: the shelf
	--------------------------------------------------------------
	local shelf = body(leftPage)
	--- `body` lays its children out in a column; a shelf is a grid, and two
	--- layouts in one frame means neither of them is the one you asked for —
	--- the first attempt drew a single card the size of the page.
	local column = shelf:FindFirstChildOfClass("UIListLayout")
	if column then
		column:Destroy()
	end
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(1 / 3, -10, 0, 190)
	grid.CellPadding = UDim2.fromOffset(14, 14)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = shelf

	for order, tool in Tools.list do
		toolCard(shelf, order, tool, state)
	end

	--------------------------------------------------------------
	-- Right: everything about the one you tapped
	--------------------------------------------------------------
	local chosen = if selectedTool then Tools.get(selectedTool) else nil
	local tool = chosen or defaultTool(state)
	selectedTool = tool.id

	local right = body(rightPage)
	local owned = state.ownedTools[tool.id] == true
	local kept = state.permanentTools[tool.id] == true

	local pane = Instance.new("Frame")
	pane.Name = "Detail"
	pane.Size = UDim2.new(1, -12, 0, 388)
	pane.BackgroundColor3 = Color3.fromRGB(30, 22, 16)
	pane.BorderSizePixel = 0
	pane.LayoutOrder = 1
	pane.Parent = right
	Theme.corner(pane, 18)
	Theme.stroke(pane, 4, Theme.colors.outline, 0)
	Theme.pad(pane, 16, 16, 16, 16)

	local well = Instance.new("Frame")
	well.Name = "Well"
	well.Size = UDim2.new(1, 0, 0, 140)
	well.BackgroundColor3 = Color3.fromRGB(44, 33, 24)
	well.BorderSizePixel = 0
	well.Parent = pane
	Theme.corner(well, 14)
	Theme.stroke(well, 3, Theme.colors.outline, 0)

	Theme.icon({
		name = "Icon",
		prop = Props.forTool(tool.id, tool.category),
		size = UDim2.fromScale(0.8, 0.8),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = well,
	})

	Theme.text({
		name = "Name",
		text = tool.name,
		size = UDim2.new(1, 0, 0, 30),
		position = UDim2.fromOffset(0, 148),
		parent = pane,
		align = Enum.TextXAlignment.Left,
		textSize = 24,
	})

	local blurb = Theme.text({
		name = "Blurb",
		text = tool.description,
		size = UDim2.new(1, 0, 0, 52),
		position = UDim2.fromOffset(0, 180),
		parent = pane,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.body,
		textSize = 15,
		bold = false,
	})
	blurb.TextWrapped = true
	blurb.TextYAlignment = Enum.TextYAlignment.Top

	local rows = Instance.new("Frame")
	rows.Name = "Stats"
	rows.Size = UDim2.new(1, 0, 0, 118)
	rows.Position = UDim2.fromOffset(0, 238)
	rows.BackgroundTransparency = 1
	rows.Parent = pane
	local rowFlow = Instance.new("UIListLayout")
	rowFlow.SortOrder = Enum.SortOrder.LayoutOrder
	rowFlow.Padding = UDim.new(0, 8)
	rowFlow.Parent = rows

	statRow(rows, 1, "DECK", `{tool.deck} tiles wide`, Theme.colors.tips)
	statRow(rows, 2, "CUT POWER", `×{tool.power}`, Palette.color(Palette.grass.blade))
	statRow(
		rows,
		3,
		"FUEL",
		if tool.fuelBurn > 0 then `{Format.stat(tool.fuelBurn)} L/s` else "none",
		if tool.fuelBurn > 0 then Theme.colors.warn else Theme.colors.label
	)

	--------------------------------------------------------------
	-- The three ways to have it
	--------------------------------------------------------------
	local order = 2
	if not owned and tool.cost > 0 then
		local buy = Theme.chunkButton({
			name = "Buy",
			variant = "primary",
			text = `BUY — {Format.cash(tool.cost)}`,
			textSize = 20,
			size = UDim2.new(1, -12, 0, 52),
			parent = right,
			radius = 14,
			outline = 4,
		})
		;(buy.Parent :: Frame).LayoutOrder = order
		order += 1
		live(function()
			wear(buy, if PlayerState.get().cash >= tool.cost then LOOK_AFFORD else LOOK_BROKE)
		end)
		buy.Activated:Connect(function()
			purchaseRemote:FireServer("tool", tool.id)
		end)
	end

	--[[
		Robux, in the two colours that mean what they mean everywhere else in
		the game: blue is this run, purple is forever. Drawn dead rather than
		hidden when the product has no real id yet, so the pane does not
		change shape the day the ids arrive.
	]]
	local runKey, foreverKey = Monetization.toolProductKeys(tool.id)
	local runProduct = Monetization.productByKey[runKey]
	local foreverProduct = Monetization.productByKey[foreverKey]
	if runProduct or foreverProduct then
		local pair = Instance.new("Frame")
		pair.Name = "Robux"
		pair.Size = UDim2.new(1, -12, 0, 46)
		pair.BackgroundTransparency = 1
		pair.LayoutOrder = order
		pair.Parent = right
		order += 1

		local function robux(product, variant: string, tail: string, x: number, dead: boolean)
			local price = Prices.robux(product.id, product.robux)
			local button = Theme.chunkButton({
				name = variant,
				variant = if dead then "disabled" else variant :: any,
				text = `R$ {price} · {tail}`,
				textSize = 15,
				--- Half the row each, with ten pixels of daylight between them:
				--- the left one starts at the left edge, the right one ends at
				--- the right, and each gives up five to the gap.
				size = UDim2.new(0.5, -5, 1, 0),
				position = UDim2.fromScale(x, 0),
				anchor = Vector2.new(x, 0),
				parent = pair,
				radius = 12,
				outline = 3,
			})
			if not dead then
				button.Activated:Connect(function()
					promptRemote:FireServer("product", product.key)
				end)
			end
		end

		if runProduct then
			robux(runProduct, "robuxRun", "RUN", 0, owned or not Monetization.isConfigured(runProduct.id))
		end
		if foreverProduct then
			robux(
				foreverProduct,
				"robuxKeep",
				"KEEP",
				1,
				kept or not Monetization.isConfigured(foreverProduct.id)
			)
		end
	end

	local tipsPrice = tool.tipsPermanent
	if tipsPrice and not kept then
		local keep = Theme.chunkButton({
			name = "Keep",
			variant = "gold",
			text = `KEEP IT FOR GOOD — {Format.count(tipsPrice)} TIPS`,
			textSize = 15,
			size = UDim2.new(1, -12, 0, 44),
			parent = right,
			radius = 12,
			outline = 3,
		})
		;(keep.Parent :: Frame).LayoutOrder = order
		order += 1
		live(function()
			wear(keep, if PlayerState.get().tips >= tipsPrice then LOOK_TIPS else LOOK_BROKE)
		end)
		keep.Activated:Connect(function()
			purchaseRemote:FireServer("permanent", tool.id)
		end)
	end

	--------------------------------------------------------------
	-- And its own three lines
	--------------------------------------------------------------
	local title = Instance.new("TextLabel")
	title.Name = "UpgradesHeading"
	title.Text = if owned then "ITS THREE LINES" else "LOCKED UNTIL YOU OWN IT"
	title.Size = UDim2.new(1, -12, 0, 22)
	title.BackgroundTransparency = 1
	title.Font = Theme.font
	title.TextColor3 = Theme.colors.label
	title.TextSize = 15
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.LayoutOrder = order
	title.Parent = right
	order += 1

	if owned then
		for index, slot in ToolUpgrades.treeFor(tool.id) do
			slotRow(right, order + index, slot, state.upgrades[slot.key] or 0)
		end
	end
end

--------------------------------------------------------------------
-- Yourself: the bag, the legs, the rate and the reach
--------------------------------------------------------------------

--[[
	The player's own stat lines, sold from the book.

	These five — how much you carry, how fast you walk, what you charge, how
	long the tank lasts, how far the trailer reaches — used to be sold only at
	the boards standing in front of the shed. That meant the single most
	important purchase in the early game, the bag, was invisible to anyone who
	had not already walked up to the right board, while the tips page told them
	to buy it first and a toast announced they could now afford it. Three parts
	of the game pointing at a thing with no way to reach it.

	They are still on the boards. They are also here, because "where do I buy
	the bag" should never be a question the game leaves you holding.
]]
local function renderStats()
	heading(leftPage, "Upgrades")
	local scroll = body(leftPage)

	for order, def in Upgrades.list do
		--- The same card every other list in the book is made of. This row was
		--- a 45%-transparent tint of the page with a hairline round it, which
		--- was a card on parchment and is a smudge on dark wood.
		local row = card(scroll, 110)
		row.Name = def.id
		row.LayoutOrder = order

		--[[
			The same badge the board in the yard wears.

			The row used to be three lines of text, and so did the four rows
			under it — a page you had to read rather than scan. The icon is
			the one thing that tells a line apart at a glance, and it is the
			same picture in both places, so the board you walked past and the
			row you are reading are recognisably the same purchase.
		]]
		if def.icon then
			local badge = Instance.new("ImageLabel")
			badge.Name = "Icon"
			badge.Size = UDim2.fromOffset(56, 56)
			badge.Position = UDim2.fromOffset(12, 20)
			badge.BackgroundTransparency = 1
			badge.Image = def.icon
			badge.ScaleType = Enum.ScaleType.Fit
			badge.Parent = row
		end

		-- Text starts clear of the badge, and still stops clear of the button.
		local textX = if def.icon then 78 else 14
		local textInset = if def.icon then -246 else -182

		local name = Instance.new("TextLabel")
		name.Text = def.name:upper()
		name.Size = UDim2.new(1, textInset, 0, 24)
		name.Position = UDim2.fromOffset(textX, 6)
		name.BackgroundTransparency = 1
		name.Font = Theme.font
		name.TextColor3 = INK
		name.TextSize = 21
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Parent = row

		local blurb = Instance.new("TextLabel")
		blurb.Text = def.description
		blurb.Size = UDim2.new(1, textInset, 0, 34)
		blurb.Position = UDim2.fromOffset(textX, 30)
		blurb.BackgroundTransparency = 1
		blurb.Font = Theme.fontRegular
		blurb.TextColor3 = Color3.fromRGB(92, 84, 74)
		blurb.TextSize = 14
		blurb.TextXAlignment = Enum.TextXAlignment.Left
		blurb.TextYAlignment = Enum.TextYAlignment.Top
		blurb.TextWrapped = true
		blurb.Parent = row

		-- "25 --> 39 units" rather than "+1 level": the purchase has to be
		-- legible as the thing it does, not as an abstraction over it.
		local pips = levelPips(row, def.maxLevel, textX, 64)

		local change = Instance.new("TextLabel")
		change.Size = UDim2.new(1, textInset, 0, 20)
		change.Position = UDim2.fromOffset(textX, 88)
		change.BackgroundTransparency = 1
		change.Font = Theme.font
		change.TextColor3 = Color3.fromRGB(150, 106, 30)
		change.TextSize = 16
		change.TextXAlignment = Enum.TextXAlignment.Left
		change.Parent = row

		local buy = Theme.chunkButton({
			name = "Buy",
			variant = "primary",
			text = "",
			textSize = 18,
			size = UDim2.fromOffset(146, 46),
			position = UDim2.new(1, -14, 0.5, 0),
			anchor = Vector2.new(1, 0.5),
			parent = row,
			radius = 13,
			outline = 3,
		})

		live(function()
			local state = PlayerState.get()
			local level = state.upgrades[def.id] or 0
			local cost = Upgrades.costAt(def, level)

			paintPips(pips, level)

			if not cost then
				change.Text = `{Format.stat(Upgrades.valueAt(def, level))}{def.suffix} — the top of the line`
				buy.Text = "MAXED"
				wear(buy, LOOK_DONE)
				return
			end

			local now = Upgrades.valueAt(def, level)
			local next_ = Upgrades.valueAt(def, level + 1)
			--- The level is the row of slabs above this line now, so the line
			--- is free to say only what the money buys.
			change.Text = `{Format.stat(now)} --> {Format.stat(next_)}{def.suffix}`
			buy.Text = Format.cash(cost)
			wear(buy, if state.cash >= cost then LOOK_AFFORD else LOOK_BROKE)
		end)

		buy.Activated:Connect(function()
			purchaseRemote:FireServer("upgrade", def.id)
		end)
	end

	heading(rightPage, "You Right Now")
	local right = body(rightPage)

	local readouts: { { label: string, read: (PlayerState.State) -> string } } = {
		{ label = "Bag", read = function(mine)
			return `{Format.count(mine.bagWeight)} / {Format.count(mine.bagCapacity)} units`
		end },
		{ label = "Stride", read = function(mine)
			return `{Format.stat(mine.walkSpeed)} studs/s`
		end },
		{ label = "Fortune", read = function(mine)
			return `{string.format("%.2f", mine.cashMultiplier)}x cash`
		end },
		{ label = "Reserve", read = function(mine)
			return `{Format.stat(mine.fuel)} / {Format.stat(mine.fuelCapacity)} L`
		end },
		{ label = "Haul", read = function(mine)
			return if mine.hasPortableTrailer
				then `portable, {Format.stat(mine.dumpRadius)} studs`
				else "walk it to the trailer"
		end },
	}

	for order, readout in readouts do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -12, 0, 38)
		row.BackgroundTransparency = 1
		row.LayoutOrder = order
		row.Parent = right

		local label = Instance.new("TextLabel")
		label.Text = readout.label
		label.Size = UDim2.fromScale(0.4, 1)
		label.BackgroundTransparency = 1
		label.Font = Theme.font
		--- The right page is the dark panel itself, not paper: ink on it is
		--- the colour of the panel, which is how these five readouts came to
		--- be all but invisible.
		label.TextColor3 = Theme.colors.label
		label.TextSize = 19
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = row

		local value = Instance.new("TextLabel")
		value.Size = UDim2.new(0.6, -12, 1, 0)
		value.Position = UDim2.fromScale(1, 0)
		value.AnchorPoint = Vector2.new(1, 0)
		value.BackgroundTransparency = 1
		value.Font = Theme.fontRegular
		value.TextColor3 = Theme.colors.body
		value.TextSize = 18
		value.TextXAlignment = Enum.TextXAlignment.Right
		value.Parent = row

		live(function()
			value.Text = readout.read(PlayerState.get())
		end)
	end

	local note = Instance.new("TextLabel")
	note.Text = "These are also sold at the boards outside the shed."
	note.Size = UDim2.new(1, -12, 0, 48)
	note.BackgroundTransparency = 1
	note.Font = Theme.fontRegular
	note.TextColor3 = Theme.colors.label
	note.TextSize = 15
	note.TextXAlignment = Enum.TextXAlignment.Left
	note.TextYAlignment = Enum.TextYAlignment.Top
	note.TextWrapped = true
	note.LayoutOrder = #readouts + 1
	note.Parent = right
end

--------------------------------------------------------------------
-- Collection and tips
--------------------------------------------------------------------

--[[
	One zone's blade: found, or still out there.

	The card is the whole record — a medal if it has been found, a dark disc
	if it has not — because the collection page is read by scanning for the
	gaps rather than by reading the list.
]]
local function bladeCard(parent: Instance, order: number, section: Types.ZoneDef, mine: boolean)
	local face: Frame
	if mine then
		face = Theme.cardFace({
			name = section.id,
			size = UDim2.fromScale(1, 1),
			parent = parent,
			radius = 16,
			drop = 5,
			outline = 4,
		})
	else
		face = Theme.chunkPanel({
			name = section.id,
			size = UDim2.fromScale(1, 1),
			parent = parent,
			radius = 16,
			drop = 5,
			outline = 4,
			top = Color3.fromRGB(44, 33, 24),
			bottom = Color3.fromRGB(44, 33, 24),
		})
	end
	;(face.Parent :: Frame).LayoutOrder = order
	Theme.pad(face, 14, 10, 13, 10)

	local disc = Instance.new("Frame")
	disc.Name = "Medal"
	disc.Size = UDim2.fromOffset(56, 56)
	disc.Position = UDim2.fromScale(0.5, 0)
	disc.AnchorPoint = Vector2.new(0.5, 0)
	disc.BackgroundColor3 = if mine then Color3.fromRGB(255, 224, 138) else Color3.fromRGB(58, 44, 30)
	disc.BorderSizePixel = 0
	disc.Parent = face
	Theme.corner(disc, Theme.PILL)
	Theme.stroke(disc, 4, Theme.colors.outline, 0)
	if mine then
		local shine = Instance.new("UIGradient")
		shine.Color = ColorSequence.new(Color3.fromRGB(255, 224, 138), Color3.fromRGB(255, 176, 32))
		shine.Rotation = 90
		shine.Parent = disc
	end

	local mark = Instance.new("Frame")
	mark.Name = "Mark"
	mark.Size = UDim2.fromOffset(22, 22)
	mark.Position = UDim2.fromScale(0.5, 0.5)
	mark.AnchorPoint = Vector2.new(0.5, 0.5)
	mark.Rotation = 45
	mark.BackgroundColor3 = if mine then Theme.colors.outline else Color3.fromRGB(74, 56, 38)
	mark.BorderSizePixel = 0
	mark.Parent = disc
	Theme.corner(mark, 3)

	local name = Theme.text({
		name = "Name",
		text = section.name,
		size = UDim2.new(1, 0, 0, 22),
		position = UDim2.fromOffset(0, 64),
		parent = face,
		align = Enum.TextXAlignment.Center,
		color = if mine then INK else Theme.colors.body,
		textSize = 17,
	})
	name.TextTruncate = Enum.TextTruncate.AtEnd

	--[[
		Where it was, or what stands between you and it.

		A side area has to be found before it can be searched, and the page
		should say so rather than leaving a dark disc with no explanation.
	]]
	local note = if mine
		then "found"
		elseif not PlayerState.isSectionOpen(section.id) then "behind a gate"
		elseif section.optional then "off the path"
		else "still out there"
	Theme.text({
		name = "Note",
		text = note,
		size = UDim2.new(1, 0, 0, 20),
		position = UDim2.fromOffset(0, 86),
		parent = face,
		align = Enum.TextXAlignment.Center,
		color = if mine then Theme.colors.inkSoft else Theme.colors.label,
		textSize = 13,
		bold = false,
	})
end

local function renderCollection()
	heading(leftPage, "Golden blades")
	local scroll = body(leftPage)

	--- Four across, which is what a page of eight reads as: two rows.
	local column = scroll:FindFirstChildOfClass("UIListLayout")
	if column then
		column:Destroy()
	end
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0.25, -11, 0, 132)
	grid.CellPadding = UDim2.fromOffset(14, 14)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scroll

	local world = PlayerState.world()
	local total, mine = 0, 0
	if world then
		for order, section in world.sections do
			local has = PlayerState.hasBlade(section.id)
			total += 1
			if has then
				mine += 1
			end
			bladeCard(scroll, order, section, has)
		end
	end

	--[[
		What the whole set is worth, said in words.

		The blades are the one thing in the game nobody is made to do — the
		design note is explicit that they are never required for a hundred per
		cent — so the page has to give a reason to go looking that is not a
		completion bar.
	]]
	heading(rightPage, "The hunt")
	local right = body(rightPage)

	local tally = card(right, 108)
	tally.LayoutOrder = 1
	Theme.pad(tally, 14, 16, 14, 16)
	Theme.text({
		name = "Heading",
		text = "THIS PROPERTY",
		size = UDim2.new(1, 0, 0, 18),
		position = UDim2.fromOffset(0, 0),
		parent = tally,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.inkSoft,
		textSize = 13,
	})
	Theme.text({
		name = "Count",
		text = `{mine} / {total}`,
		size = UDim2.new(1, 0, 0, 40),
		position = UDim2.fromOffset(0, 20),
		parent = tally,
		align = Enum.TextXAlignment.Left,
		color = INK,
		textSize = 34,
	})
	Theme.text({
		name = "Note",
		text = if mine >= total and total > 0
			then "every one of them, this run"
			else `{total - mine} still hidden — one to a zone`,
		size = UDim2.new(1, 0, 0, 20),
		position = UDim2.fromOffset(0, 62),
		parent = tally,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.inkSoft,
		textSize = 15,
		bold = false,
	})

	local words = card(right, 0)
	words.LayoutOrder = 2
	words.AutomaticSize = Enum.AutomaticSize.Y
	Theme.pad(words, 14, 16, 16, 16)
	local flow = Instance.new("UIListLayout")
	flow.SortOrder = Enum.SortOrder.LayoutOrder
	flow.Padding = UDim.new(0, 8)
	flow.Parent = words

	local lines: { { text: string, size: number, ink: Color3 } } = {
		{ text = "WHAT THEY PAY", size = 15, ink = Theme.colors.inkSoft },
		{
			text = "A flat finder's fee in cash and a handful of tips, wherever you find it.",
			size = 17,
			ink = INK,
		},
		{ text = "WHERE THEY ARE", size = 15, ink = Theme.colors.inkSoft },
		{
			text = "One hidden in every zone, in the same place on every server, put back each round.",
			size = 17,
			ink = INK,
		},
		{ text = "AND THE RULE", size = 15, ink = Theme.colors.inkSoft },
		{
			text = "Never needed to finish a property. Somewhere to go that nobody made you go.",
			size = 17,
			ink = INK,
		},
	}
	for order, line in lines do
		local label = Instance.new("TextLabel")
		label.Name = `Line{order}`
		label.Text = line.text
		label.Size = UDim2.fromScale(1, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.BackgroundTransparency = 1
		label.Font = if line.size >= 17 then Theme.fontRegular else Theme.font
		label.TextColor3 = line.ink
		label.TextSize = line.size
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.TextWrapped = true
		label.LayoutOrder = order
		label.Parent = words
	end
end

--[[
	The help spread, which leads with what tips are.

	Cash resets with every run and tips do not, and nothing in the game said
	so — a player could finish a property without ever learning what the
	number in the corner was for. It is the first thing on this page now,
	with where they come from and the only thing they buy, because a currency
	nobody can explain is a currency nobody spends.
]]
local function renderTips()
	--[[
		Every word on this spread is on a card now.

		It was bare text, and it was written in the book's ink — which was
		right while the pages were parchment and is invisible now that the
		spread is dark wood: two columns of near-black type on a near-black
		panel, the only page in the journal you could not read at all.
	]]
	local function note(parent: Instance, order: number): Frame
		local sheet = card(parent, 0)
		sheet.LayoutOrder = order
		sheet.AutomaticSize = Enum.AutomaticSize.Y
		Theme.pad(sheet, 14, 16, 16, 16)

		local flow = Instance.new("UIListLayout")
		flow.SortOrder = Enum.SortOrder.LayoutOrder
		flow.Padding = UDim.new(0, 6)
		flow.Parent = sheet
		return sheet
	end

	local function line(parent: Instance, text: string, order: number, size: number, colour: Color3)
		local label = Instance.new("TextLabel")
		label.Text = text
		label.Size = UDim2.fromScale(1, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.BackgroundTransparency = 1
		label.Font = if size >= 18 then Theme.font else Theme.fontRegular
		label.TextColor3 = colour
		label.TextSize = size
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.TextWrapped = true
		label.LayoutOrder = order
		label.Parent = parent
		return label
	end

	local SOFT = Color3.fromRGB(92, 80, 66)

	heading(leftPage, "Tips")
	local scroll = body(leftPage)

	local what = note(scroll, 1)
	line(what, "Cash is for this run and goes when it ends.", 1, 19, INK)
	line(what, "Tips are yours to keep — a run never takes them back.", 2, 17, SOFT)

	local sources = note(scroll, 2)
	line(sources, "YOU EARN THEM BY", 1, 15, SOFT)
	local earned = {
		"logging in — more each day in a row",
		"every eight minutes of work",
		"cutting a long straight Clean Stripe",
		"finding the Golden Blade hidden in a section",
		"finishing a property, by your share of the work",
	}
	for order, text in earned do
		line(sources, `•  {text}`, 1 + order, 17, INK)
	end

	local spend = note(scroll, 3)
	line(spend, "WHAT THEY BUY", 1, 15, SOFT)
	line(
		spend,
		"A tool bought with tips on the Tools page is yours for good, and you start every run already holding it.",
		2,
		17,
		INK
	)

	heading(rightPage, "Controls")
	local right = body(rightPage)

	--[[
		What the controls actually do, for the screen in the player's hands.

		This used to be one list of keys, and it was read on tablets — which
		is nearly everybody — by players who have no keys. The touch list
		names the buttons that are on the screen; the keyboard one names the
		keys. It also used to promise that B opened "the shed", which it never
		did: B and TAB are bound to the same action, and both open this book.
	]]
	local controls: { string } = if Theme.hasKeyboard()
		then {
			"Hold left mouse or E — work",
			"TAB or B — open this journal",
			"G — the Robux store",
			"F — mount a riding mower",
			"T — park the portable trailer",
		}
		else {
			"Hold the tool button — work",
			"Tap the Journal — open this journal",
			"Tap STORE — the Robux store",
			"Tap Ride — mount a riding mower",
			"Tap Trailer — park the portable trailer",
		}

	local keys = note(right, 1)
	for order, text in controls do
		line(keys, text, order, 17, INK)
	end
	line(keys, "Upgrades and tools are bought in this journal, or at the boards outside the shed.", #controls + 1, 15, SOFT)

	local hints = note(right, 2)
	line(hints, "WORTH KNOWING", 1, 15, SOFT)
	for order, text in {
		"Hold to work. Your deck cuts a swath as wide as the tool.",
		"The bag is the bottleneck early. Buy it on Upgrades, first.",
		"Walk into the trailer to sell — there is no button to press.",
		"Grass too thick for your tool will bog it down. Buy better.",
		"Cut in long straight lines to bank a Clean Stripe bonus.",
		"Some sections are not for sale. Clear a yard, or find the switch.",
	} do
		line(hints, `•  {text}`, 1 + order, 17, INK)
	end
end

--------------------------------------------------------------------
-- Shell
--------------------------------------------------------------------

--[[
	What the open spread is made of, as one string.

	Everything that changes the *shape* of a page goes in here; nothing that
	merely changes a number on it does. Cash, bag weight and quest progress are
	deliberately absent — those move five times a second, and they are what
	`live` is for.
]]
local function signature(): string
	local state = PlayerState.get()
	local parts = { activeTab, state.equippedTool, selectedTool or "-", tostring(state.hasPortableTrailer) }

	local owned = {}
	for id in state.ownedTools do
		table.insert(owned, id)
	end
	table.sort(owned)
	table.insert(parts, table.concat(owned, ","))

	--[[
		What you own for good, which is a different set from what you own now.

		The tool spread offers two prices — cash for this run, tips for every
		run after — and the tips one disappears once it is bought. Buying
		permanence for a tool you had *already* bought with cash this run
		changes neither `ownedTools` nor the equipped tool, so without this the
		spread would not redraw and the offer would sit there having already
		been taken.
	]]
	local kept = {}
	for id, has in state.permanentTools do
		if has then
			table.insert(kept, id)
		end
	end
	table.sort(kept)
	table.insert(parts, table.concat(kept, ","))

	local levels = {}
	for key, level in state.upgrades do
		table.insert(levels, `{key}={level}`)
	end
	table.sort(levels)
	table.insert(parts, table.concat(levels, ","))

	for _, entry in questState do
		table.insert(parts, `{entry.id}:{if entry.done then 1 else 0}`)
	end

	for _, subject in Players:GetPlayers() do
		table.insert(parts, tostring(subject.UserId))
	end

	local world = PlayerState.world()
	table.insert(parts, if world then world.id else "-")

	local open = {}
	for id, isOpenSection in PlayerState.openSections() do
		if isOpenSection then
			table.insert(open, id)
		end
	end
	table.sort(open)
	table.insert(parts, table.concat(open, ","))

	return table.concat(parts, "|")
end

local lastSignature: string? = nil

local function render()
	if not isOpen then
		-- Nothing is standing, so nothing can be reused next time it opens.
		lastSignature = nil
		table.clear(liveBits)
		return
	end

	local purse = PlayerState.get()
	--[[
		The block at the foot of the rail says what the open page is about.

		Money, on every page that sells something — which is most of them, and
		it is why the block is beside the tabs rather than at the bottom of a
		page. The collection page sells nothing: what it is counting is
		blades, and a run-cash figure next to a grid of medals is the one
		number on that page nobody is looking for.
	]]
	if activeTab == "collection" then
		local world = PlayerState.world()
		local total = if world then #world.sections else 0
		local found = 0
		if world then
			for _, section in world.sections do
				if PlayerState.hasBlade(section.id) then
					found += 1
				end
			end
		end
		purseHeading.Text = "GOLDEN BLADES"
		railCash.Text = `{found} / {total}`
		railCash.TextColor3 = Theme.colors.tips
		railTips.Text = if found >= total and total > 0 then "all of them" else "hidden in the sections"
		railTips.TextColor3 = Theme.colors.label
	else
		purseHeading.Text = "RUN CASH"
		railCash.Text = Format.cash(purse.cash)
		railCash.TextColor3 = Theme.colors.cash
		railTips.Text = if purse.tips > 0 then `{Format.count(purse.tips)} tips` else ""
		railTips.TextColor3 = Theme.colors.tips
	end

	local now = signature()
	if now == lastSignature then
		for _, update in liveBits do
			update()
		end
		return
	end
	lastSignature = now

	table.clear(liveBits)
	clear(leftPage)
	clear(rightPage)

	if activeTab == "objectives" then
		renderObjectives()
		renderPlayers()
	elseif activeTab == "stats" then
		renderStats()
	elseif activeTab == "upgrades" then
		renderUpgrades()
	elseif activeTab == "collection" then
		renderCollection()
	else
		renderTips()
	end
end

--- Re-renders the open spread in place. Cards call this after a selection.
function Journal.refresh()
	render()
end

--- True when anything in the book — a slot on an owned tool, or the next tool
--- itself — is affordable right now.
function Journal.somethingAffordable(): boolean
	local state = PlayerState.get()

	-- The player's own lines first: the bag is usually the answer, and it is
	-- the one the badge most needs to be pointing at.
	for _, def in Upgrades.list do
		local cost = Upgrades.costAt(def, state.upgrades[def.id] or 0)
		if cost and state.cash >= cost then
			return true
		end
	end

	for toolId in state.ownedTools do
		for _, slot in ToolUpgrades.treeFor(toolId) do
			local cost = ToolUpgrades.costAt(slot, state.upgrades[slot.key] or 0)
			if cost and state.cash >= cost then
				return true
			end
		end
	end

	for _, tool in Tools.list do
		if tool.cost > 0 and not state.ownedTools[tool.id] and state.cash >= tool.cost then
			return true
		end
	end
	return false
end

local function refreshBadge()
	local badge = upgradeBadge
	if badge then
		badge.Visible = Journal.somethingAffordable()
	end
end

--- The title and the sentence under it, per tab. A window that opens on a
--- list of objectives under the heading UPGRADE JOURNAL is lying to you.
local COPY: { [string]: { title: string, blurb: string } } = {
	objectives = {
		title = "Objectives",
		blurb = "Tick these off for tips and cash. Nothing here is required to finish.",
	},
	stats = {
		title = "Upgrades",
		blurb = "Seven lines, all reset each run. First levels cost a dollar or two.",
	},
	--[[
		"The Shed", because that is what the rest of the game calls it.

		The overgrowth card's button says OPEN THE SHED, the first run's third
		step says open the shed and spend it, and the store's header points at
		the shed. The page they all lead to was headed "Tools", which is the
		word on the rail beside it and not the name of the place.
	]]
	upgrades = {
		title = "The Shed",
		blurb = "Everything resets when the run does. Bare hands can shift anything.",
	},
	collection = {
		title = "Golden Blades",
		blurb = "One hidden in every zone, back in a new place each round. Never required to finish.",
	},
	tips = {
		title = "Help",
		blurb = "How the run works, and every key this game listens for.",
	},
}

local function setTab(id: string)
	activeTab = id
	local copy = COPY[id]
	if bookTitle and copy then
		bookTitle.Text = copy.title
	end
	if tabBlurb and copy then
		tabBlurb.Text = copy.blurb
	end
	--[[
		Gold when it is the page you are on, dark when it is not.

		The rail used to say it with size — a selected tab twenty pixels wider
		than the others — which is a difference you can only see by comparing
		it with its neighbours. Colour says it on its own, and it is the same
		gold the store pill and the section badge use for "this one".
	]]
	for tabId, button in tabButtons do
		local selected = tabId == id
		local face = button:FindFirstChild("Face") :: Frame?
		local label = button:FindFirstChild("Label") :: TextLabel?
		local well = button:FindFirstChild("Well") :: Frame?
		if face then
			face.BackgroundColor3 = if selected
				then Color3.fromRGB(255, 217, 104)
				else Color3.fromRGB(44, 33, 24)
			local grade = face:FindFirstChildOfClass("UIGradient")
			if grade then
				grade.Enabled = selected
			end
			local drop = button:FindFirstChild("Drop") :: Frame?
			if drop then
				drop.Visible = selected
			end
		end
		if label then
			label.TextColor3 = if selected then Theme.colors.outline else Theme.colors.body
		end
		if well then
			well.BackgroundColor3 = if selected
				then Color3.fromRGB(255, 240, 188)
				else Color3.fromRGB(74, 56, 38)
		end
	end
	render()
end

local function buildTab(parent: Instance, order: number, tab: { id: string, label: string, icon: string, color: Color3 })
	local seat = Instance.new("TextButton")
	seat.Name = tab.id
	seat.Size = UDim2.new(1, 0, 0, 46)
	seat.LayoutOrder = order
	seat.BackgroundTransparency = 1
	seat.Text = ""
	seat.AutoButtonColor = false
	--- Modal, like the close button: the camera pins the cursor to the centre
	--- of the screen, so without it the rail cannot be clicked on a desktop.
	seat.Modal = true
	seat.Parent = parent

	local drop = Instance.new("Frame")
	drop.Name = "Drop"
	drop.Size = UDim2.fromScale(1, 1)
	drop.Position = UDim2.fromOffset(0, 4)
	drop.BackgroundColor3 = Color3.fromRGB(169, 110, 8)
	drop.BorderSizePixel = 0
	drop.ZIndex = 0
	drop.Visible = false
	drop.Parent = seat
	Theme.corner(drop, 14)

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.fromScale(1, 1)
	face.BackgroundColor3 = Color3.fromRGB(44, 33, 24)
	face.BorderSizePixel = 0
	face.Parent = seat
	Theme.corner(face, 14)
	Theme.stroke(face, 3, Theme.colors.outline, 0)
	local grade = Instance.new("UIGradient")
	grade.Color = ColorSequence.new(Color3.fromRGB(255, 217, 104), Color3.fromRGB(245, 168, 28))
	grade.Rotation = 90
	grade.Enabled = false
	grade.Parent = face

	local well = Instance.new("Frame")
	well.Name = "Well"
	well.Size = UDim2.fromOffset(26, 26)
	well.Position = UDim2.new(0, 12, 0.5, 0)
	well.AnchorPoint = Vector2.new(0, 0.5)
	well.BackgroundColor3 = Color3.fromRGB(74, 56, 38)
	well.BorderSizePixel = 0
	well.Parent = seat
	Theme.corner(well, 8)
	Theme.stroke(well, 2.5, Theme.colors.outline, 0)

	--[[
		The thing the tab is about, in the well.

		Every tab in `TABS` has carried an icon name since the rail was
		written and nothing had ever drawn it, so the rail was five empty
		boxes down the side of the book — furniture that looked like it was
		waiting for something rather than like a row of buttons.
	]]
	Theme.icon({
		name = "Icon",
		prop = tab.icon,
		size = UDim2.fromScale(0.82, 0.82),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = well,
	})

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Text = tab.label
	label.Size = UDim2.new(1, -54, 1, 0)
	label.Position = UDim2.fromOffset(48, 0)
	label.BackgroundTransparency = 1
	label.Font = Theme.font
	label.TextColor3 = Theme.colors.body
	label.TextSize = 18
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = seat

	seat.Activated:Connect(function()
		setTab(tab.id)
	end)
	tabButtons[tab.id] = seat
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MowJournal"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 8
	gui.Parent = player:WaitForChild("PlayerGui")

	local shade = Instance.new("Frame")
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.38
	shade.BorderSizePixel = 0
	shade.Parent = gui

	--[[
		One panel, in the chrome everything else on the screen wears.

		This was a book: a blue cover, cream pages, a spine shadow down the
		middle and a tab strip hanging a hundred and sixty-four pixels off its
		left edge. A different game from the HUD behind it — and the overhang
		is why it needed to be scaled to fit at all, because the first thing
		to leave a narrow screen was the tabs and the close button.

		Nothing hangs outside it now, so `fitToViewport` is measuring the
		panel and not the panel plus what is sticking off it.
	]]
	local book = Theme.chunkPanel({
		name = "Book",
		size = UDim2.fromOffset(1024, 678),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = gui,
		radius = 26,
		drop = 12,
		outline = 5,
		top = Color3.fromRGB(66, 49, 31),
		bottom = Color3.fromRGB(42, 31, 21),
	})
	book.ClipsDescendants = true
	Theme.fitToViewport(book.Parent :: Frame, 1024 + 40, 678 + 40)

	----------------------------------------------------------------
	-- The rail
	----------------------------------------------------------------

	local rail = Instance.new("Frame")
	rail.Name = "Rail"
	rail.Size = UDim2.new(0, 196, 1, 0)
	rail.BackgroundColor3 = Color3.fromRGB(30, 22, 16)
	rail.BorderSizePixel = 0
	rail.Parent = book

	--- A five-pixel ink edge down its right-hand side. A `UIStroke` would put
	--- one on all four, and three of those are behind the panel's own border.
	local railEdge = Instance.new("Frame")
	railEdge.Name = "Edge"
	railEdge.Size = UDim2.new(0, 5, 1, 0)
	railEdge.Position = UDim2.new(1, -5, 0, 0)
	railEdge.BackgroundColor3 = Theme.colors.outline
	railEdge.BorderSizePixel = 0
	railEdge.Parent = rail

	local railInner = Instance.new("Frame")
	railInner.Name = "Inner"
	railInner.Size = UDim2.new(1, -33, 1, -40)
	railInner.Position = UDim2.fromOffset(14, 20)
	railInner.BackgroundTransparency = 1
	railInner.Parent = rail

	local railWord = Instance.new("TextLabel")
	railWord.Name = "Word"
	railWord.Text = "JOURNAL"
	railWord.Size = UDim2.new(1, 0, 0, 20)
	railWord.BackgroundTransparency = 1
	railWord.Font = Theme.font
	railWord.TextColor3 = Theme.colors.label
	railWord.TextSize = 13
	railWord.TextXAlignment = Enum.TextXAlignment.Left
	railWord.LayoutOrder = 0
	railWord.Parent = railInner

	local railFlow = Instance.new("UIListLayout")
	railFlow.SortOrder = Enum.SortOrder.LayoutOrder
	railFlow.Padding = UDim.new(0, 10)
	railFlow.Parent = railInner

	for order, tab in TABS do
		buildTab(railInner, order, tab)
	end

	--[[
		What you have to spend, at the foot of the rail.

		It used to be one line at the bottom-right of the right-hand page,
		which is the last place a player looks and the furthest from every
		price on the page. Money belongs beside the tabs, where it is in
		view whichever page is open.
	]]
	local purse = Instance.new("Frame")
	purse.Name = "Purse"
	purse.Size = UDim2.fromOffset(168, 92)
	purse.Position = UDim2.new(0, 14, 1, -20)
	purse.AnchorPoint = Vector2.new(0, 1)
	purse.BackgroundColor3 = Color3.fromRGB(44, 33, 24)
	purse.BorderSizePixel = 0
	purse.Parent = rail
	Theme.corner(purse, 14)
	Theme.stroke(purse, 3, Theme.colors.outline, 0)
	Theme.pad(purse, 12, 12, 12, 12)

	local purseWord = Instance.new("TextLabel")
	purseHeading = purseWord
	purseWord.Text = "RUN CASH"
	purseWord.Size = UDim2.new(1, 0, 0, 16)
	purseWord.BackgroundTransparency = 1
	purseWord.Font = Theme.font
	purseWord.TextColor3 = Theme.colors.label
	purseWord.TextSize = 13
	purseWord.TextXAlignment = Enum.TextXAlignment.Left
	purseWord.Parent = purse

	railCash = Instance.new("TextLabel")
	railCash.Name = "Cash"
	railCash.Text = "$0.00"
	railCash.Size = UDim2.new(1, 0, 0, 30)
	railCash.Position = UDim2.fromOffset(0, 18)
	railCash.BackgroundTransparency = 1
	railCash.Font = Theme.font
	railCash.TextColor3 = Theme.colors.cash
	railCash.TextSize = 26
	railCash.TextXAlignment = Enum.TextXAlignment.Left
	railCash.Parent = purse

	railTips = Instance.new("TextLabel")
	railTips.Name = "Tips"
	railTips.Text = ""
	railTips.Size = UDim2.new(1, 0, 0, 20)
	railTips.Position = UDim2.fromOffset(0, 48)
	railTips.BackgroundTransparency = 1
	railTips.Font = Theme.font
	railTips.TextColor3 = Theme.colors.tips
	railTips.TextSize = 15
	railTips.TextXAlignment = Enum.TextXAlignment.Left
	railTips.Parent = purse

	-- The red ! : something in the book is affordable right now. Same signal
	-- the HUD's journal tile carries, for the same reason — the moment a
	-- purchase comes into reach is invisible unless something says.
	local badge = Instance.new("Frame")
	badge.Name = "UpgradeBadge"
	badge.Size = UDim2.fromOffset(24, 24)
	badge.Position = UDim2.new(1, -18, 0, 8)
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.BackgroundColor3 = Theme.colors.danger
	badge.BorderSizePixel = 0
	badge.Visible = false
	badge.ZIndex = 3
	badge.Parent = rail
	upgradeBadge = badge

	local badgeRound = Instance.new("UICorner")
	badgeRound.CornerRadius = UDim.new(0.5, 0)
	badgeRound.Parent = badge
	Theme.stroke(badge, 2.5, Theme.colors.outline, 0)

	local bang = Instance.new("TextLabel")
	bang.Text = "!"
	bang.Size = UDim2.fromScale(1, 1)
	bang.BackgroundTransparency = 1
	bang.Font = Theme.font
	bang.TextColor3 = Theme.colors.text
	bang.TextSize = 17
	bang.ZIndex = 3
	bang.Parent = badge

	----------------------------------------------------------------
	-- Header and the two columns
	----------------------------------------------------------------

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, -196, 1, 0)
	content.Position = UDim2.fromOffset(196, 0)
	content.BackgroundTransparency = 1
	content.Parent = book

	bookTitle = Instance.new("TextLabel")
	bookTitle.Name = "BookTitle"
	bookTitle.Text = "Objectives"
	bookTitle.Size = UDim2.new(1, -120, 0, 38)
	bookTitle.Position = UDim2.fromOffset(26, 22)
	bookTitle.BackgroundTransparency = 1
	bookTitle.Font = Theme.font
	bookTitle.TextColor3 = Theme.colors.text
	bookTitle.TextSize = 32
	bookTitle.TextXAlignment = Enum.TextXAlignment.Left
	bookTitle.Parent = content
	Theme.outline(bookTitle, 3)

	tabBlurb = Instance.new("TextLabel")
	tabBlurb.Name = "Blurb"
	tabBlurb.Text = ""
	tabBlurb.Size = UDim2.new(1, -120, 0, 22)
	tabBlurb.Position = UDim2.fromOffset(26, 60)
	tabBlurb.BackgroundTransparency = 1
	tabBlurb.Font = Theme.font
	tabBlurb.TextColor3 = Theme.colors.body
	tabBlurb.TextSize = 16
	tabBlurb.TextXAlignment = Enum.TextXAlignment.Left
	tabBlurb.Parent = content

	--[[
		Close, top right, in the danger variant.

		It was an eighty-eight pixel red square overhanging the cover's
		corner, which made it the first thing off a short screen — the
		journal with no visible way to shut it. Inside the panel, in the same
		button language as everything else, it cannot leave.

		Modal is what gives the journal a usable mouse: the camera is locked
		to first person, which pins the cursor to the centre of the screen, so
		without it every control in here sits somewhere the cursor can never
		reach — and tools are only ever bought from this panel.
	]]
	local close = Theme.chunkButton({
		name = "Close",
		variant = "danger",
		text = "×",
		textSize = 26,
		size = UDim2.fromOffset(48, 48),
		position = UDim2.new(1, -26, 0, 22),
		anchor = Vector2.new(1, 0),
		parent = content,
		radius = 14,
		outline = 4,
	})
	close.Modal = true
	close.Activated:Connect(function()
		Journal.setOpen(false)
	end)

	--[[
		Two columns, which is what every page in here already assumed.

		The book was a spread — a left page and a right page — and all five
		renderers write into those two frames. The Tools page in particular is
		a grid on one side and a detail pane on the other, which is exactly
		the shape the redesign asks for, so the two survive as columns rather
		than as pages: the wide one takes whatever is left, the narrow one is
		the two hundred and eighty-four the detail pane wants.
	]]
	local columns = Instance.new("Frame")
	columns.Name = "Columns"
	columns.Size = UDim2.new(1, -52, 1, -122)
	columns.Position = UDim2.fromOffset(26, 96)
	columns.BackgroundTransparency = 1
	columns.Parent = content

	leftPage = Instance.new("Frame")
	leftPage.Name = "Left"
	leftPage.Size = UDim2.new(1, -302, 1, 0)
	leftPage.BackgroundTransparency = 1
	leftPage.Parent = columns

	rightPage = Instance.new("Frame")
	rightPage.Name = "Right"
	rightPage.Size = UDim2.new(0, 284, 1, 0)
	rightPage.Position = UDim2.fromScale(1, 0)
	rightPage.AnchorPoint = Vector2.new(1, 0)
	rightPage.BackgroundTransparency = 1
	rightPage.Parent = columns

	--- Kept so `render` has somewhere to write the running total; the rail
	--- carries the visible one.
	moneyLabel = Instance.new("TextLabel")
	moneyLabel.Name = "Money"
	moneyLabel.Text = ""
	moneyLabel.Size = UDim2.fromOffset(1, 1)
	moneyLabel.BackgroundTransparency = 1
	moneyLabel.Visible = false
	moneyLabel.Parent = content
end

function Journal.setOpen(open: boolean)
	if open == isOpen then
		return
	end
	isOpen = open
	gui.Enabled = open
	Theme.holdCursor(open)

	if open then
		render()
		-- Opening it is itself an objective.
		questRemote:FireServer("opened")

		local book = gui:FindFirstChild("Book")
		if book and book:IsA("Frame") then
			book.Size = UDim2.fromOffset(880, 500)
			TweenService:Create(book, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Size = UDim2.fromOffset(940, 560),
			}):Play()
		end
	end
end

function Journal.isOpen(): boolean
	return isOpen
end

--[[
	Open the book on one tool, from somewhere else in the game.

	The overgrowth card's whole job is to name the fix, so its button has to
	land on that tool's page rather than on the shed's front door — "open the
	shed" and then a shelf of sixteen is the toast's answer with an extra
	click on it.
]]
function Journal.openTool(toolId: string)
	selectedTool = toolId
	setTab("upgrades")
	Journal.setOpen(true)
end

--[[
	Open the shed's shelf, with nothing picked out on it.

	The store sells the passes and the boosts and deliberately does not sell
	the sixteen tools a second time — each tool's own page already carries its
	two Robux buttons beside the cash price, which is where somebody deciding
	between the three is looking. So the store points here rather than
	repeating thirty rows of it.
]]
function Journal.openUpgrades()
	setTab("upgrades")
	Journal.setOpen(true)
end

function Journal.toggle()
	Journal.setOpen(not isOpen)
end

function Journal.start()
	purchaseRemote = Remotes.event(Remotes.PURCHASE)
	promptRemote = Remotes.event(Remotes.PROMPT_PURCHASE)
	questRemote = Remotes.event(Remotes.QUESTS)

	build()
	setTab("objectives")

	questRemote.OnClientEvent:Connect(function(snapshot: any)
		if type(snapshot) == "table" then
			questState = snapshot
			render()
		end
	end)

	PlayerState.Changed:Connect(function()
		refreshBadge()
		if isOpen then
			render()
		end
	end)
end

--- The objective the player is currently working on, for the HUD.
function Journal.currentObjective(): (string?, number, number)
	for _, entry in questState do
		if not entry.done then
			return entry.text, entry.progress, entry.target
		end
	end
	return nil, 0, 0
end

export type JobRow = { text: string, progress: number, target: number, done: boolean }

--[[
	The next few objectives, for the HUD's own job panel.

	`currentObjective` hands back one, which is what a single line of text
	needed. The panel shows a short list — three is what fits, and a list is
	what makes them read as a job rather than as a caption. Finished ones are
	included, in order, because a ticked box is most of why anybody looks.
]]
function Journal.jobs(limit: number): { JobRow }
	local out: { JobRow } = {}
	for _, entry in questState do
		if not entry.done then
			table.insert(out, {
				text = entry.text,
				progress = entry.progress,
				target = entry.target,
				done = false,
			})
			if #out >= limit then
				return out
			end
		end
	end
	for _, entry in questState do
		if entry.done and #out < limit then
			table.insert(out, {
				text = entry.text,
				progress = entry.progress,
				target = entry.target,
				done = true,
			})
		end
	end
	return out
end

return Journal
