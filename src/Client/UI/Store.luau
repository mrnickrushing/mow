--!strict
--[[
	Store — the Robux shop.

	Passes and products are read straight from the shared config, and anything
	whose id is still a placeholder is hidden rather than shown as a dead button.
	That means the store is empty and harmless until real ids are pasted in, and
	fills itself in as they are.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Monetization = require(Shared.Config.Monetization)
local Prices = require(Shared.Prices)
local Remotes = require(Shared.Remotes)
local Theme = require(script.Parent.Theme)

local Store = {}

local player = Players.LocalPlayer
local promptRemote: RemoteEvent
local gui: ScreenGui
local listFrame: ScrollingFrame
local emptyLabel: TextLabel
local isOpen = false

--[[
	One thing for sale: what it is, what it does, and what it costs.

	The price is a slab in one of the two Robux colours — blue for what lasts
	this run, purple for what you keep — which is the one distinction in this
	shop a player has to be able to make without reading. Everything else on
	the row is dark type on a cream card, the same card the journal is built
	out of.
]]
local function addEntry(
	order: number,
	title: string,
	description: string,
	robux: number,
	keeps: boolean,
	buy: () -> ()
)
	local row = Theme.cardFace({
		name = title,
		size = UDim2.new(1, -12, 0, 78),
		parent = listFrame,
		radius = 16,
		drop = 5,
		outline = 4,
	})
	local seat = row.Parent :: Frame
	seat.LayoutOrder = order

	Theme.text({
		name = "Title",
		text = title,
		size = UDim2.new(1, -160, 0, 24),
		position = UDim2.fromOffset(16, 10),
		parent = row,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.ink,
		textSize = 19,
	})

	--[[
		Wrapped, because these lines are what the thing does.

		A single unwrapped line in a box a hundred and forty short of the
		price button fits about sixty characters, and VIP's is a hundred:
		"...and double tips from every strip" and then nothing. The row is
		tall enough for two lines of it — the label just was not allowed to
		use them.
	]]
	local detail = Theme.text({
		name = "Detail",
		text = description,
		size = UDim2.new(1, -160, 0, 34),
		position = UDim2.fromOffset(16, 34),
		parent = row,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.inkSoft,
		textSize = 14,
		bold = false,
	})
	detail.TextWrapped = true
	detail.TextYAlignment = Enum.TextYAlignment.Top

	local button = Theme.chunkButton({
		name = "Buy",
		variant = if keeps then "robuxKeep" else "robuxRun",
		text = `R$ {robux}`,
		textSize = 18,
		size = UDim2.fromOffset(122, 46),
		position = UDim2.new(1, -14, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		parent = row,
		radius = 13,
		outline = 3,
	})
	button.Activated:Connect(buy)
end

--[[
	A heading between the groups.

	Forty-five rows in a list four rows tall is a nine-screen scroll, and
	until the shop was filled in it was fifteen and the question never came
	up. Somebody who wants Fast Feet should not have to go past thirty tool
	unlocks to find out whether it exists.
]]
local function addHeading(order: number, text: string)
	local heading = Instance.new("Frame")
	heading.Name = text
	heading.Size = UDim2.new(1, -12, 0, 30)
	heading.BackgroundTransparency = 1
	heading.LayoutOrder = order
	heading.Parent = listFrame

	local label = Theme.text({
		name = "Text",
		text = text,
		size = UDim2.new(1, -8, 1, 0),
		position = UDim2.fromOffset(6, 0),
		parent = heading,
		align = Enum.TextXAlignment.Left,
		textSize = 15,
		color = Theme.colors.label,
	})
	local _ = label
end

local function render()
	for _, child in listFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local order = 0

	--[[
		Three groups, in the order somebody shops in them.

		Passes first, because they are the things you keep. Then the one-off
		boosts and refills. The tool unlocks last, because there are thirty
		of them and they are the long tail rather than the shop window.
	]]
	-- Annotated: an empty table literal infers as unknown, and the entries
	-- are read for their fields a few lines down.
	local passes: { Monetization.PassDef } = {}
	local boosts: { Monetization.ProductDef } = {}
	local tools: { Monetization.ProductDef } = {}
	for _, def in Monetization.passes do
		if Monetization.isConfigured(def.id) then
			table.insert(passes, def)
		end
	end
	for _, def in Monetization.products do
		if Monetization.isConfigured(def.id) then
			local isTool = def.kind == "toolRun" or def.kind == "toolPermanent"
			table.insert(if isTool then tools else boosts, def)
		end
	end

	if #passes > 0 then
		order += 1
		addHeading(order, "YOURS FOR GOOD")
		for _, def in passes do
			order += 1
			addEntry(order, def.name, def.description, Prices.robux(def.id, def.robux), true, function()
				promptRemote:FireServer("pass", def.key)
			end)
		end
	end

	if #boosts > 0 then
		order += 1
		addHeading(order, "BOOSTS AND REFILLS")
		for _, def in boosts do
			order += 1
			--- A boost or a refill runs out; only a pass is kept.
			addEntry(order, def.name, def.description, Prices.robux(def.id, def.robux), false, function()
				promptRemote:FireServer("product", def.key)
			end)
		end
	end

	if #tools > 0 then
		order += 1
		addHeading(order, "TOOLS")
		for _, def in tools do
			order += 1
			addEntry(
				order,
				def.name,
				def.description,
				Prices.robux(def.id, def.robux),
				def.kind == "toolPermanent",
				function()
					promptRemote:FireServer("product", def.key)
				end
			)
		end
	end

	-- Nothing configured yet is the expected state of a fresh place, so say so
	-- plainly rather than showing an empty box.
	emptyLabel.Visible = order == 0
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MowStore"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 6
	gui.Parent = player:WaitForChild("PlayerGui")

	local shade = Instance.new("Frame")
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.45
	shade.BorderSizePixel = 0
	shade.Parent = gui

	--[[
		Tall, because there are forty-five things to buy in here.

		At 440 the list showed five rows of forty-five — three sections and
		eleven tools, each sold twice — so finding the chainsaw meant nine
		screens of scrolling past everything else. Nothing was broken; there
		was simply no reason for the window to be that short, and on a tablet
		it left six hundred pixels of shaded background under it.

		`fitToViewport` only ever shrinks, never grows, so the authored size is
		the largest this is ever drawn: asking for more height costs nothing on
		a small screen, where it scales down exactly as before.
	]]
	local WINDOW = Vector2.new(600, 760)
	local window = Theme.chunkPanel({
		name = "Window",
		size = UDim2.fromOffset(WINDOW.X, WINDOW.Y),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = gui,
		radius = 26,
		drop = 12,
		outline = 5,
		top = Color3.fromRGB(66, 49, 31),
		bottom = Color3.fromRGB(42, 31, 21),
	})
	Theme.fitToViewport(window.Parent :: GuiObject, WINDOW.X + 40, WINDOW.Y + 40)

	--- The gold diamond that heads every panel in the game.
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.fromOffset(13, 13)
	badge.Position = UDim2.fromOffset(22, 26)
	badge.Rotation = 45
	badge.BackgroundColor3 = Theme.colors.tips
	badge.BorderSizePixel = 0
	badge.Parent = window

	Theme.text({
		name = "Title",
		text = "STORE",
		size = UDim2.fromOffset(300, 26),
		position = UDim2.fromOffset(46, 20),
		parent = window,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.tips,
		textSize = 21,
	})
	Theme.text({
		name = "Blurb",
		text = "Blue lasts the run. Purple is yours for good.",
		size = UDim2.fromOffset(400, 20),
		position = UDim2.fromOffset(46, 45),
		parent = window,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.label,
		textSize = 15,
	})

	local close = Theme.chunkButton({
		name = "Close",
		variant = "danger",
		size = UDim2.fromOffset(46, 46),
		position = UDim2.new(1, -18, 0, 18),
		anchor = Vector2.new(1, 0),
		parent = window,
		radius = Theme.PILL,
		drop = 4,
		outline = 4,
	})
	-- Releases the first-person mouse lock while the store is open, so its rows
	-- can actually be clicked. See the note in Journal.
	close.Modal = true
	Theme.icon({
		name = "CloseIcon",
		prop = "Cross",
		size = UDim2.fromScale(0.62, 0.62),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = close,
	})
	close.Activated:Connect(function()
		Store.setOpen(false)
	end)

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Size = UDim2.new(1, -32, 1, -96)
	listFrame.Position = UDim2.fromOffset(16, 80)
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 7
	listFrame.ScrollBarImageColor3 = Theme.colors.outline
	listFrame.ScrollBarImageTransparency = 0.15
	listFrame.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	listFrame.CanvasSize = UDim2.new()
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listFrame.Parent = window

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 10)
	layout.Parent = listFrame

	emptyLabel = Theme.text({
		name = "Empty",
		text = "Nothing here yet — the shop opens once the products are set up.",
		size = UDim2.new(1, -40, 0, 60),
		position = UDim2.fromScale(0.5, 0.45),
		anchor = Vector2.new(0.5, 0.5),
		parent = window,
		color = Theme.colors.label,
		align = Enum.TextXAlignment.Center,
		textSize = 16,
		bold = false,
	})
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
	end
end

function Store.toggle()
	Store.setOpen(not isOpen)
end

function Store.start()
	promptRemote = Remotes.event(Remotes.PROMPT_PURCHASE)
	build()
	render()

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
