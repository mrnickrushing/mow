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
local Worlds = require(Shared.Config.Worlds)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Types = require(Shared.Types)
local ToolUpgrades = require(Shared.Config.ToolUpgrades)
local Monetization = require(Shared.Config.Monetization)
local Upgrades = require(Shared.Config.Upgrades)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Store = require(script.Parent.Store)
local Theme = require(script.Parent.Theme)
local Props = require(Shared.Config.Props)

local Journal = {}

local player = Players.LocalPlayer
local purchaseRemote: RemoteEvent
local questRemote: RemoteEvent

local gui: ScreenGui
local upgradeBadge: Frame? = nil
local leftPage: Frame
local rightPage: Frame
local moneyLabel: TextLabel
local tabButtons: { [string]: TextButton } = {}
local activeTab = "objectives"
local isOpen = false
local questState: { any } = {}

local PAPER = Color3.fromRGB(246, 236, 210)
local PAPER_EDGE = Color3.fromRGB(222, 206, 172)
local INK = Color3.fromRGB(58, 46, 96)
local COVER = Color3.fromRGB(58, 118, 186)
local LOCKED = Color3.fromRGB(158, 154, 148)
--- A brighter, opaque card on the parchment page it sits on.
local CARD = Color3.fromRGB(255, 252, 241)

--[[
	The tabs, in the order a player needs them.

	"Upgrades" used to mean the per-tool trees and nothing else, which left the
	bag — the first and most important thing anybody buys — with no tab at all.
	The word now sits on the page that actually sells the bag, and the tool
	trees are "Tools", which is what they were always about.
]]
local TABS = {
	{ id = "objectives", label = "Journal", icon = "Scroll", color = Color3.fromRGB(226, 198, 150) },
	{ id = "stats", label = "Upgrades", icon = "Sack", color = Color3.fromRGB(178, 214, 168) },
	{ id = "upgrades", label = "Tools", icon = "Toolbox", color = Color3.fromRGB(190, 210, 226) },
	{ id = "collection", label = "Collection", icon = "LeafMaple", color = Color3.fromRGB(232, 196, 156) },
	{ id = "tips", label = "Tips", icon = "QuestionSign", color = Color3.fromRGB(200, 200, 216) },
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
	label.Size = UDim2.new(1, -24, 0, 40)
	label.Position = UDim2.fromOffset(12, 8)
	label.BackgroundTransparency = 1
	label.Font = Theme.font
	label.TextColor3 = INK
	label.TextSize = 30
	label.TextXAlignment = Enum.TextXAlignment.Center
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
	Theme.corner(row, 8)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = INK
	stroke.Transparency = 0.75
	stroke.Parent = row
	return row
end

--- A scrolling body area under the heading.
local function body(page: Frame): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Body"
	scroll.Size = UDim2.new(1, -20, 1, -60)
	scroll.Position = UDim2.fromOffset(10, 52)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = PAPER_EDGE
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = page

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
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
		local row = card(scroll, 54)
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
		box.Size = UDim2.fromOffset(24, 24)
		box.Position = UDim2.fromOffset(10, 15)
		box.BackgroundColor3 = if entry.done then Color3.fromRGB(126, 186, 108) else Color3.fromRGB(255, 255, 255)
		box.BorderSizePixel = 0
		box.Parent = row
		Theme.corner(box, 5)
		local boxStroke = Instance.new("UIStroke")
		boxStroke.Thickness = 2
		boxStroke.Color = INK
		boxStroke.Transparency = 0.4
		boxStroke.Parent = box

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
		title.Size = UDim2.new(1, -50, 0, 26)
		title.Position = UDim2.fromOffset(46, 13)
		title.BackgroundTransparency = 1
		title.Font = Theme.font
		title.TextColor3 = if entry.done then LOCKED else Color3.fromRGB(48, 40, 32)
		title.TextSize = 20
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.Parent = row

		local progress = Instance.new("TextLabel")
		-- Read back out of `questState` by position rather than closing over
		-- `entry`: a quest push replaces the whole table, so the row this was
		-- built from is a stale copy the moment the next snapshot lands.
		local slot = order
		live(function()
			local current = questState[slot]
			if current then
				progress.Text = `({Format.count(current.progress)}/{Format.count(current.target)})`
			end
		end)
		progress.Size = UDim2.new(1, -50, 0, 22)
		progress.Position = UDim2.fromOffset(46, 33)
		progress.BackgroundTransparency = 1
		progress.Font = Theme.fontRegular
		progress.TextColor3 = LOCKED
		progress.TextSize = 17
		progress.TextXAlignment = Enum.TextXAlignment.Left
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

		local name = Instance.new("TextLabel")
		name.Text = if subject then subject.DisplayName else `Player {order}`
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

--------------------------------------------------------------------
-- Upgrades: every tool's own three slots
--------------------------------------------------------------------

--- The upgrade the player has clicked, as its `toolId/slot` key.
local selectedKey: string? = nil

--- A row of leaf pips over a card: one leaf per possible level, the earned
--- ones in autumn orange and the rest in pale outline. Reading your level as
--- leaves instead of a number is pure flavour, and exactly the flavour the
--- book is for.
local function pips(parent: Instance, level: number, maxLevel: number)
	local row = Instance.new("Frame")
	row.Name = "Pips"
	row.Size = UDim2.new(1, 0, 0, 16)
	row.Position = UDim2.fromOffset(0, 22)
	row.BackgroundTransparency = 1
	row.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 1)
	layout.Parent = row

	for index = 1, maxLevel do
		local pip = Theme.icon({
			name = "Pip",
			prop = "LeafOak",
			size = UDim2.fromOffset(15, 15),
			position = UDim2.fromScale(0, 0),
			parent = row,
		})
		pip.ImageTransparency = if index <= level then 0 else 0.75
		pip.LayoutOrder = index
		pip.Parent = row
	end
