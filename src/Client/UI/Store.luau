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
local Remotes = require(Shared.Remotes)
local Theme = require(script.Parent.Theme)

local Store = {}

local player = Players.LocalPlayer
local promptRemote: RemoteEvent
local gui: ScreenGui
local listFrame: ScrollingFrame
local emptyLabel: TextLabel
local isOpen = false

local function addEntry(order: number, title: string, description: string, robux: number, buy: () -> ())
	local row = Theme.panel({
		name = title,
		size = UDim2.new(1, -12, 0, 68),
		position = UDim2.fromScale(0, 0),
		parent = listFrame,
		transparency = 0.25,
	})
	row.LayoutOrder = order

	Theme.text({
		name = "Title",
		text = title,
		size = UDim2.new(1, -140, 0, 22),
		position = UDim2.fromOffset(12, 10),
		parent = row,
		textSize = 17,
	})
	Theme.text({
		name = "Detail",
		text = description,
		size = UDim2.new(1, -140, 0, 30),
		position = UDim2.fromOffset(12, 32),
		parent = row,
		color = Theme.colors.subtext,
		textSize = 13,
		bold = false,
	})

	local button = Instance.new("TextButton")
	button.Name = "Buy"
	button.Size = UDim2.fromOffset(110, 40)
	button.Position = UDim2.new(1, -12, 0.5, 0)
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Text = `R$ {robux}`
	button.Font = Theme.font
	button.TextSize = 16
	button.BackgroundColor3 = Theme.colors.tips
	button.TextColor3 = Color3.fromRGB(40, 30, 0)
	button.BorderSizePixel = 0
	button.Parent = row
	Theme.corner(button, 8)
	button.Activated:Connect(buy)
end

local function render()
	for _, child in listFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local order = 0

	for _, def in Monetization.passes do
		if Monetization.isConfigured(def.id) then
			order += 1
			addEntry(order, def.name, def.description, def.robux, function()
				promptRemote:FireServer("pass", def.key)
			end)
		end
	end

	for _, def in Monetization.products do
		if Monetization.isConfigured(def.id) then
			order += 1
			addEntry(order, def.name, def.description, def.robux, function()
				promptRemote:FireServer("product", def.key)
			end)
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

	local window = Theme.panel({
		name = "Window",
		size = UDim2.fromOffset(600, 440),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = gui,
		transparency = 0.02,
	})
	Theme.fitToViewport(window, 600 + 40, 440 + 40)

	Theme.text({
		name = "Title",
		text = "STORE",
		size = UDim2.fromOffset(300, 30),
		position = UDim2.fromOffset(20, 16),
		parent = window,
		textSize = 24,
	})

	local close = Instance.new("TextButton")
	-- Releases the first-person mouse lock while the store is open, so its rows
	-- can actually be clicked. See the note in Journal.
	close.Modal = true
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
		Store.setOpen(false)
	end)

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Size = UDim2.new(1, -28, 1, -70)
	listFrame.Position = UDim2.fromOffset(14, 58)
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

	emptyLabel = Theme.text({
		name = "Empty",
		text = "Nothing here yet — the shop opens once the products are set up.",
		size = UDim2.new(1, -40, 0, 60),
		position = UDim2.fromScale(0.5, 0.45),
		anchor = Vector2.new(0.5, 0.5),
		parent = window,
		color = Theme.colors.subtext,
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
end

return Store
