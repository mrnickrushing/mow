--!strict
--[[
	Store — the Robux shop, as a place you go rather than a box over the game.

	It used to be a six-hundred-wide window over a shaded lawn holding
	forty-five rows in one scrolling list: seven passes, eight boosts, and then
	thirty tool unlocks, each tool sold twice. Finding Fast Feet meant scrolling
	past the chainsaw. The handoff makes it a destination on the same ground as
	world select — one flagship at the top, then the two lists a player actually
	chooses between, side by side and short enough to read whole.

	The thirty tool rows are gone from here on purpose. Every tool's own page in
	the shed already carries its two Robux buttons beside the cash price, which
	is where somebody weighing the three ways to get a chainsaw is looking; the
	header points there rather than repeating the shelf.

	Nothing on this screen is required to finish a property, and the strip along
	the bottom is the proof: the three free loops, running, with the next one
	counting down.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Loop = require(Shared.Util.Loop)
local Monetization = require(Shared.Config.Monetization)
local Prices = require(Shared.Prices)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Journal = require(script.Parent.Journal)
local Theme = require(script.Parent.Theme)

local Store = {}

local player = Players.LocalPlayer
local promptRemote: RemoteEvent
local gui: ScreenGui
local isOpen = false

--- The product the featured slab is reserved for.
local FEATURED_KEY = "rentZeroTurn"

--- Authored at the handoff's size and scaled down to whatever the screen is.
local STAGE = Vector2.new(1194, 834)
local PAD_X, PAD_Y = 34, 28
local GAP = 18
local HEADER_H = 76
local FEATURE_H = 136
local STRIP_H = 78
local INNER_W = STAGE.X - PAD_X * 2
local COLUMN_W = (INNER_W - 20) // 2
local COLUMNS_H = STAGE.Y - PAD_Y * 2 - HEADER_H - FEATURE_H - STRIP_H - GAP * 3
--- The column's own header, over the list.
local LIST_TOP = 33
--[[
	Rows are one line, and the price chip is what decides how tall that line is.

	At the handoff's `3/14/4` padding with a two-pixel border the chip comes out
	at thirty-two and the row at forty-six, and seven of those fit the column
	with room to spare. The note in the handoff is emphatic about this because
	the first build used the bigger button padding everywhere: the chip grew to
	forty-three, the row to fifty-seven, and the seventh pass fell off the
	bottom of a screen that has no scrollbar to tell you it had.
]]
local ROW_H = 46
local CHIP_W, CHIP_H = 92, 32
--- The scrollbar's inset is taken whether or not the bar is drawn, so a row's
--- width is one number rather than two.
local BAR = 6
local ROW_W = COLUMN_W - BAR

local INK = Color3.fromRGB(24, 18, 10)
local WELL = Color3.fromRGB(58, 44, 30)
local TILE = Color3.fromRGB(44, 33, 24)
local PASS_TINT = Color3.fromRGB(199, 155, 240)
local BOOST_TINT = Color3.fromRGB(127, 198, 245)

--[[
	Where the free loops have got to, and when we were told.

	The server sends remaining seconds rather than a deadline, because the two
	clocks have no shared origin; the chip counts down from the moment the push
	landed. The defaults are what a player who has just joined would be told
	anyway, so the screen is never drawn with a blank timer on it.
]]
type Rewards = {
	streak: number,
	streakOf: number,
	streakTips: number,
	nextTips: number,
	nextRental: number,
}
local rewards: Rewards = {
	streak = 0,
	streakOf = #Monetization.rewards.dailyStreak,
	streakTips = Monetization.rewards.dailyStreak[1],
	nextTips = Monetization.rewards.playtimeInterval,
	nextRental = Monetization.rewards.freeRentalInterval,
}
local rewardsAt = os.clock()

local passList: ScrollingFrame
local boostList: ScrollingFrame
local featureSlot: Frame
local rentalLabel: TextLabel
local streakLabel: TextLabel
local emptyLabel: TextLabel

--------------------------------------------------------------------
-- Pieces
--------------------------------------------------------------------

--[[
	The drawn icons that survive being thirty pixels across.

	Nine of the fifteen rows could be given one from the existing set, and six
	of those nine came out as smudges: the Golden Blade is a sliver at this
	size, the sack a grey lump, the rake a faint grey T. A picture nobody can
	identify is worse than no picture, so those rows get a flat diamond in
	their column's colour instead — which reads cleanly, and reads the same
	down the whole list. `ICON-BRIEFS.md` specifies the drawn icons this shop
	is actually missing.
]]
local ICON_FOR: { [string]: string } = {
	doubleCash = "Coin",
	cashBoost3x = "Coin",
	rentZeroTurn = "RidingMower",
	rentRidingMower = "RidingMower",
}

--- The dark tile an icon sits in, with whatever we have to put in it.
local function well(parent: Instance, key: string, tint: Color3, size: number, position: UDim2): Frame
	local tile = Instance.new("Frame")
	tile.Name = "Well"
	tile.Size = UDim2.fromOffset(size, size)
	tile.Position = position
	tile.BackgroundColor3 = WELL
	tile.BorderSizePixel = 0
	tile.Parent = parent
	Theme.corner(tile, if size > 60 then 14 else 8)
	Theme.stroke(tile, 3, INK, 0)

	local prop = ICON_FOR[key]
	if prop then
		Theme.icon({
			name = "Icon",
			prop = prop,
			size = UDim2.fromScale(if size > 60 then 0.8 else 0.88, if size > 60 then 0.8 else 0.88),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
			parent = tile,
		})
	else
		local diamond = Instance.new("Frame")
		diamond.Name = "Diamond"
		diamond.Size = UDim2.fromOffset(size // 3, size // 3)
		diamond.Position = UDim2.fromScale(0.5, 0.5)
		diamond.AnchorPoint = Vector2.new(0.5, 0.5)
		diamond.Rotation = 45
		diamond.BackgroundColor3 = tint
		diamond.BorderSizePixel = 0
		diamond.Parent = tile
		Theme.corner(diamond, 3)
	end
	return tile
end

--[[
	One line: what it is, what it does, and what it costs.

	The name and the effect are a single rich-text label rather than two, so
	the effect starts where the name ends however long the name is — and so the
	truncation the handoff asks for lands on the effect, which can lose its
	tail, instead of on the name, which cannot.
]]
local function addRow(
	list: ScrollingFrame,
	order: number,
	key: string,
	title: string,
	effect: string,
	robux: number,
	keeps: boolean,
	buy: () -> ()
)
	local row = Instance.new("Frame")
	row.Name = key
	row.Size = UDim2.fromOffset(ROW_W, ROW_H)
	row.BackgroundColor3 = TILE
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = list
	Theme.corner(row, 12)
	Theme.stroke(row, 3, INK, 0)

	local tint = if keeps then PASS_TINT else BOOST_TINT
	well(row, key, tint, 30, UDim2.fromOffset(10, 8))

	local textLeft = 52
	local textRight = ROW_W - 10 - CHIP_W - 10
	local label = Theme.text({
		name = "Line",
		text = `{title}  <font size="14" color="rgb(179,156,126)">{effect}</font>`,
		size = UDim2.fromOffset(textRight - textLeft, ROW_H),
		position = UDim2.fromOffset(textLeft, 0),
		parent = row,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.progress,
		textSize = 17,
	})
	label.TextTruncate = Enum.TextTruncate.AtEnd
	--- Two pixels, not three: the heavy outline a title gets makes a
	--- fourteen-point caption inside the same label read as a smudge.
	local edge = label:FindFirstChildOfClass("UIStroke")
	if edge then
		edge.Thickness = 2
	end

	local chip = Theme.chunkButton({
		name = "Price",
		variant = if keeps then "robuxKeep" else "robuxRun",
		text = `R$ {robux}`,
		textSize = 16,
		size = UDim2.fromOffset(CHIP_W, CHIP_H),
		position = UDim2.new(1, -10, 0, (ROW_H - CHIP_H) // 2 - 1),
		anchor = Vector2.new(1, 0),
		parent = row,
		radius = 9,
		drop = 3,
		outline = 3,
	})
	chip.Activated:Connect(buy)
end

--- A column: a fixed heading over a list that can grow past its own bottom.
local function addColumn(parent: Instance, x: number, name: string, tint: Color3, blurb: string): ScrollingFrame
	local holder = Instance.new("Frame")
	holder.Name = name
	holder.Size = UDim2.fromOffset(COLUMN_W, COLUMNS_H)
	holder.Position = UDim2.fromOffset(x, 0)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	Theme.text({
		name = "Heading",
		text = name,
		size = UDim2.fromOffset(150, 22),
		position = UDim2.fromOffset(2, 0),
		parent = holder,
		align = Enum.TextXAlignment.Left,
		color = tint,
		textSize = 16,
	})
	Theme.text({
		name = "Blurb",
		text = blurb,
		size = UDim2.fromOffset(COLUMN_W - 90, 22),
		position = UDim2.fromOffset(84, 1),
		parent = holder,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.label,
		textSize = 15,
		bold = false,
	})

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Size = UDim2.fromOffset(COLUMN_W, COLUMNS_H - LIST_TOP)
	list.Position = UDim2.fromOffset(0, LIST_TOP)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = BAR
	list.ScrollBarImageColor3 = INK
	list.ScrollBarImageTransparency = 0.2
	list.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = holder

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = list

	return list
end

--[[
	The flagship, given the room the rest of the list is not.

	`docs/MONETIZATION.md` calls the two-minute zero-turn the impulse buy the
	whole shop is built around, and a forty-six pixel row is not where an
	impulse happens. Purple, because it is the one thing here that is neither a
	pass nor an ordinary boost — it is the ride.
]]
local function addFeatured(def: Monetization.ProductDef)
	local slab = Theme.chunkPanel({
		name = "Featured",
		size = UDim2.fromOffset(INNER_W, FEATURE_H),
		position = UDim2.fromOffset(0, 0),
		parent = featureSlot,
		radius = 20,
		drop = 6,
		outline = 4,
		top = Color3.fromRGB(74, 59, 110),
		bottom = Color3.fromRGB(46, 36, 72),
	})

	well(slab, def.key, PASS_TINT, 104, UDim2.fromOffset(20, 16))
	-- The well is square; the handoff's is 132 wide, so the picture is given
	-- the extra width rather than cropped to a box.
	local tile = slab:FindFirstChild("Well")
	if tile and tile:IsA("Frame") then
		tile.Size = UDim2.fromOffset(132, 104)
	end

	local left = 172
	local priceW = 150
	local pill = Instance.new("Frame")
	pill.Name = "Popular"
	pill.Size = UDim2.fromOffset(148, 24)
	pill.Position = UDim2.fromOffset(left, 16)
	pill.BackgroundColor3 = Theme.colors.tips
	pill.BorderSizePixel = 0
	pill.Parent = slab
	Theme.corner(pill, Theme.PILL)
	Theme.stroke(pill, 2.5, INK, 0)
	Theme.text({
		name = "Text",
		text = "MOST POPULAR",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = pill,
		align = Enum.TextXAlignment.Center,
		color = INK,
		textSize = 13,
	})

	Theme.text({
		name = "Name",
		text = def.name,
		size = UDim2.fromOffset(INNER_W - left - priceW - 40, 36),
		position = UDim2.fromOffset(left, 47),
		parent = slab,
		align = Enum.TextXAlignment.Left,
		textSize = 30,
	})
	local blurb = Theme.text({
		name = "Blurb",
		text = def.description,
		size = UDim2.fromOffset(INNER_W - left - priceW - 40, 22),
		position = UDim2.fromOffset(left, 87),
		parent = slab,
		align = Enum.TextXAlignment.Left,
		color = Color3.fromRGB(205, 190, 234),
		textSize = 16,
		bold = false,
	})
	blurb.TextTruncate = Enum.TextTruncate.AtEnd

	local price = Theme.chunkButton({
		name = "Price",
		variant = "robuxRun",
		text = `R$ {Prices.robux(def.id, def.robux)}`,
		textSize = 24,
		size = UDim2.fromOffset(priceW, 62),
		position = UDim2.new(1, -20, 0.5, -3),
		anchor = Vector2.new(1, 0.5),
		parent = slab,
		radius = 16,
		drop = 5,
		outline = 4,
	})
	price.Activated:Connect(function()
		promptRemote:FireServer("product", def.key)
	end)
end

--------------------------------------------------------------------
-- Contents
--------------------------------------------------------------------

local function render()
	for _, list in { passList, boostList } do
		for _, child in list:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
	end
	for _, child in featureSlot:GetChildren() do
		child:Destroy()
	end

	local featured = Monetization.productByKey[FEATURED_KEY]
	local hasFeature = featured ~= nil and Monetization.isConfigured(featured.id)
	if featured and hasFeature then
		addFeatured(featured)
	end

	local order = 0
	for _, def in Monetization.passes do
		if Monetization.isConfigured(def.id) then
			order += 1
			addRow(
				passList,
				order,
				def.key,
				def.name,
				def.effect,
				Prices.robux(def.id, def.robux),
				true,
				function()
					promptRemote:FireServer("pass", def.key)
				end
			)
		end
	end

	local passCount = order
	order = 0
	for _, def in Monetization.products do
		local isTool = def.kind == "toolRun" or def.kind == "toolPermanent"
		-- The flagship is not listed twice; if its id is missing it drops back
		-- into the column it came from rather than disappearing from the shop.
		local isFeatured = hasFeature and def.key == FEATURED_KEY
		if not isTool and not isFeatured and Monetization.isConfigured(def.id) then
			order += 1
			addRow(
				boostList,
				order,
				def.key,
				def.name,
				def.effect,
				Prices.robux(def.id, def.robux),
				false,
				function()
					promptRemote:FireServer("product", def.key)
				end
			)
		end
	end

	emptyLabel.Visible = passCount == 0 and order == 0 and not hasFeature
end

--- The two lines on the strip that are not fixed facts about the game.
local function refreshRewards()
	local since = os.clock() - rewardsAt
	rentalLabel.Text = `Free rental in {Format.clock(math.max(rewards.nextRental - since, 0))}`
	streakLabel.Text = `Day {math.max(rewards.streak, 1)} of {rewards.streakOf} · +{rewards.streakTips} tips`
end

--------------------------------------------------------------------
-- Chrome
--------------------------------------------------------------------

--- A dark capsule with a diamond and a line of text. The header wears two.
local function headerChip(parent: Instance, name: string, width: number, x: number, dot: Color3): TextLabel
	local chip = Instance.new("TextButton")
	chip.Name = name
	chip.Size = UDim2.fromOffset(width, 44)
	chip.Position = UDim2.fromOffset(x, HEADER_H - 48)
	chip.BackgroundColor3 = TILE
	chip.BorderSizePixel = 0
	chip.AutoButtonColor = false
	chip.Text = ""
	chip.Parent = parent
	Theme.corner(chip, 14)
	Theme.stroke(chip, 3, INK, 0)

	local diamond = Instance.new("Frame")
	diamond.Name = "Dot"
	diamond.Size = UDim2.fromOffset(14, 14)
	diamond.Position = UDim2.fromOffset(18, 15)
	diamond.Rotation = 45
	diamond.BackgroundColor3 = dot
	diamond.BorderSizePixel = 0
	diamond.Parent = chip
	Theme.corner(diamond, 4)

	return Theme.text({
		name = "Text",
		text = "",
		size = UDim2.fromOffset(width - 50, 44),
		position = UDim2.fromOffset(41, 0),
		parent = chip,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.body,
		textSize = 16,
		bold = false,
	})
end

--- One of the three blocks along the free-rewards strip.
local function freeBlock(parent: Instance, x: number, width: number, heading: string, value: string): TextLabel
	local block = Instance.new("Frame")
	block.Name = heading
	block.Size = UDim2.fromOffset(width, 54)
	block.Position = UDim2.fromOffset(x, 12)
	block.BackgroundColor3 = TILE
	block.BorderSizePixel = 0
	block.Parent = parent
	Theme.corner(block, 11)

	Theme.text({
		name = "Heading",
		text = heading,
		size = UDim2.fromOffset(width - 26, 18),
		position = UDim2.fromOffset(13, 8),
		parent = block,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.label,
		textSize = 13,
	})
	return Theme.text({
		name = "Value",
		text = value,
		size = UDim2.fromOffset(width - 26, 22),
		position = UDim2.fromOffset(13, 26),
		parent = block,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.progress,
		textSize = 16,
	})
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MowStore"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 6
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")

	Theme.backdrop(gui)

	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.Size = UDim2.fromOffset(INNER_W, STAGE.Y - PAD_Y * 2)
	stage.Position = UDim2.fromScale(0.5, 0.5)
	stage.AnchorPoint = Vector2.new(0.5, 0.5)
	stage.BackgroundTransparency = 1
	stage.Parent = gui
	Theme.fitToViewport(stage, STAGE.X, STAGE.Y)

	----------------------------------------------------------------
	-- Header
	----------------------------------------------------------------
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.fromOffset(INNER_W, HEADER_H)
	header.Position = UDim2.fromOffset(0, 0)
	header.BackgroundTransparency = 1
	header.Parent = stage

	Theme.text({
		name = "Eyebrow",
		text = "THE STORE",
		size = UDim2.fromOffset(400, 20),
		position = UDim2.fromOffset(0, 0),
		parent = header,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.tips,
		textSize = 15,
	})
	--[[
		The one sentence on the screen that is not selling anything.

		It is the promise the free strip at the bottom keeps, said at the top
		where somebody arriving with a wallet open can read it first.
	]]
	Theme.text({
		name = "Headline",
		text = "All of it is optional.",
		size = UDim2.fromOffset(620, 46),
		position = UDim2.fromOffset(0, 23),
		parent = header,
		align = Enum.TextXAlignment.Left,
		textSize = 38,
	})

	local close = Theme.chunkButton({
		name = "Close",
		variant = "danger",
		size = UDim2.fromOffset(48, 48),
		position = UDim2.fromOffset(INNER_W - 48, HEADER_H - 50),
		parent = header,
		radius = 14,
		drop = 5,
		outline = 4,
	})
	-- Releases the first-person mouse lock while the store is open, so its
	-- rows can actually be clicked. See the note in Journal.
	close.Modal = true
	Theme.icon({
		name = "CloseIcon",
		prop = "Cross",
		size = UDim2.fromScale(0.6, 0.6),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = close,
	})
	close.Activated:Connect(function()
		Store.setOpen(false)
	end)

	local RENTAL_W, SHED_W = 216, 210
	rentalLabel = headerChip(
		header,
		"Rental",
		RENTAL_W,
		INNER_W - 48 - 10 - RENTAL_W,
		Theme.colors.grass
	)

	local shed = headerChip(
		header,
		"Shed",
		SHED_W,
		INNER_W - 48 - 10 - RENTAL_W - 10 - SHED_W,
		Theme.colors.tips
	)
	shed.Text = "Tools are in the shed"
	local shedButton = shed.Parent :: TextButton
	shedButton.Modal = true
	shedButton.Activated:Connect(function()
		Store.setOpen(false)
		Journal.openUpgrades()
	end)

	----------------------------------------------------------------
	-- Featured, then the two lists
	----------------------------------------------------------------
	featureSlot = Instance.new("Frame")
	featureSlot.Name = "FeatureSlot"
	featureSlot.Size = UDim2.fromOffset(INNER_W, FEATURE_H)
	featureSlot.Position = UDim2.fromOffset(0, HEADER_H + GAP)
	featureSlot.BackgroundTransparency = 1
	featureSlot.Parent = stage

	local columns = Instance.new("Frame")
	columns.Name = "Columns"
	columns.Size = UDim2.fromOffset(INNER_W, COLUMNS_H)
	columns.Position = UDim2.fromOffset(0, HEADER_H + GAP + FEATURE_H + GAP)
	columns.BackgroundTransparency = 1
	columns.Parent = stage

	passList = addColumn(columns, 0, "PASSES", PASS_TINT, "bought once, kept forever")
	boostList = addColumn(columns, COLUMN_W + 20, "BOOSTS", BOOST_TINT, "this run only, buy again")

	-- A fresh place with no ids pasted in has nothing to sell, which is the
	-- expected state of this file's first day rather than a fault. Say so
	-- plainly instead of showing two empty columns.
	emptyLabel = Theme.text({
		name = "Empty",
		text = "Nothing here yet — the shop opens once the products are set up.",
		size = UDim2.fromOffset(INNER_W, 40),
		position = UDim2.fromOffset(0, COLUMNS_H // 2 - 20),
		parent = columns,
		color = Theme.colors.label,
		align = Enum.TextXAlignment.Center,
		textSize = 16,
		bold = false,
	})

	----------------------------------------------------------------
	-- The free loops
	----------------------------------------------------------------
	local strip = Instance.new("Frame")
	strip.Name = "FreeRewards"
	strip.Size = UDim2.fromOffset(INNER_W, STRIP_H)
	strip.Position = UDim2.fromOffset(0, STAGE.Y - PAD_Y * 2 - STRIP_H)
	strip.BackgroundColor3 = Color3.fromRGB(30, 22, 16)
	strip.BorderSizePixel = 0
	strip.Parent = stage
	Theme.corner(strip, 16)
	Theme.stroke(strip, 3, INK, 0)

	Theme.text({
		name = "Always",
		text = "FREE, ALWAYS",
		size = UDim2.fromOffset(130, STRIP_H),
		position = UDim2.fromOffset(18, 0),
		parent = strip,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.cash,
		textSize = 15,
	})

	local blocksLeft = 146
	local blockW = (INNER_W - 18 - blocksLeft - 20) // 3
	local reward = Monetization.rewards
	streakLabel = freeBlock(strip, blocksLeft, blockW, "DAILY STREAK", "")
	freeBlock(
		strip,
		blocksLeft + blockW + 10,
		blockW,
		"PLAYTIME",
		`{reward.playtimeTips} tips every {reward.playtimeInterval // 60} minutes`
	)
	local rentalTool = Tools.get(reward.freeRentalToolId)
	freeBlock(
		strip,
		blocksLeft + (blockW + 10) * 2,
		blockW,
		"FREE RENTAL",
		`{if rentalTool then rentalTool.name else "A mower"}, every {reward.freeRentalInterval // 60} min`
	)

	refreshRewards()
end

function Store.setOpen(open: boolean)
	if open == isOpen then
		return
	end
	isOpen = open
	gui.Enabled = open
	Theme.holdCursor(open)
	if open then
		render()
		refreshRewards()
	end
end

function Store.toggle()
	Store.setOpen(not isOpen)
end

function Store.isOpen(): boolean
	return isOpen
end

function Store.start()
	promptRemote = Remotes.event(Remotes.PROMPT_PURCHASE)
	build()
	render()

	Remotes.event(Remotes.REWARDS).OnClientEvent:Connect(function(state: Rewards)
		rewards = state
		rewardsAt = os.clock()
		if isOpen then
			refreshRewards()
		end
	end)

	--- The chip is a countdown, so it moves while the screen is up and rests
	--- while it is not.
	Loop.forever("Store.rewards", function()
		task.wait(1)
		if isOpen then
			refreshRewards()
		end
	end)

	--[[
		Redraw if a price lands while the store is already open.

		Opening it renders, so almost every player sees live prices without
		this. The exception is the first player on a new server, who can have
		the store open before the server has finished asking Roblox what
		anything costs — about ten seconds — and would otherwise sit looking at
		the configured prices with no reason to close and reopen.
	]]
	Prices.onChanged(function()
		if isOpen then
			render()
		end
	end)
end

return Store