end

--[[
	One upgrade card: name over pips over an icon tile over a price.

	Cards for a tool the player does not own draw as three padlocks with
	question marks — the tree exists, but what it teaches is the tool's secret
	until the tool is bought.
]]
local function slotCard(parent: Instance, order: number, slot: any, owned: boolean, level: number)
	local card = Instance.new("TextButton")
	card.Name = if owned then slot.key else "Locked"
	card.Size = UDim2.fromOffset(92, 132)
	card.BackgroundTransparency = 1
	card.Text = ""
	card.LayoutOrder = order
	card.AutoButtonColor = owned
	card.Parent = parent

	local name = Instance.new("TextLabel")
	name.Text = if owned then slot.name else "???"
	name.Size = UDim2.new(1, 0, 0, 22)
	name.BackgroundTransparency = 1
	name.Font = Theme.font
	name.TextColor3 = Color3.fromRGB(52, 44, 36)
	name.TextSize = 17
	name.Parent = card

	if owned then
		pips(card, level, slot.maxLevel)
	end

	local tile = Instance.new("Frame")
	tile.Size = UDim2.fromOffset(72, 66)
	tile.Position = UDim2.new(0.5, 0, 0, 40)
	tile.AnchorPoint = Vector2.new(0.5, 0)
	tile.BackgroundColor3 = if owned then Color3.fromRGB(214, 210, 200) else Color3.fromRGB(96, 92, 88)
	tile.BorderSizePixel = 0
	tile.Parent = card
	Theme.corner(tile, 9)

	local tileStroke = Instance.new("UIStroke")
	tileStroke.Thickness = 2
	tileStroke.Color = INK
	tileStroke.Transparency = if selectedKey == slot.key and owned then 0 else 0.65
	tileStroke.Parent = tile

	Theme.icon({
		name = "Icon",
		prop = if owned then Props.forToolCategory(slot.category) else "Padlock",
		size = UDim2.fromScale(0.82, 0.82),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = tile,
	})

	local cost = ToolUpgrades.costAt(slot, level)
	local price = Instance.new("TextLabel")
	price.Name = "Price"
	price.Text = if not owned then "?" elseif cost then `{string.format("%.2f", cost)}$` else "MAX"
	price.Size = UDim2.new(1, 0, 0, 22)
	price.Position = UDim2.new(0, 0, 0, 108)
	price.BackgroundTransparency = 1
	price.Font = Theme.font
	price.TextColor3 = if not owned
		then LOCKED
		elseif cost then Color3.fromRGB(150, 106, 30)
		else Color3.fromRGB(126, 158, 78)
	price.TextSize = 17
	price.Parent = card

	if owned then
		card.Activated:Connect(function()
			selectedKey = slot.key
			Journal.refresh()
		end)
	end
end

