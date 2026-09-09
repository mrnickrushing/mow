--!strict
--[[
	Hotbar — the numbered tool slots along the bottom.

	Small thing, large effect: seeing your gear laid out in slots with a number
	on each is what makes a set of tools feel like equipment rather than a
	setting buried in a menu. Number keys select, and the equipped slot lifts.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
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

--[[
	One slot, in the same chrome as everything else on the screen.

	Roblox has no `box-shadow`, so a slot is a transparent holder with a drop
	behind it and the face on top — the arrangement `Theme.chunkPanel` makes,
	written out here because the face has to be the `TextButton` a player
	presses rather than a frame with one over it.

	The icon sits in a well rather than on the face. A picture drawn straight
	onto a panel is a sticker; the same picture in a recess with its own
	outline is a thing in a slot, and it is what tells eight of these apart at
	a glance on a phone.
]]
local SLOT = 82

local function buildSlot(order: number): TextButton
	--- Not `holder`: that name already belongs to the row this goes into,
	--- and shadowing it made every slot its own parent.
	local seat = Instance.new("Frame")
	seat.Name = `Slot{order}Seat`
	seat.Size = UDim2.fromOffset(SLOT, SLOT)
	seat.BackgroundTransparency = 1
	seat.BorderSizePixel = 0
	seat.LayoutOrder = order
	seat.Parent = holder

	local drop = Instance.new("Frame")
	drop.Name = "Drop"
	drop.Size = UDim2.fromScale(1, 1)
	drop.Position = UDim2.fromOffset(0, 6)
	drop.BackgroundColor3 = Theme.colors.outline
	drop.BorderSizePixel = 0
	drop.ZIndex = 0
	drop.Parent = seat
	Theme.corner(drop, 18)

	local button = Instance.new("TextButton")
	button.Name = `Slot{order}`
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundColor3 = Theme.colors.panelLight
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	button.Parent = seat
	Theme.corner(button, 18)
	local face = Instance.new("UIGradient")
	face.Color = ColorSequence.new(Theme.colors.panelLight, Theme.colors.panel)
	face.Rotation = 90
	face.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Edge"
	stroke.Thickness = 4
	stroke.Color = Theme.colors.outline
	stroke.Parent = button

	local bevel = Instance.new("Frame")
	bevel.Name = "Bevel"
	bevel.Size = UDim2.new(1, -8, 0, 3)
	bevel.Position = UDim2.fromOffset(4, 3)
	bevel.BackgroundColor3 = Color3.new(1, 1, 1)
	bevel.BackgroundTransparency = 0.86
	bevel.BorderSizePixel = 0
	bevel.Parent = button
	Theme.corner(bevel, 2)

	local well = Instance.new("Frame")
	well.Name = "Well"
	well.Size = UDim2.fromOffset(52, 52)
	well.Position = UDim2.fromScale(0.5, 0.5)
	well.AnchorPoint = Vector2.new(0.5, 0.5)
	well.BackgroundColor3 = Color3.fromRGB(36, 26, 18)
	well.BorderSizePixel = 0
	well.Parent = button
	Theme.corner(well, 11)
	Theme.stroke(well, 3, Theme.colors.outline, 0)

	local number = Instance.new("TextLabel")
	number.Name = "Number"
	number.Text = tostring(order)
	number.Size = UDim2.fromOffset(18, 18)
	number.Position = UDim2.fromOffset(8, 4)
	number.BackgroundTransparency = 1
	number.Font = Theme.font
	number.TextColor3 = Theme.colors.label
	number.TextSize = 14
	number.Parent = button

	Theme.icon({
		name = "Icon",
		prop = Props.FALLBACK_TOOL_ICON,
		size = UDim2.fromScale(0.92, 0.92),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = well,
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
	more.Position = UDim2.new(1, -6, 1, -4)
	more.BackgroundTransparency = 1
	more.Font = Theme.font
	more.TextColor3 = Theme.colors.text
	more.TextSize = 14
	more.Visible = false
	more.Parent = button
	Theme.outline(more, 2)

	--[[
		The selected slot is underlined, and its well lights up.

		It used to fill the whole tile blue behind the icon, because a lift
		alone is easy to lose against a lawn covered in bright leaves. A bar
		hanging under the slot is not easy to lose either — it is the only
		blue on the screen and it sits outside the row's own outline — and it
		leaves the tile looking like the other seven, which is what makes a
		row of them read as a row. The well brightening carries the rest of
		what the fill was doing.
	]]
	local selected = Instance.new("Frame")
	selected.Name = "Selected"
	selected.Size = UDim2.new(1, -20, 0, 7)
	selected.Position = UDim2.new(0.5, 0, 1, 9)
	selected.AnchorPoint = Vector2.new(0.5, 0)
	selected.BackgroundColor3 = Palette.color(Palette.ui.selected)
	selected.BorderSizePixel = 0
	selected.Visible = false
	selected.Parent = button
	Theme.corner(selected, 4)
	Theme.stroke(selected, 2, Theme.colors.outline, 0)

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
		--- The icon lives in the well now, so this has to look past the face.
		local icon = button:FindFirstChild("Icon", true) :: ViewportFrame?
		local stroke = button:FindFirstChild("Edge") :: UIStroke?
		local selected = button:FindFirstChild("Selected") :: Frame?

		--- The holder is what the row lays out and what carries the drop, so
		--- hiding the face alone left a shadow with an empty gap over it.
		;(button.Parent :: Frame).Visible = toolId ~= nil
		if toolId and icon and stroke and selected then
			local tool = Tools.get(toolId)
			Theme.setIcon(icon, if tool then Props.forTool(tool.id, tool.category) else Props.FALLBACK_TOOL_ICON)

			--[[
				The slot no longer grows or fades when it is picked.

				Eight tiles that change size as you cycle through them is a row
				that moves under your thumb, and the fade left the selected one
				lighter than its neighbours on a bright lawn and darker on a
				dark one. The underline and the lit well say it instead, and
				every tile stays where it is.
			]]
			local equipped = state.equippedTool == toolId
			selected.Visible = equipped
			local well = button:FindFirstChild("Well") :: Frame?
			if well then
				well.BackgroundColor3 = if equipped
					then Color3.fromRGB(64, 48, 32)
					else Color3.fromRGB(36, 26, 18)
			end

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
	--- Eighty-two of slot and ten of gap, plus the drop and the underline
	--- hanging below the last row.
	holder.Size = UDim2.fromOffset(MAX_SLOTS * 92, 104)
	--[[
		Bottom left with a mouse, centred under a thumb.

		It was centred on every screen, which put it between the bag in one
		corner and the clock in the other and made it the one piece of UI that
		had to be told about both. The clock is part of the completion bar
		across the top now and the bag has gone to the top-left column, so the
		bottom-left is free — with a mouse.

		On touch it is not: Roblox draws the movement thumbstick over that
		corner, and its rest area is wider than the stick you can see. That is
		the same corner the bag was moved out of, for the same reason, so the
		row stays in the middle where a thumb on either side can reach it and
		neither thumb is standing on it.
	]]
	if UserInputService.TouchEnabled then
		holder.Position = UDim2.new(0.5, 0, 1, -22)
		holder.AnchorPoint = Vector2.new(0.5, 1)
	else
		holder.Position = UDim2.new(0, 26, 1, -22)
		holder.AnchorPoint = Vector2.new(0, 1)
	end
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
	--- The tool button parks itself bottom-right and is the only thing the
	--- row can still run into, so that corner is what it stands down for.
	local CORNER_WIDGET, CORNER_INSET = 200, 26
	Theme.fitToViewport(holder, MAX_SLOTS * 92, 140, 0, CORNER_WIDGET, CORNER_INSET)

	local layoutOrder = Instance.new("UIListLayout")
	layoutOrder.FillDirection = Enum.FillDirection.Horizontal
	layoutOrder.HorizontalAlignment = if UserInputService.TouchEnabled
		then Enum.HorizontalAlignment.Center
		else Enum.HorizontalAlignment.Left
	layoutOrder.VerticalAlignment = Enum.VerticalAlignment.Top
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
