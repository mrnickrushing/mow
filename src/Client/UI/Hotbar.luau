--!strict
--[[
	Hotbar — the numbered tool slots along the bottom.

	Small thing, large effect: seeing your gear laid out in slots with a number
	on each is what makes a set of tools feel like equipment rather than a
	setting buried in a menu. Number keys select, and the equipped slot lifts.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared.Config.Palette)
local RunOnly = require(script.Parent.RunOnly)
local Props = require(Shared.Config.Props)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Theme = require(script.Parent.Theme)

local Hotbar = {}

local player = Players.LocalPlayer
local equipRemote: RemoteEvent
local holder: Frame
local slotFrames: { TextButton } = {}
--- Tool ids currently laid out, in slot order.
local layout: { string } = {}
--- Everything owned in each slot's category, strongest first. A slot holds a
--- category rather than a tool, and pressing it again walks down the list.
local slotTools: { { string } } = {}
local choose: (order: number) -> ()

--- Slots shown. More than this and the bar starts covering the lawn.
--[[
	Slots on the bar.

	Sixteen tools across eleven categories will not fit in six, and the six it
	kept were the six cheapest — so a maxed player's bar was hands, reel mower,
	rake, gas mower, trimmer and blower, with everything they had actually
	worked for missing from it. Eight covers the best of eight categories,
	which between them clear every kind of debris in the game with room to
	spare.
]]
--[[
	Ten, because there are ten categories of tool and there were eight slots.

	Hand, Mower, Rake, Trimmer, Blower, HedgeTrimmer, Saw, Chainsaw, Grinder,
	Chipper. At eight it was not possible to show one of each, so owning the
	ladder pushed whole categories off the end — and the bar is the only thing
	that fires the equip remote, so off the end means gone.
]]
local MAX_SLOTS = 10

local function buildSlot(order: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = `Slot{order}`
	button.Size = UDim2.fromOffset(64, 64)
	button.BackgroundColor3 = Theme.colors.panel
	button.BackgroundTransparency = 0.2
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	button.LayoutOrder = order
	button.Parent = holder
	Theme.corner(button, 12)

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Edge"
	stroke.Thickness = 3
	stroke.Color = Theme.colors.outline
	stroke.Parent = button

	local number = Instance.new("TextLabel")
	number.Name = "Number"
	number.Text = tostring(order)
	number.Size = UDim2.fromOffset(18, 18)
	number.Position = UDim2.fromOffset(4, 2)
	number.BackgroundTransparency = 1
	number.Font = Theme.font
	number.TextColor3 = Theme.colors.text
	number.TextSize = 16
	number.Parent = button
	Theme.outline(number, 2)

	Theme.icon({
		name = "Icon",
		prop = Props.FALLBACK_TOOL_ICON,
		size = UDim2.fromScale(0.86, 0.86),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = button,
	})

	--[[
		How many more of this kind are in here.

		Without it a slot that cycles looks exactly like one that does not, and
		nobody presses a button twice to find out.
	]]
	local more = Instance.new("TextLabel")
	more.Name = "More"
	more.Text = ""
	more.Size = UDim2.fromOffset(20, 16)
	more.AnchorPoint = Vector2.new(1, 1)
	more.Position = UDim2.new(1, -3, 1, -2)
	more.BackgroundTransparency = 1
	more.Font = Theme.font
	more.TextColor3 = Theme.colors.text
	more.TextSize = 14
	more.Visible = false
	more.Parent = button
	Theme.outline(more, 2)

	-- The selected slot fills in behind the icon and takes a white border. A
	-- lift alone is easy to lose against a lawn covered in bright leaves on a
	-- phone; a filled tile is not, and it is what tells you at a glance which
	-- tool is in your hands.
	local selected = Instance.new("Frame")
	selected.Name = "Selected"
	selected.Size = UDim2.fromScale(1, 1)
	selected.BackgroundColor3 = Palette.color(Palette.ui.selected)
	selected.BorderSizePixel = 0
	selected.ZIndex = 0
	selected.Visible = false
	selected.Parent = button
	Theme.corner(selected, 12)

	local selectedEdge = Instance.new("UIStroke")
	selectedEdge.Thickness = 3.5
	selectedEdge.Color = Palette.color(Palette.ui.text)
	selectedEdge.Parent = selected

	button.Activated:Connect(function()
		choose(order)
	end)

	return button
end

--[[
	Equips a slot, or walks to the next tool of its kind.

	Pressing a slot you are not holding equips it. Pressing the one you are
	holding moves to the next tool in that category and wraps, which is the only
	way to reach a tool that is not the best of its kind.
]]
function choose(order: number)
	local list = slotTools[order]
	local current = layout[order]
	if not list or not current then
		return
	end
	if PlayerState.get().equippedTool == current and #list > 1 then
		local at = table.find(list, current) or 1
		equipRemote:FireServer(list[(at % #list) + 1])
	else
		equipRemote:FireServer(current)
	end
end

--- Rebuilds the slot contents from what the player owns.
local function refresh()
	local state = PlayerState.get()

	--[[
		Which six of the sixteen.

		This took the first six owned in tier order, which is fine until you
		own seven. The hotbar is the only thing in the game that fires the
		equip remote — the book buys tools, it does not switch between them —
		so anything that fell off the end of the bar could never be selected
		again. A player who had worked up to a sixty-five thousand dollar
		Zero-Turn could hold it exactly until they pressed another number, and
		then never get it back.

		The bar is built to guarantee three things instead: your hands are
		always on it, because they clear every kind of debris and are what the
		game tells you to reach for when a tool refuses; whatever you are
		holding is always on it; and after that it is the best tool you own of
		each category, strongest first, so a mower, a rake, a blower and a saw
		beat four grades of mower.

		Laid out weakest to strongest at the end, so the order a player learns
		does not shuffle every time they buy something.
	]]
	table.clear(layout)
	table.clear(slotTools)

	--[[
		A slot is a category, not a tool.

		The bar used to be a pick of individual tools: your hands, whatever was
		equipped, then the best of each category, then the strongest of
		whatever was left. That guaranteed the strong things and quietly lost
		the rest — with the whole ladder owned it came out as hands plus the
		seven highest tiers, and the eight tools underneath them, the reel
		mower and the rake and the gas mower among them, could not be selected
		at all. Owned, listed in the book, unreachable.

		Ten categories into ten slots fixes the arithmetic. Pressing a slot
		that is already in your hand walks to the next tool of that kind, so
		the mower slot goes commercial deck, zero turn, riding, self-propelled,
		gas, reel and round again. Everything owned is two presses away and the
		bar did not get any wider.
	]]
	local byCategory: { [string]: { string } } = {}
	local categories: { string } = {}
	for _, tool in Tools.list do
		if state.ownedTools[tool.id] and Tools.get(tool.id) then
			local list = byCategory[tool.category]
			if not list then
				list = {}
				byCategory[tool.category] = list
				table.insert(categories, tool.category)
			end
			table.insert(list, tool.id)
		end
	end

	-- Strongest first inside a slot, so one press still gets the best of its
	-- kind and the walk is downhill from there.
	for _, list in byCategory do
		table.sort(list, function(a, b)
			return Tools.expect(a).tier > Tools.expect(b).tier
		end)
	end

	-- Laid out weakest to strongest, so the order a player learns does not
	-- shuffle every time they buy something.
	table.sort(categories, function(a, b)
		return Tools.expect(byCategory[a][1]).tier < Tools.expect(byCategory[b][1]).tier
	end)

	for _, category in categories do
		if #layout >= MAX_SLOTS then
			break
		end
		table.insert(slotTools, byCategory[category])
		table.insert(layout, byCategory[category][1])
	end

	-- A slot shows what is actually in your hand rather than the best of its
	-- kind, or the bar would stop saying what you are holding the moment you
	-- walked down one.
	for index, list in slotTools do
		if table.find(list, state.equippedTool) then
			layout[index] = state.equippedTool
		end
	end

	for order, button in slotFrames do
		local toolId = layout[order]
		local icon = button:FindFirstChild("Icon") :: ViewportFrame?
		local stroke = button:FindFirstChild("Edge") :: UIStroke?
		local selected = button:FindFirstChild("Selected") :: Frame?

		button.Visible = toolId ~= nil
		if toolId and icon and stroke and selected then
			local tool = Tools.get(toolId)
			Theme.setIcon(icon, if tool then Props.forTool(tool.id, tool.category) else Props.FALLBACK_TOOL_ICON)

			local equipped = state.equippedTool == toolId
			stroke.Color = if equipped then Theme.colors.text else Theme.colors.outline
			stroke.Transparency = if equipped then 0 else 0.35
			button.BackgroundTransparency = if equipped then 1 else 0.5
			button.Size = if equipped then UDim2.fromOffset(72, 72) else UDim2.fromOffset(60, 60)
			selected.Visible = equipped
			icon.ZIndex = 2

			local more = button:FindFirstChild("More") :: TextLabel?
			local stack = slotTools[order]
			if more then
				more.Visible = stack ~= nil and #stack > 1
				more.Text = if stack and #stack > 1 then `+{#stack - 1}` else ""
			end
		end
	end
end

function Hotbar.start()
	equipRemote = Remotes.event(Remotes.EQUIP)

	local gui = Instance.new("ScreenGui")
	gui.Name = "MowHotbar"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	holder = Instance.new("Frame")
	holder.Name = "Slots"
	RunOnly.add(holder)
	holder.Size = UDim2.fromOffset(MAX_SLOTS * 74, 80)
	holder.Position = UDim2.new(0.5, 0, 1, -12)
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	--[[
		Scaled to the screen, like every other panel.

		This was the one piece of UI in the game with no viewport scaling on
		it: a fixed bar in pixels, which on a narrow phone ran off both ends
		and took the outer slots with it. It is the widest thing on the HUD and
		it sits along the bottom edge, so it is the one that could least afford
		to be fixed.
	]]
	--[[
		Wide enough to reach the corners, so it has to give way to them.

		Eight slots is 592 pixels of bar across the middle of the bottom edge,
		and it only shrank once the screen was narrower than that. But the bag
		sits 210 pixels in from the left and the clock 262 in from the right,
		and a centred 592-wide bar reaches them long before it reaches the edge
		— measured at 1024x576, the clock was sitting on the last two slots.

		Fitting against the bar plus both corners plus a margin makes it stand
		down while there is still room for all three. A screen wide enough for
		everything is unaffected: the scale clamps at 1 above 1212 pixels, so
		nothing changes on a desktop.
	]]
	-- The round timer is 240 wide and sits 22 in from the edge. Only the first
	-- of those shrinks on a phone, so they are passed separately; together they
	-- are the same 262 this reserved before.
	local CORNER_WIDGET, CORNER_INSET = 240, 22
	Theme.fitToViewport(holder, MAX_SLOTS * 74, 120, 0, CORNER_WIDGET, CORNER_INSET)

	local layoutOrder = Instance.new("UIListLayout")
	layoutOrder.FillDirection = Enum.FillDirection.Horizontal
	layoutOrder.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layoutOrder.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layoutOrder.SortOrder = Enum.SortOrder.LayoutOrder
	layoutOrder.Padding = UDim.new(0, 10)
	layoutOrder.Parent = holder

	for order = 1, MAX_SLOTS do
		table.insert(slotFrames, buildSlot(order))
	end

	-- Nine and zero for the last two, the way every game with ten slots does it.
	local keys = {
		Enum.KeyCode.One,
		Enum.KeyCode.Two,
		Enum.KeyCode.Three,
		Enum.KeyCode.Four,
		Enum.KeyCode.Five,
		Enum.KeyCode.Six,
		Enum.KeyCode.Seven,
		Enum.KeyCode.Eight,
		Enum.KeyCode.Nine,
		Enum.KeyCode.Zero,
	}
	for order, key in keys do
		ContextActionService:BindAction(`MowSlot{order}`, function(_, inputState)
			if inputState == Enum.UserInputState.Begin then
				choose(order)
			end
			return Enum.ContextActionResult.Sink
		end, false, key)
	end

	PlayerState.Changed:Connect(refresh)
	refresh()
end

return Hotbar
