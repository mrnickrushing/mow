--!strict
--[[
	Shop — the Shed interface: tools, upgrades and zones.

	Rows show what a purchase actually does rather than only its price, because
	"+40% capacity" is the reason to buy a bag and "$250" is not. Anything the
	player cannot afford stays visible and dimmed so the next goal is always on
	screen.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Properties = require(Shared.Config.Properties)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Upgrades = require(Shared.Config.Upgrades)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Theme = require(script.Parent.Theme)

local Shop = {}

local player = Players.LocalPlayer
local purchaseRemote: RemoteEvent

local gui: ScreenGui
local window: Frame
local listFrame: ScrollingFrame
local tabButtons: { [string]: TextButton } = {}
local activeTab = "tools"
local isOpen = false

local TABS = { { id = "tools", label = "TOOLS" }, { id = "upgrades", label = "UPGRADES" }, { id = "zones", label = "ZONES" } }

--------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------

type RowSpec = {
	title: string,
	detail: string,
	effect: string,
	cost: number?,
	costLabel: string?,
	owned: boolean,
	affordable: boolean,
	equipped: boolean?,
	buy: (() -> ())?,
}

local function clearList()
	for _, child in listFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
end

local function addRow(spec: RowSpec, order: number)
	local row = Theme.panel({
		name = spec.title,
		size = UDim2.new(1, -12, 0, 74),
		position = UDim2.fromScale(0, 0),
		parent = listFrame,
		transparency = 0.25,
	})
	row.LayoutOrder = order

	Theme.text({
		name = "Title",
		text = spec.title,
		size = UDim2.new(1, -150, 0, 22),
		position = UDim2.fromOffset(12, 8),
		parent = row,
		textSize = 18,
	})
	Theme.text({
		name = "Detail",
		text = spec.detail,
		size = UDim2.new(1, -150, 0, 18),
		position = UDim2.fromOffset(12, 30),
		parent = row,
		color = Theme.colors.subtext,
		textSize = 13,
		bold = false,
	})
	Theme.text({
		name = "Effect",
		text = spec.effect,
		size = UDim2.new(1, -150, 0, 18),
		position = UDim2.fromOffset(12, 50),
		parent = row,
		color = Theme.colors.grass,
		textSize = 14,
	})

	local button = Instance.new("TextButton")
	button.Name = "Buy"
	button.Size = UDim2.fromOffset(118, 42)
	button.Position = UDim2.new(1, -12, 0.5, 0)
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Font = Theme.font
	button.TextSize = 16
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Parent = row
	Theme.corner(button, 8)

	if spec.owned then
		button.Text = if spec.equipped then "EQUIPPED" else "EQUIP"
		button.BackgroundColor3 = if spec.equipped then Theme.colors.panelLight else Theme.colors.grassDark
		button.TextColor3 = if spec.equipped then Theme.colors.subtext else Theme.colors.text
		button.AutoButtonColor = not spec.equipped
	else
		button.Text = spec.costLabel or Format.cash(spec.cost or 0)
		button.BackgroundColor3 = if spec.affordable then Theme.colors.grass else Theme.colors.panelLight
		button.TextColor3 = if spec.affordable then Color3.fromRGB(16, 32, 14) else Theme.colors.subtext
		button.AutoButtonColor = spec.affordable
	end

	local action = spec.buy
	if action then
		button.Activated:Connect(action)
	end
end

--------------------------------------------------------------------
-- Tab contents
--------------------------------------------------------------------

local function renderTools()
	local state = PlayerState.get()
	local order = 0

	for _, tool in Tools.list do
		local owned = state.ownedTools[tool.id] == true
		local equipped = state.equippedTool == tool.id

		-- Hide tools far beyond what the player could plausibly reach, so the
		-- list stays a short-term shopping list rather than a wall of numbers.
		local reachable = owned or tool.cost <= math.max(state.cash * 12, 2000)
		if reachable then
			order += 1
			addRow({
				title = tool.name,
				detail = tool.description,
				effect = `{tool.deck}-tile deck · {tool.power} height/pass · {string.format("%.1f", tool.rate)}/s`,
				cost = tool.cost,
				costLabel = if tool.currency == "Tips" then `{Format.count(tool.cost)} tips` else nil,
				owned = owned,
				equipped = equipped,
				affordable = state.cash >= tool.cost,
				buy = function()
					if owned then
						if not equipped then
							Remotes.event(Remotes.EQUIP):FireServer(tool.id)
						end
					else
						purchaseRemote:FireServer("tool", tool.id)
					end
				end,
			}, order)
		end
	end
end

local function renderUpgrades()
	local state = PlayerState.get()

	for order, def in Upgrades.list do
		local level = state.upgrades[def.id] or 0
		local cost = Upgrades.costAt(def, level)
		local current = Upgrades.valueAt(def, level)
		local nextValue = Upgrades.valueAt(def, level + 1)

		local effect = if cost
			then `{Format.count(current)}{def.suffix or ""} → {Format.count(nextValue)}{def.suffix or ""}`
			else `Maxed at {Format.count(current)}{def.suffix or ""}`

		addRow({
			title = `{def.name}  ·  Lv {level}/{def.maxLevel}`,
			detail = def.description,
			effect = effect,
			cost = cost,
			costLabel = if cost then nil else "MAX",
			owned = cost == nil,
			equipped = cost == nil,
			affordable = cost ~= nil and state.cash >= cost,
			buy = function()
				if cost then
					purchaseRemote:FireServer("upgrade", def.id)
				end
			end,
		}, order)
	end
end

local function renderZones()
	local property = PlayerState.property()
	if not property then
		return
	end
	local state = PlayerState.get()

	for order, zone in property.zones do
		local owned = state.unlockedZones[zone.id] == true
		local tiles = zone.rect.w * zone.rect.d
		local kind = Properties.unlockKind(zone)

		-- Earned zones show how to earn them rather than a price, so the shop
		-- never implies a rooftop is something you can simply buy.
		local effect, costLabel
		if owned then
			effect = "Unlocked"
		elseif kind == "completion" then
			local required = Properties.zone(property, zone.requires or "")
			effect = `Opens when the {if required then required.name else "previous area"} is 100% clear`
			costLabel = "EARN IT"
		elseif kind == "button" then
			local host = Properties.zone(property, zone.buttonIn or "")
			effect = `A switch somewhere in the {if host then host.name else "property"} opens this`
			costLabel = "FIND IT"
		else
			effect = "More to clear means more to earn before the round ends"
		end

		addRow({
			title = zone.name,
			detail = `{Format.count(tiles)} tiles on {property.name}`,
			effect = effect,
			cost = zone.cost,
			costLabel = if costLabel then costLabel elseif zone.cost <= 0 then "FREE" else nil,
			owned = owned,
			equipped = owned,
			-- Nothing to buy, so never render it as an affordable purchase.
			affordable = kind == "cash" and state.cash >= zone.cost,
			buy = function()
				if not owned and kind == "cash" then
					purchaseRemote:FireServer("zone", zone.id)
				end
			end,
		}, order)
	end
end

local function render()
	if not isOpen then
		return
	end
	clearList()

	if activeTab == "tools" then
		renderTools()
	elseif activeTab == "upgrades" then
		renderUpgrades()
	else
		renderZones()
	end
end

--------------------------------------------------------------------
-- Window
--------------------------------------------------------------------

local function setTab(id: string)
	activeTab = id
	for tabId, button in tabButtons do
		local selected = tabId == id
		button.BackgroundColor3 = if selected then Theme.colors.grass else Theme.colors.panelLight
		button.TextColor3 = if selected then Color3.fromRGB(16, 32, 14) else Theme.colors.subtext
	end
	render()
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MowShop"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 5
	gui.Parent = player:WaitForChild("PlayerGui")

	local shade = Instance.new("Frame")
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.45
	shade.BorderSizePixel = 0
	shade.Parent = gui

	window = Theme.panel({
		name = "Window",
		size = UDim2.fromOffset(620, 470),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = gui,
		transparency = 0.02,
	})

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MaxSize = Vector2.new(620, 470)
	sizeConstraint.Parent = window

	Theme.text({
		name = "Title",
		text = "THE SHED",
		size = UDim2.fromOffset(300, 30),
		position = UDim2.fromOffset(20, 16),
		parent = window,
		textSize = 24,
	})

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.Size = UDim2.fromOffset(36, 36)
	close.Position = UDim2.new(1, -16, 0, 14)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Text = "✕"
	close.Font = Theme.font
	close.TextSize = 20
	close.BackgroundColor3 = Theme.colors.panelLight
	close.TextColor3 = Theme.colors.subtext
	close.BorderSizePixel = 0
	close.Parent = window
	Theme.corner(close, 8)
	close.Activated:Connect(function()
		Shop.setOpen(false)
	end)

	local tabRow = Instance.new("Frame")
	tabRow.Name = "Tabs"
	tabRow.Size = UDim2.new(1, -40, 0, 36)
	tabRow.Position = UDim2.fromOffset(20, 56)
	tabRow.BackgroundTransparency = 1
	tabRow.Parent = window

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 8)
	tabLayout.Parent = tabRow

	for index, tab in TABS do
		local button = Instance.new("TextButton")
		button.Name = tab.id
		button.Size = UDim2.fromOffset(140, 36)
		button.Text = tab.label
		button.Font = Theme.font
		button.TextSize = 15
		button.BorderSizePixel = 0
		button.LayoutOrder = index
		button.Parent = tabRow
		Theme.corner(button, 8)
		button.Activated:Connect(function()
			setTab(tab.id)
		end)
		tabButtons[tab.id] = button
	end

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Name = "List"
	listFrame.Size = UDim2.new(1, -28, 1, -110)
	listFrame.Position = UDim2.fromOffset(14, 100)
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 5
	listFrame.ScrollBarImageColor3 = Theme.colors.stroke
	listFrame.CanvasSize = UDim2.new()
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listFrame.Parent = window

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = listFrame
end

function Shop.setOpen(open: boolean)
	isOpen = open
	gui.Enabled = open
	if open then
		render()
	end
end

function Shop.isOpen(): boolean
	return isOpen
end

function Shop.toggle()
	Shop.setOpen(not isOpen)
end

function Shop.start()
	purchaseRemote = Remotes.event(Remotes.PURCHASE)
	build()
	setTab("tools")

	-- Re-render on any state change so prices grey in and out as cash moves.
	PlayerState.Changed:Connect(render)
	PlayerState.WorldChanged:Connect(function()
		if activeTab == "zones" then
			render()
		end
	end)
end

return Shop
