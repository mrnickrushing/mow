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
local Worlds = require(Shared.Config.Worlds)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Types = require(Shared.Types)
local ToolUpgrades = require(Shared.Config.ToolUpgrades)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Store = require(script.Parent.Store)
local Theme = require(script.Parent.Theme)

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

--- The right-hand page of the objectives spread: who else is on the world.
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
		local pip = Instance.new("TextLabel")
		pip.Text = "🍁"
		pip.Size = UDim2.fromOffset(15, 15)
		pip.BackgroundTransparency = 1
		pip.TextSize = 12
		pip.TextTransparency = if index <= level then 0 else 0.75
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

	local icon = Instance.new("TextLabel")
	icon.Text = if owned then slot.icon else "🔒"
	icon.Size = UDim2.fromScale(1, 1)
	icon.BackgroundTransparency = 1
	icon.TextSize = 34
	icon.Parent = tile

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

	-- A tool you do not own sells itself right under its padlocked tree.
	if not owned and tool.cost > 0 then
		local buy = Instance.new("TextButton")
		buy.Text = `Buy — {Format.cash(tool.cost)}`
		buy.Size = UDim2.fromOffset(150, 26)
		buy.Position = UDim2.new(0.5, 0, 0, 182)
		buy.AnchorPoint = Vector2.new(0.5, 0)
		buy.BackgroundColor3 = if state.cash >= tool.cost
			then Color3.fromRGB(126, 158, 78)
			else Color3.fromRGB(196, 190, 178)
		buy.BorderSizePixel = 0
		buy.Font = Theme.font
		buy.TextColor3 = Color3.fromRGB(250, 244, 228)
		buy.TextSize = 17
		buy.Parent = holder
		Theme.corner(buy, 7)

		buy.Activated:Connect(function()
			purchaseRemote:FireServer("tool", tool.id)
		end)
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

	local affordable = selectedCost ~= nil and state.cash >= (selectedCost :: number)

	local buyButton = Instance.new("TextButton")
	buyButton.Text = if selectedCost then `BUY  —  {string.format("%.2f", selectedCost :: number)}$` else "BUY"
	buyButton.Size = UDim2.new(0.8, 0, 0, 48)
	buyButton.BackgroundColor3 = if affordable
		then Color3.fromRGB(126, 158, 78)
		else Color3.fromRGB(196, 190, 178)
	buyButton.BorderSizePixel = 0
	buyButton.Font = Theme.font
	buyButton.TextColor3 = Color3.fromRGB(250, 246, 238)
	buyButton.TextSize = 26
	buyButton.LayoutOrder = 3
	buyButton.Parent = left
	Theme.corner(buyButton, 12)
	Theme.outline(buyButton, 2)

	if affordable and selectedKey then
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

			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, -12, 0, 44)
			row.BackgroundTransparency = 1
			row.LayoutOrder = order
			row.Parent = scroll

			local name = Instance.new("TextLabel")
			name.Text = if owned then section.name else `🔒 {section.name}`
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
				else Format.cash(section.cost)
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
		`Earned this run: {Format.cash(PlayerState.get().earned)}`,
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

--- Re-renders the open spread in place. Cards call this after a selection.
function Journal.refresh()
	render()
end

--- True when anything in the book — a slot on an owned tool, or the next tool
--- itself — is affordable right now.
function Journal.somethingAffordable(): boolean
	local state = PlayerState.get()

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

	-- The Robux quick-buy hanging under the tabs: the flagship gamepass, one
	-- press from anywhere in the book.
	local quick = Instance.new("TextButton")
	quick.Name = "RobuxQuick"
	quick.Size = UDim2.fromOffset(120, 56)
	quick.Position = UDim2.fromOffset(24, 208)
	quick.BackgroundTransparency = 1
	quick.Text = "💨\n⬡ 180"
	quick.Font = Theme.font
	quick.TextColor3 = Theme.colors.cash
	quick.TextSize = 20
	quick.ZIndex = 0
	quick.Parent = rail
	Theme.outline(quick, 2.5)

	quick.Activated:Connect(function()
		Store.toggle()
	end)

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