--- A tool's panel: its name in ink over its three cards in a sketched frame.
local function toolPanel(parent: Instance, order: number, tool: Types.ToolDef, owned: boolean)
	local holder = Instance.new("Frame")
	holder.Name = tool.id
	holder.Size = UDim2.new(1, -8, 0, 208)
	holder.BackgroundTransparency = 1
	holder.LayoutOrder = order
	holder.Parent = parent

	local title = Instance.new("TextLabel")
	title.Text = tool.name:upper()
	title.Size = UDim2.new(1, 0, 0, 34)
	title.BackgroundTransparency = 1
	title.Font = Theme.font
	title.TextColor3 = INK
	title.TextSize = 27
	title.Parent = holder

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, -4, 0, 152)
	frame.Position = UDim2.fromOffset(2, 38)
	frame.BackgroundColor3 = PAPER
	frame.BackgroundTransparency = 0.5
	frame.BorderSizePixel = 0
	frame.Parent = holder
	Theme.corner(frame, 6)

	-- The sketched corner-mark border of a scrapbook photo mount.
	local frameStroke = Instance.new("UIStroke")
	frameStroke.Thickness = 1.5
	frameStroke.Color = INK
	frameStroke.Transparency = 0.55
	frameStroke.Parent = frame

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -12, 1, -12)
	row.Position = UDim2.fromOffset(6, 6)
	row.BackgroundTransparency = 1
	row.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = row

	local state = PlayerState.get()
	for index, slot in ToolUpgrades.treeFor(tool.id) do
		slotCard(row, index, slot, owned, state.upgrades[slot.key] or 0)
	end

	--[[
		What the page can sell you, and where it puts it.

		Two offers, because a tool has two prices that mean different things:
		cash buys it for this run, tips buy it for every run after. They share
		one row so the panel keeps its height — centred when only one applies,
		side by side when both do.
	]]
	local tipsPrice = tool.tipsPermanent
	local sellsForCash = not owned and tool.cost > 0
	local sellsForTips = tipsPrice ~= nil and not state.permanentTools[tool.id]

	local function offer(text: string, x: number, width: number, affordable: () -> boolean, onBuy: () -> ())
		local buy = Instance.new("TextButton")
		buy.Text = text
		buy.Size = UDim2.fromOffset(width, 26)
		buy.Position = UDim2.new(0.5, x, 0, 182)
		buy.AnchorPoint = Vector2.new(0.5, 0)
		live(function()
			buy.BackgroundColor3 = if affordable()
				then Color3.fromRGB(126, 158, 78)
				else Color3.fromRGB(196, 190, 178)
		end)
		buy.BorderSizePixel = 0
		buy.Font = Theme.font
		buy.TextColor3 = Color3.fromRGB(250, 244, 228)
		buy.TextSize = 16
		buy.Parent = holder
		Theme.corner(buy, 7)
		buy.Activated:Connect(onBuy)
	end

	local both = sellsForCash and sellsForTips
	local width = if both then 148 else 172

	if sellsForCash then
		offer(
			`Buy — {Format.cash(tool.cost)}`,
			if both then -76 else 0,
			width,
			function()
				return PlayerState.get().cash >= tool.cost
			end,
			function()
				purchaseRemote:FireServer("tool", tool.id)
			end
		)
	end

	if sellsForTips then
		local price = tipsPrice :: number
		offer(
			`Keep it — {Format.count(price)} tips`,
			if both then 76 else 0,
			width,
			function()
				return PlayerState.get().tips >= price
			end,
			function()
				purchaseRemote:FireServer("permanent", tool.id)
			end
		)
	end
end

--- The three tools the spread shows: what is in your hands, then the next
--- two rungs of the ladder — the thing you have, and what it could become.
local function panelTools(): { Types.ToolDef }
	local state = PlayerState.get()
	local out: { Types.ToolDef } = {}
	local seen: { [string]: boolean } = {}

	local equipped = if state.equippedTool ~= "" then Tools.get(state.equippedTool) else nil
	if equipped then
		table.insert(out, equipped)
		seen[equipped.id] = true
	end

	-- Owned tools first, cheapest unowned after, until three panels stand.
	for _, tool in Tools.list do
		if #out >= 3 then
			break
		end
		if not seen[tool.id] and state.ownedTools[tool.id] then
			table.insert(out, tool)
			seen[tool.id] = true
		end
	end
	for _, tool in Tools.list do
		if #out >= 3 then
			break
		end
		if not seen[tool.id] and tool.currency == "Cash" then
			table.insert(out, tool)
			seen[tool.id] = true
		end
	end

	return out
end

