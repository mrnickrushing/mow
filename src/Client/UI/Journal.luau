--!strict
--[[
	Journal — the menu, as a physical book.

	A dark floating panel reads as a settings dialogue. An open book with paper
	tab bookmarks, parchment pages and hand-drawn cards reads as part of the
	world, and that difference is most of what makes this genre feel warm rather
	than administrative.

	Four tabs down the left spine: what to do, what to buy, what you have found,
	and how any of it works.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Properties = require(Shared.Config.Properties)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Types = require(Shared.Types)
local Upgrades = require(Shared.Config.Upgrades)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Theme = require(script.Parent.Theme)

local Journal = {}

local player = Players.LocalPlayer
local purchaseRemote: RemoteEvent
local questRemote: RemoteEvent

local gui: ScreenGui
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

local TABS = {
	{ id = "objectives", label = "Journal", icon = "📜", color = Color3.fromRGB(226, 198, 150) },
	{ id = "upgrades", label = "Upgrades", icon = "⬆️", color = Color3.fromRGB(178, 214, 168) },
	{ id = "collection", label = "Collection", icon = "🍂", color = Color3.fromRGB(232, 196, 156) },
	{ id = "tips", label = "Tips", icon = "❓", color = Color3.fromRGB(200, 200, 216) },
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
		local row = Instance.new("Frame")
		row.Name = entry.id
		row.Size = UDim2.new(1, -12, 0, 54)
		row.BackgroundTransparency = 1
		row.LayoutOrder = order
		row.Parent = scroll

		-- A drawn checkbox rather than a tick character, so an unfinished
		-- objective still reads as something waiting to be done.
		local box = Instance.new("Frame")
		box.Size = UDim2.fromOffset(24, 24)
		box.Position = UDim2.fromOffset(2, 4)
		box.BackgroundColor3 = if entry.done then Color3.fromRGB(126, 186, 108) else PAPER
		box.BorderSizePixel = 0
		box.Parent = row
		Theme.corner(box, 5)
		local boxStroke = Instance.new("UIStroke")
		boxStroke.Thickness = 2
		boxStroke.Color = INK
		boxStroke.Transparency = 0.4
		boxStroke.Parent = box

		if entry.done then
			local tick = Instance.new("TextLabel")
			tick.Text = "✓"
			tick.Size = UDim2.fromScale(1, 1)
			tick.BackgroundTransparency = 1
			tick.Font = Theme.font
			tick.TextColor3 = Color3.fromRGB(28, 62, 24)
			tick.TextSize = 20
			tick.Parent = box
		end

		local title = Instance.new("TextLabel")
		title.Text = entry.text
		title.Size = UDim2.new(1, -40, 0, 26)
		title.Position = UDim2.fromOffset(36, 2)
		title.BackgroundTransparency = 1
		title.Font = Theme.font
		title.TextColor3 = if entry.done then LOCKED else Color3.fromRGB(48, 40, 32)
		title.TextSize = 20
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.Parent = row

		local progress = Instance.new("TextLabel")
		progress.Text = `({Format.count(entry.progress)}/{Format.count(entry.target)})`
		progress.Size = UDim2.new(1, -40, 0, 22)
		progress.Position = UDim2.fromOffset(36, 26)
		progress.BackgroundTransparency = 1
		progress.Font = Theme.fontRegular
		progress.TextColor3 = LOCKED
		progress.TextSize = 17
		progress.TextXAlignment = Enum.TextXAlignment.Left
		progress.Parent = row
	end
end

--- The right-hand page of the objectives spread: who else is on the property.
local function renderPlayers()
	heading(rightPage, "Players")
	local scroll = body(rightPage)

	local others = Players:GetPlayers()
	for order = 1, 4 do
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
		stats.Text = if isSelf
			then `🪙 {Format.cash(PlayerState.get().cash)}   🍂 {Format.count(PlayerState.get().bagWeight)}`
			else "🪙 —   🍂 —"
		stats.Size = UDim2.new(1, -64, 0, 24)
		stats.Position = UDim2.fromOffset(60, 30)
		stats.BackgroundTransparency = 1
		stats.Font = Theme.fontRegular
		stats.TextColor3 = LOCKED
		stats.TextSize = 17
		stats.TextXAlignment = Enum.TextXAlignment.Left
		stats.Parent = row
	end
end

--------------------------------------------------------------------
-- Upgrades
--------------------------------------------------------------------

--[[
	One upgrade card: icon tile, name, price, and a row of leaf pips showing how
	many levels are already bought.

	A locked card keeps its slot and shows a padlock, because seeing what is
	still ahead is most of the reason to open the page at all.
]]
local function upgradeCard(parent: Instance, order: number, def: Types.UpgradeDef?, level: number, cost: number?)
	local card = Instance.new("TextButton")
	card.Name = if def then def.id else `locked{order}`
	card.Size = UDim2.fromOffset(112, 132)
	card.BackgroundColor3 = PAPER
	card.BorderSizePixel = 0
	card.AutoButtonColor = def ~= nil
	card.Text = ""
	card.LayoutOrder = order
	card.Parent = parent
	Theme.corner(card, 8)

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = INK
	stroke.Transparency = 0.55
	stroke.Parent = card

	local name = Instance.new("TextLabel")
	name.Text = if def then def.name else "???"
	name.Size = UDim2.new(1, -8, 0, 20)
	name.Position = UDim2.fromOffset(4, 4)
	name.BackgroundTransparency = 1
	name.Font = Theme.font
	name.TextColor3 = if def then Color3.fromRGB(52, 44, 36) else LOCKED
	name.TextSize = 15
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Parent = card

	-- Leaf pips: filled for levels owned, outlined for levels still to buy.
	local pips = Instance.new("TextLabel")
	local maxPips = if def then math.min(def.maxLevel, 5) else 5
	local filled = if def then math.min(math.ceil(level / math.max(def.maxLevel, 1) * maxPips), maxPips) else 0
	pips.Text = string.rep("🍂", filled) .. string.rep("·", maxPips - filled)
	pips.Size = UDim2.new(1, -8, 0, 16)
	pips.Position = UDim2.fromOffset(4, 24)
	pips.BackgroundTransparency = 1
	pips.Font = Theme.fontRegular
	pips.TextColor3 = LOCKED
	pips.TextSize = 13
	pips.Parent = card

	local icon = Instance.new("TextLabel")
	icon.Text = if def then "🧤" else "🔒"
	icon.Size = UDim2.fromOffset(72, 60)
	icon.Position = UDim2.new(0.5, 0, 0, 42)
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.BackgroundColor3 = if def then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(206, 202, 196)
	icon.Font = Theme.font
	icon.TextSize = 34
	icon.BorderSizePixel = 0
	icon.Parent = card
	Theme.corner(icon, 6)

	local price = Instance.new("TextLabel")
	price.Text = if not def then "?" elseif cost then Format.cash(cost) else "MAX"
	price.Size = UDim2.new(1, -8, 0, 22)
	price.Position = UDim2.fromOffset(4, 106)
	price.BackgroundTransparency = 1
	price.Font = Theme.font
	price.TextColor3 = if def and cost then Color3.fromRGB(150, 106, 30) else LOCKED
	price.TextSize = 17
	price.Parent = card

	if def and cost then
		card.Activated:Connect(function()
			purchaseRemote:FireServer("upgrade", def.id)
		end)
	end
end

local function upgradeSection(parent: Instance, order: number, title: string, ids: { string })
	local section = Instance.new("Frame")
	section.Size = UDim2.new(1, -12, 0, 176)
	section.BackgroundTransparency = 1
	section.LayoutOrder = order
	section.Parent = parent

	local label = Instance.new("TextLabel")
	label.Text = title:upper()
	label.Size = UDim2.new(1, 0, 0, 26)
	label.BackgroundTransparency = 1
	label.Font = Theme.font
	label.TextColor3 = INK
	label.TextSize = 21
	label.Parent = section

	local tray = Instance.new("Frame")
	tray.Size = UDim2.new(1, 0, 0, 142)
	tray.Position = UDim2.fromOffset(0, 30)
	tray.BackgroundColor3 = Color3.fromRGB(232, 224, 202)
	tray.BorderSizePixel = 0
	tray.Parent = section
	Theme.corner(tray, 8)
	local trayStroke = Instance.new("UIStroke")
	trayStroke.Thickness = 2
	trayStroke.Color = INK
	trayStroke.Transparency = 0.7
	trayStroke.Parent = tray

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.Parent = tray

	local state = PlayerState.get()
	for slot, id in ids do
		local def = Upgrades.get(id)
		if def then
			local level = state.upgrades[id] or 0
			upgradeCard(tray, slot, def, level, Upgrades.costAt(def, level))
		else
			upgradeCard(tray, slot, nil, 0, nil)
		end
	end
end

local function renderUpgrades()
	heading(leftPage, "Hand")
	local left = body(leftPage)
	upgradeSection(left, 1, "Hand", { "bag", "speed", "yield" })
	upgradeSection(left, 2, "Boots", { "walk", "cash", "fuel" })

	heading(rightPage, "Gear")
	local right = body(rightPage)
	upgradeSection(right, 1, "Trailer", { "trailer", "", "" })

	-- Tools live on the same page, since buying one is the same decision.
	local state = PlayerState.get()
	local shown = 0
	for _, tool in Tools.list do
		if shown >= 8 then
			break
		end
		local owned = state.ownedTools[tool.id] == true
		if owned or tool.cost <= math.max(state.cash * 14, 3000) then
			shown += 1

			local row = Instance.new("TextButton")
			row.Size = UDim2.new(1, -12, 0, 46)
			row.BackgroundColor3 = PAPER
			row.BorderSizePixel = 0
			row.Text = ""
			row.LayoutOrder = 10 + shown
			row.AutoButtonColor = true
			row.Parent = right
			Theme.corner(row, 6)

			local rowStroke = Instance.new("UIStroke")
			rowStroke.Thickness = 2
			rowStroke.Color = INK
			rowStroke.Transparency = 0.6
			rowStroke.Parent = row

			local name = Instance.new("TextLabel")
			name.Text = tool.name
			name.Size = UDim2.new(1, -110, 1, 0)
			name.Position = UDim2.fromOffset(10, 0)
			name.BackgroundTransparency = 1
			name.Font = Theme.font
			name.TextColor3 = Color3.fromRGB(52, 44, 36)
			name.TextSize = 18
			name.TextXAlignment = Enum.TextXAlignment.Left
			name.TextTruncate = Enum.TextTruncate.AtEnd
			name.Parent = row

			local price = Instance.new("TextLabel")
			price.Text = if owned then "OWNED" else Format.cash(tool.cost)
			price.Size = UDim2.new(0, 100, 1, 0)
			price.Position = UDim2.new(1, -10, 0, 0)
			price.AnchorPoint = Vector2.new(1, 0)
			price.BackgroundTransparency = 1
			price.Font = Theme.font
			price.TextColor3 = if owned then LOCKED else Color3.fromRGB(150, 106, 30)
			price.TextSize = 17
			price.TextXAlignment = Enum.TextXAlignment.Right
			price.Parent = row

			row.Activated:Connect(function()
				if owned then
					Remotes.event(Remotes.EQUIP):FireServer(tool.id)
				else
					purchaseRemote:FireServer("tool", tool.id)
				end
			end)
		end
	end
end

--------------------------------------------------------------------
-- Collection and tips
--------------------------------------------------------------------

local function renderCollection()
	heading(leftPage, "Zones")
	local scroll = body(leftPage)

	local property = PlayerState.property()
	local state = PlayerState.get()
	if property then
		for order, zone in property.zones do
			local owned = state.unlockedZones[zone.id] == true
			local kind = Properties.unlockKind(zone)

			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, -12, 0, 44)
			row.BackgroundTransparency = 1
			row.LayoutOrder = order
			row.Parent = scroll

			local name = Instance.new("TextLabel")
			name.Text = if owned then zone.name else `🔒 {zone.name}`
			name.Size = UDim2.new(1, -100, 1, 0)
			name.BackgroundTransparency = 1
			name.Font = Theme.font
			name.TextColor3 = if owned then Color3.fromRGB(52, 44, 36) else LOCKED
			name.TextSize = 19
			name.TextXAlignment = Enum.TextXAlignment.Left
			name.Parent = row

			local how = Instance.new("TextLabel")
			how.Text = if owned
				then "✓"
				elseif kind == "completion" then "clear first"
				elseif kind == "button" then "find switch"
				else Format.cash(zone.cost)
			how.Size = UDim2.new(0, 96, 1, 0)
			how.Position = UDim2.new(1, 0, 0, 0)
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
	local lines = {
		`Lifetime earned: {Format.cash(PlayerState.get().lifetimeCash)}`,
		`Tips banked: {Format.count(PlayerState.get().tips)}`,
		`Bag capacity: {Format.count(PlayerState.get().bagCapacity)}`,
	}
	for order, line in lines do
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

local function renderTips()
	heading(leftPage, "Tips")
	local scroll = body(leftPage)

	local tips = {
		"Hold to work. Your deck cuts a swath as wide as the tool.",
		"The bag is the bottleneck early. Upgrade it before anything else.",
		"Walk into the trailer to sell — there is no button to press.",
		"Grass too thick for your tool will bog it down. That means buy better.",
		"Cut in long straight lines to bank a Clean Stripe bonus.",
		"Some zones are not for sale. Clear a yard, or find the switch.",
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
	local controls = {
		"Hold left mouse or E — work",
		"TAB — open this journal",
		"B — the shed",
		"G — the store",
		"F — mount a riding mower",
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

local function render()
	if not isOpen then
		return
	end
	clear(leftPage)
	clear(rightPage)

	if activeTab == "objectives" then
		renderObjectives()
		renderPlayers()
	elseif activeTab == "upgrades" then
		renderUpgrades()
	elseif activeTab == "collection" then
		renderCollection()
	else
		renderTips()
	end

	moneyLabel.Text = `your money :  {Format.cash(PlayerState.get().cash)}  🪙`
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
	button.Text = `{tab.icon}  {tab.label}`
	button.Font = Theme.font
	button.TextColor3 = Color3.fromRGB(120, 104, 84)
	button.TextSize = 20
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.AutoButtonColor = false
	button.Parent = parent

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 12)
	padding.Parent = button

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

	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MaxSize = Vector2.new(940, 560)
	sizeLimit.Parent = book

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
	rail.Size = UDim2.fromOffset(180, 240)
	rail.Position = UDim2.new(0, -164, 0, 60)
	rail.BackgroundTransparency = 1
	rail.ZIndex = 0
	rail.Parent = book
	for order, tab in TABS do
		buildTab(rail, order, tab)
	end

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.Size = UDim2.fromOffset(56, 56)
	close.Position = UDim2.new(1, 6, 0, -18)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Text = "✕"
	close.Font = Theme.font
	close.TextSize = 32
	close.BackgroundColor3 = Color3.fromRGB(214, 72, 60)
	close.TextColor3 = Color3.fromRGB(255, 246, 240)
	close.BorderSizePixel = 0
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
