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

--- Slots shown. More than this and the bar starts covering the lawn.
local MAX_SLOTS = 6

local ICONS: { [string]: string } = {
	Hand = "🧤",
	Shears = "✂️",
	Rake = "🧹",
	Mower = "🚜",
	Trimmer = "🌿",
	Blower = "💨",
	HedgeTrimmer = "🪴",
	Saw = "🪚",
	Chainsaw = "🪓",
	Grinder = "⚙️",
	Chipper = "🪵",
}

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

	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.Text = ""
	icon.Size = UDim2.fromScale(1, 1)
	icon.BackgroundTransparency = 1
	icon.Font = Theme.font
	icon.TextSize = 30
	icon.Parent = button

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
		local toolId = layout[order]
		if toolId then
			equipRemote:FireServer(toolId)
		end
	end)

	return button
end

--- Rebuilds the slot contents from what the player owns.
local function refresh()
	local state = PlayerState.get()

	table.clear(layout)
	for _, tool in Tools.list do
		if state.ownedTools[tool.id] and #layout < MAX_SLOTS then
			table.insert(layout, tool.id)
		end
	end

	for order, button in slotFrames do
		local toolId = layout[order]
		local icon = button:FindFirstChild("Icon") :: TextLabel?
		local stroke = button:FindFirstChild("Edge") :: UIStroke?
		local selected = button:FindFirstChild("Selected") :: Frame?

		button.Visible = toolId ~= nil
		if toolId and icon and stroke and selected then
			local tool = Tools.get(toolId)
			icon.Text = if tool then ICONS[tool.category] or "🧰" else "🧰"

			local equipped = state.equippedTool == toolId
			stroke.Color = if equipped then Theme.colors.text else Theme.colors.outline
			stroke.Transparency = if equipped then 0 else 0.35
			button.BackgroundTransparency = if equipped then 1 else 0.5
			button.Size = if equipped then UDim2.fromOffset(72, 72) else UDim2.fromOffset(60, 60)
			selected.Visible = equipped
			icon.ZIndex = 2
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
	holder.Size = UDim2.fromOffset(MAX_SLOTS * 74, 80)
	holder.Position = UDim2.new(0.5, 0, 1, -12)
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

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

	local keys = {
		Enum.KeyCode.One,
		Enum.KeyCode.Two,
		Enum.KeyCode.Three,
		Enum.KeyCode.Four,
		Enum.KeyCode.Five,
		Enum.KeyCode.Six,
	}
	for order, key in keys do
		ContextActionService:BindAction(`MowSlot{order}`, function(_, inputState)
			if inputState == Enum.UserInputState.Begin then
				local toolId = layout[order]
				if toolId then
					equipRemote:FireServer(toolId)
				end
			end
			return Enum.ContextActionResult.Sink
		end, false, key)
	end

	PlayerState.Changed:Connect(refresh)
	refresh()
end

return Hotbar