local function renderUpgrades()
	local state = PlayerState.get()
	local shown = panelTools()

	-- Left page: the tool in hand, then the chooser and the BUY button.
	local left = body(leftPage)
	if shown[1] then
		toolPanel(left, 1, shown[1], state.ownedTools[shown[1].id] == true)
	end

	-- The detail panel: what the selected upgrade does, or the standing
	-- instruction when nothing is picked yet.
	local detail = Instance.new("Frame")
	detail.Size = UDim2.new(1, -16, 0, 96)
	detail.BackgroundColor3 = Color3.fromRGB(178, 176, 190)
	detail.BackgroundTransparency = 0.2
	detail.BorderSizePixel = 0
	detail.LayoutOrder = 2
	detail.Parent = left
	Theme.corner(detail, 14)

	local selectedSlot, selectedTool = nil, nil
	if selectedKey then
		selectedSlot, selectedTool = ToolUpgrades.slotByKey(selectedKey)
	end

	local detailText = Instance.new("TextLabel")
	detailText.Size = UDim2.new(1, -20, 1, -10)
	detailText.Position = UDim2.fromOffset(10, 5)
	detailText.BackgroundTransparency = 1
	detailText.Font = Theme.font
	detailText.TextColor3 = Color3.fromRGB(250, 246, 238)
	detailText.TextSize = 20
	detailText.TextWrapped = true
	detailText.Parent = detail
	Theme.outline(detailText, 2)

	local selectedCost: number? = nil
	if selectedSlot and selectedTool then
		local level = state.upgrades[selectedSlot.key] or 0
		selectedCost = ToolUpgrades.costAt(selectedSlot, level)
		detailText.Text = `{selectedTool.name} — {selectedSlot.name}\n{selectedSlot.description}`
	else
		detailText.Text = "Select an upgrade!"
	end

	local buyButton = Instance.new("TextButton")
	buyButton.Text = if selectedCost then `BUY  —  {string.format("%.2f", selectedCost :: number)}$` else "BUY"
	buyButton.Size = UDim2.new(0.8, 0, 0, 48)
	-- Green the instant the money lands, without the page being rebuilt under
	-- the cursor to do it.
	live(function()
		local cost = selectedCost
		buyButton.BackgroundColor3 = if cost and PlayerState.get().cash >= cost
			then Color3.fromRGB(126, 158, 78)
			else Color3.fromRGB(196, 190, 178)
	end)
	buyButton.BorderSizePixel = 0
	buyButton.Font = Theme.font
	buyButton.TextColor3 = Color3.fromRGB(250, 246, 238)
	buyButton.TextSize = 26
	buyButton.LayoutOrder = 3
	buyButton.Parent = left
	Theme.corner(buyButton, 12)
	Theme.outline(buyButton, 2)

	-- Connected whether or not the money is there yet. Wiring this only when
	-- the price was already met left a button that stayed dead after the cash
	-- arrived, because the page no longer rebuilds itself to notice. The server
	-- is the one that decides, and it says no politely.
	if selectedKey then
		local key = selectedKey :: string
		buyButton.Activated:Connect(function()
			purchaseRemote:FireServer("toolUpgrade", key)
		end)
	end

	-- Right page: the next two rungs of the ladder.
	local right = body(rightPage)
	for index = 2, 3 do
		local tool = shown[index]
		if tool then
			toolPanel(right, index, tool, state.ownedTools[tool.id] == true)
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
		local row = Instance.new("Frame")
		row.Name = def.id
		row.Size = UDim2.new(1, -12, 0, 80)
		row.BackgroundColor3 = PAPER
		row.BackgroundTransparency = 0.45
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		row.Parent = scroll
		Theme.corner(row, 8)

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.5
		stroke.Color = INK
		stroke.Transparency = 0.6
		stroke.Parent = row

		local name = Instance.new("TextLabel")
		name.Text = def.name:upper()
		name.Size = UDim2.new(1, -130, 0, 24)
		name.Position = UDim2.fromOffset(12, 6)
		name.BackgroundTransparency = 1
		name.Font = Theme.font
		name.TextColor3 = INK
		name.TextSize = 21
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Parent = row

		local blurb = Instance.new("TextLabel")
		blurb.Text = def.description
		blurb.Size = UDim2.new(1, -130, 0, 30)
		blurb.Position = UDim2.fromOffset(12, 28)
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
		local change = Instance.new("TextLabel")
		change.Size = UDim2.new(1, -130, 0, 22)
		change.Position = UDim2.fromOffset(12, 56)
		change.BackgroundTransparency = 1
		change.Font = Theme.font
		change.TextColor3 = Color3.fromRGB(150, 106, 30)
		change.TextSize = 16
		change.TextXAlignment = Enum.TextXAlignment.Left
		change.Parent = row

		local buy = Instance.new("TextButton")
		buy.Name = "Buy"
		buy.Size = UDim2.fromOffset(104, 44)
		buy.Position = UDim2.new(1, -12, 0.5, 0)
		buy.AnchorPoint = Vector2.new(1, 0.5)
		buy.BorderSizePixel = 0
		buy.Font = Theme.font
		buy.TextColor3 = Color3.fromRGB(250, 246, 238)
		buy.TextSize = 17
		buy.AutoButtonColor = true
		buy.Parent = row
		Theme.corner(buy, 8)
		Theme.outline(buy, 2)

		live(function()
			local state = PlayerState.get()
			local level = state.upgrades[def.id] or 0
			local cost = Upgrades.costAt(def, level)

			if not cost then
				change.Text = `{Format.stat(Upgrades.valueAt(def, level))}{def.suffix} — the top of the line`
				buy.Text = "MAX"
				buy.BackgroundColor3 = Color3.fromRGB(178, 172, 160)
				return
			end

			local now = Upgrades.valueAt(def, level)
			local next_ = Upgrades.valueAt(def, level + 1)
			change.Text = `Lv {level}   {Format.stat(now)} --> {Format.stat(next_)}{def.suffix}`
			buy.Text = Format.cash(cost)
			buy.BackgroundColor3 = if state.cash >= cost
				then Color3.fromRGB(126, 158, 78)
				else Color3.fromRGB(196, 190, 178)
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
		label.Size = UDim2.new(0.4, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Font = Theme.font
		label.TextColor3 = INK
		label.TextSize = 19
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = row

		local value = Instance.new("TextLabel")
		value.Size = UDim2.new(0.6, -12, 1, 0)
		value.Position = UDim2.new(1, 0, 0, 0)
		value.AnchorPoint = Vector2.new(1, 0)
		value.BackgroundTransparency = 1
		value.Font = Theme.fontRegular
		value.TextColor3 = Color3.fromRGB(52, 44, 36)
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
	note.TextColor3 = LOCKED
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

local function renderCollection()
	heading(leftPage, "Zones")
	local scroll = body(leftPage)

	local world = PlayerState.world()
	if world then
		for order, section in world.sections do
			local owned = PlayerState.isSectionOpen(section.id)
			local kind = Worlds.unlockKind(section)

			local row = card(scroll, 44)
			row.LayoutOrder = order

			local name = Instance.new("TextLabel")
			name.Text = if owned then section.name else `    {section.name}`
			if not owned then
				Theme.icon({
					name = "Lock",
					prop = "Padlock",
					size = UDim2.fromOffset(22, 22),
					position = UDim2.fromOffset(10, 11),
					parent = row,
				})
			end
			name.Position = UDim2.fromOffset(10, 0)
			name.Size = UDim2.new(1, -110, 1, 0)
			name.BackgroundTransparency = 1
			name.Font = Theme.font
			name.TextColor3 = if owned then Color3.fromRGB(52, 44, 36) else LOCKED
			name.TextSize = 19
			name.TextXAlignment = Enum.TextXAlignment.Left
			name.Parent = row

			if owned then
				Theme.icon({
					name = "Done",
					prop = "Tick",
					size = UDim2.fromOffset(24, 24),
					position = UDim2.new(1, -40, 0, 10),
					parent = row,
				})
			end

			local how = Instance.new("TextLabel")
			how.Text = if owned
				then ""
				elseif kind == "completion" then "clear first"
				elseif kind == "button" then "find switch"
				else Format.cash(section.cost)
			how.Size = UDim2.new(0, 96, 1, 0)
			how.Position = UDim2.new(1, -10, 0, 0)
			how.AnchorPoint = Vector2.new(1, 0)
			how.BackgroundTransparency = 1
			how.Font = Theme.fontRegular
			how.TextColor3 = LOCKED
			how.TextSize = 16
			how.TextXAlignment = Enum.TextXAlignment.Right
			how.Parent = row
		end
	end

	heading(rightPage, "Records")
	local right = body(rightPage)
	-- One card holding all three, because these are facts about the same run
	-- rather than a list of separate choices — a list of cards read as three
	-- unrelated things instead of one summary.
	local panel = card(right, 34 * 3 + 24)
	panel.LayoutOrder = 1

	-- Written out of the state each time rather than baked into a string, so
	-- the records keep counting while the page stays still.
	local lines: { (PlayerState.State) -> string } = {
		function(mine)
			return `Earned this run: {Format.cash(mine.earned)}`
		end,
		function(mine)
			return `Tips banked: {Format.count(mine.tips)}`
		end,
		function(mine)
			return `Bag capacity: {Format.count(mine.bagCapacity)}`
		end,
	}
	for order, line in lines do
		local label = Instance.new("TextLabel")
		live(function()
			label.Text = line(PlayerState.get())
		end)
		label.Size = UDim2.new(1, -24, 0, 34)
		label.Position = UDim2.fromOffset(12, 12 + (order - 1) * 34)
		label.BackgroundTransparency = 1
		label.Font = Theme.fontRegular
		label.TextColor3 = Color3.fromRGB(52, 44, 36)
		label.TextSize = 18
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = panel
	end
end

local function renderTips()
	heading(leftPage, "Tips")
	local scroll = body(leftPage)

	local tips = {
		"Hold to work. Your deck cuts a swath as wide as the tool.",
		"The bag is the bottleneck early. Buy it on the Upgrades tab, first.",
		"Walk into the trailer to sell — there is no button to press.",
		"Grass too thick for your tool will bog it down. That means buy better.",
		"Cut in long straight lines to bank a Clean Stripe bonus.",
		"Some sections are not for sale. Clear a yard, or find the switch.",
	}
	for order, tip in tips do
		local label = Instance.new("TextLabel")
		label.Text = `• {tip}`
		label.Size = UDim2.new(1, -12, 0, 56)
		label.BackgroundTransparency = 1
		label.Font = Theme.fontRegular
		label.TextColor3 = Color3.fromRGB(52, 44, 36)
		label.TextSize = 17
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.TextWrapped = true
		label.LayoutOrder = order
		label.Parent = scroll
	end

	heading(rightPage, "Controls")
	local right = body(rightPage)
	-- What the keys actually do. This list used to promise that B opened "the
	-- shed", which it never did — B and TAB are bound to the same action, and
	-- both open this book.
	local controls = {
		"Hold left mouse or E — work",
		"TAB or B — open this journal",
		"G — the Robux store",
		"F — mount a riding mower",
		"",
		"Upgrades and tools are bought in this book,",
		"or at the boards outside the shed.",
	}
	for order, line in controls do
		local label = Instance.new("TextLabel")
		label.Text = line
		label.Size = UDim2.new(1, -12, 0, 34)
		label.BackgroundTransparency = 1
		label.Font = Theme.fontRegular
		label.TextColor3 = Color3.fromRGB(52, 44, 36)
		label.TextSize = 18
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.LayoutOrder = order
		label.Parent = right
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
	local parts = { activeTab, state.equippedTool, selectedKey or "-", tostring(state.hasPortableTrailer) }

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

	moneyLabel.Text = `your money :  {Format.cash(PlayerState.get().cash)}    `

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

local function setTab(id: string)
	activeTab = id
	for tabId, button in tabButtons do
		local selected = tabId == id
		button.TextColor3 = if selected then INK else Color3.fromRGB(120, 104, 84)
		button.Size = if selected then UDim2.fromOffset(196, 46) else UDim2.fromOffset(176, 44)
	end
	render()
end

local function buildTab(parent: Instance, order: number, tab: { id: string, label: string, icon: string, color: Color3 })
	local button = Instance.new("TextButton")
	button.Name = tab.id
	button.Size = UDim2.fromOffset(176, 44)
	button.Position = UDim2.fromOffset(0, (order - 1) * 56)
	button.BackgroundColor3 = tab.color
	button.BorderSizePixel = 0
	-- The label alone. `tab.icon` names a model, and a model goes in a viewport
	-- beside the words rather than into them — printed into the text it read as
	-- "Scroll Journal", which is the catalogue talking to the player.
	button.Text = tab.label
	button.Font = Theme.font
	button.TextColor3 = Color3.fromRGB(120, 104, 84)
	button.TextSize = 20
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.AutoButtonColor = false
	button.Parent = parent

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 46)
	padding.Parent = button

	--[[
		The tab's model sits beside its word.

		It hangs off the tab column rather than off the button, because the
		padding that indents the label indents everything inside the button
		with it — put in there, the icon lands underneath its own text.
	]]
	Theme.icon({
		name = `TabIcon{tab.id}`,
		prop = tab.icon,
		size = UDim2.fromOffset(32, 32),
		position = UDim2.fromOffset(10, (order - 1) * 56 + 6),
		parent = parent,
		zIndex = 4,
	})

	-- Square off the right edge so the tab reads as tucked into the spine.
	Theme.corner(button, 8)
	local mask = Instance.new("Frame")
	mask.Size = UDim2.fromOffset(14, 44)
	mask.Position = UDim2.new(1, -14, 0, 0)
	mask.BackgroundColor3 = tab.color
	mask.BorderSizePixel = 0
	mask.ZIndex = button.ZIndex
	mask.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(146, 124, 96)
	stroke.Transparency = 0.4
	stroke.Parent = button

	button.Activated:Connect(function()
		setTab(tab.id)
	end)
	tabButtons[tab.id] = button
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
	shade.BackgroundTransparency = 0.5
	shade.BorderSizePixel = 0
	shade.Parent = gui

	-- The cover: a coloured border the pages sit inside.
	local book = Instance.new("Frame")
	book.Name = "Book"
	book.Size = UDim2.fromOffset(940, 560)
	book.Position = UDim2.fromScale(0.5, 0.52)
	book.AnchorPoint = Vector2.new(0.5, 0.5)
	book.BackgroundColor3 = COVER
	book.BorderSizePixel = 0
	book.Parent = gui
	Theme.corner(book, 14)

	-- The tab strip hangs 164 pixels off the book's left edge, so the room the
	-- journal really needs is wider than the book itself.
	Theme.fitToViewport(book, 940 + 220, 560 + 60)

	local spread = Instance.new("Frame")
	spread.Name = "Pages"
	spread.Size = UDim2.new(1, -24, 1, -24)
	spread.Position = UDim2.fromOffset(12, 12)
	spread.BackgroundColor3 = PAPER
	spread.BorderSizePixel = 0
	spread.Parent = book
	Theme.corner(spread, 8)

	-- The spine shadow down the middle is what sells it as one open book
	-- rather than two panels side by side.
	local spine = Instance.new("Frame")
	spine.Size = UDim2.new(0, 16, 1, -20)
	spine.Position = UDim2.new(0.5, 0, 0, 10)
	spine.AnchorPoint = Vector2.new(0.5, 0)
	spine.BackgroundColor3 = PAPER_EDGE
	spine.BackgroundTransparency = 0.25
	spine.BorderSizePixel = 0
	spine.Parent = spread

	leftPage = Instance.new("Frame")
	leftPage.Name = "Left"
	leftPage.Size = UDim2.new(0.5, -22, 1, -50)
	leftPage.Position = UDim2.fromOffset(14, 10)
	leftPage.BackgroundTransparency = 1
	leftPage.Parent = spread

	rightPage = Instance.new("Frame")
	rightPage.Name = "Right"
	rightPage.Size = UDim2.new(0.5, -22, 1, -50)
	rightPage.Position = UDim2.new(0.5, 8, 0, 10)
	rightPage.BackgroundTransparency = 1
	rightPage.Parent = spread

	moneyLabel = Instance.new("TextLabel")
	moneyLabel.Name = "Money"
	moneyLabel.Text = "your money :  $0.00"
	moneyLabel.Size = UDim2.new(0.5, -30, 0, 32)
	moneyLabel.Position = UDim2.new(1, -18, 1, -14)
	moneyLabel.AnchorPoint = Vector2.new(1, 1)
	moneyLabel.BackgroundTransparency = 1
	moneyLabel.Font = Theme.font
	moneyLabel.TextColor3 = Color3.fromRGB(90, 70, 40)
	moneyLabel.TextSize = 21
	moneyLabel.TextXAlignment = Enum.TextXAlignment.Right
	moneyLabel.Parent = spread

	-- Tabs hang off the left edge, behind the cover.
	local rail = Instance.new("Frame")
	rail.Name = "Tabs"
	rail.Size = UDim2.fromOffset(180, #TABS * 56 + 80)
	rail.Position = UDim2.new(0, -164, 0, 60)
	rail.BackgroundTransparency = 1
	rail.ZIndex = 0
	rail.Parent = book
	for order, tab in TABS do
		buildTab(rail, order, tab)
	end

	-- The red ! on the Upgrades tab: something in the book is affordable right
	-- now. Same signal the HUD's journal icon carries, for the same reason —
	-- the moment a purchase comes into reach is invisible unless something says.
	local badge = Instance.new("Frame")
	badge.Name = "UpgradeBadge"
	badge.Size = UDim2.fromOffset(24, 24)
	badge.Position = UDim2.fromOffset(158, 48)
	badge.BackgroundColor3 = Theme.colors.danger
	badge.BorderSizePixel = 0
	badge.Visible = false
	badge.ZIndex = 3
	badge.Parent = rail
	upgradeBadge = badge

	local badgeRound = Instance.new("UICorner")
	badgeRound.CornerRadius = UDim.new(0.5, 0)
	badgeRound.Parent = badge
	Theme.stroke(badge, 2.5, Theme.colors.outline, 0.05)

	local bang = Instance.new("TextLabel")
	bang.Text = "!"
	bang.Size = UDim2.fromScale(1, 1)
	bang.BackgroundTransparency = 1
	bang.Font = Theme.font
	bang.TextColor3 = Theme.colors.text
	bang.TextSize = 17
	bang.ZIndex = 3
	bang.Parent = badge

	--[[
		The Robux quick-buy hanging under the tabs.

		Its price used to be the string "180", which matched no pass in the
		catalogue at any point — and it was shown even on a place where none of
		the passes have been created yet, so pressing it opened a store that
		said "nothing here yet". A button advertising a price for a thing that
		cannot be bought is worse than no button, so it now names the cheapest
		pass that actually exists and hides itself when none do.
	]]
	local cheapest: Monetization.PassDef? = nil
	for _, def in Monetization.passes do
		if Monetization.isConfigured(def.id) and (cheapest == nil or def.robux < cheapest.robux) then
			cheapest = def
		end
	end

	local quick = Instance.new("TextButton")
	quick.Name = "RobuxQuick"
	quick.Size = UDim2.fromOffset(120, 56)
	-- Below the last tab, wherever the last tab now ends: the tabs are laid out
	-- 56 apart from the top of the rail, and this sat at a hardcoded 208 that
	-- was one row short the moment a fifth tab was added.
	quick.Position = UDim2.fromOffset(24, #TABS * 56 + 12)
	quick.BackgroundTransparency = 1
	-- The Robux mark stays a character: it is Roblox's, not ours to redraw.
	quick.Text = if cheapest then `\n\n⬡ {cheapest.robux}` else ""
	quick.Visible = cheapest ~= nil
	quick.Font = Theme.font
	quick.TextColor3 = Theme.colors.cash
	quick.TextSize = 20
	quick.ZIndex = 0
	quick.Parent = rail
	Theme.outline(quick, 2.5)
	Theme.icon({
		name = "QuickIcon",
		prop = "LeafBlower",
		size = UDim2.fromOffset(40, 30),
		position = UDim2.new(0.5, 0, 0, 2),
		anchor = Vector2.new(0.5, 0),
		parent = quick,
	})

	quick.Activated:Connect(function()
		Store.toggle()
	end)

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.Size = UDim2.fromOffset(56, 56)
	-- Tucked inside the cover rather than overhanging its top-right corner:
	-- overhung, it was the first thing to leave the screen on a short viewport,
	-- which left the journal with no visible way to shut it.
	close.Position = UDim2.new(1, -14, 0, 14)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Text = ""
	Theme.icon({
		name = "CloseIcon",
		prop = "Cross",
		size = UDim2.fromScale(0.6, 0.6),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = close,
	})
	close.BackgroundColor3 = Color3.fromRGB(214, 72, 60)
	close.TextColor3 = Color3.fromRGB(255, 246, 240)
	close.BorderSizePixel = 0
	--[[
		Modal is what gives the journal a usable mouse.

		The camera is locked to first person, which pins the cursor to the
		centre of the screen — so every control in here, the tabs, the tool Buy
		buttons and this button itself, sat somewhere the cursor could never
		reach. Tools are only ever bought from this panel, so on a desktop the
		whole sixteen-tool ladder was unreachable and the run ended at bare
		hands. A visible modal button releases the mouse for as long as the
		panel is open, and re-locks it the moment the panel closes.
	]]
	close.Modal = true
	close.Parent = book
	Theme.corner(close, 10)
	Theme.outline(close, 3)
	local closeStroke = Instance.new("UIStroke")
	closeStroke.Thickness = 3
	closeStroke.Color = Color3.fromRGB(122, 34, 28)
	closeStroke.Parent = close
	close.Activated:Connect(function()
		Journal.setOpen(false)
	end)
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

function Journal.toggle()
	Journal.setOpen(not isOpen)
end

function Journal.start()
	purchaseRemote = Remotes.event(Remotes.PURCHASE)
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

return Journal
