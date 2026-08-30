--!strict
--[[
	StationController — the writing on the upgrade boards.

	The server builds the boards and owns the purchase; what it cannot write is
	the text, because "250 --> 300 / $2.00" is about *your* bag, and one shared
	sign cannot be right for two players at once. So each client hangs its own
	billboard on each board and keeps it current with its own levels.

	The same pass covers the cash gates: their price is the same for everyone
	and the server draws it, but the affordability tint — green when you can pay,
	grey when you cannot — is personal, so it is applied here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Upgrades = require(Shared.Config.Upgrades)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Theme = require(script.Parent.Parent.UI.Theme)

local StationController = {}

local player = Players.LocalPlayer

type Card = {
	name: TextLabel,
	change: TextLabel,
	price: TextLabel,
}

local cards: { [string]: Card } = {}
local watched: Folder? = nil

local function makeLabel(parent: Instance, size: UDim2, position: UDim2, textSize: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.Font = Theme.font
	label.TextSize = textSize
	label.TextColor3 = Theme.colors.text
	label.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = Theme.colors.outline
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	return label
end

local function attach(board: BasePart, upgradeId: string)
	local gui = Instance.new("BillboardGui")
	gui.Name = "StationText"
	gui.Size = UDim2.fromOffset(190, 96)
	gui.StudsOffset = Vector3.new(0, 3.6, 0)
	gui.MaxDistance = 70
	gui.LightInfluence = 0
	gui.Adornee = board
	gui.Parent = board

	cards[upgradeId] = {
		name = makeLabel(gui, UDim2.new(1, 0, 0, 30), UDim2.fromOffset(0, 0), 24),
		change = makeLabel(gui, UDim2.new(1, 0, 0, 26), UDim2.fromOffset(0, 32), 20),
		price = makeLabel(gui, UDim2.new(1, 0, 0, 26), UDim2.fromOffset(0, 60), 20),
	}
end

local function refresh()
	local state = PlayerState.get()

	for upgradeId, card in cards do
		local def = Upgrades.get(upgradeId)
		if not def then
			continue
		end

		local level = state.upgrades[upgradeId] or 0
		local cost = Upgrades.costAt(def, level)

		card.name.Text = def.name

		if not cost then
			card.change.Text = "MAX"
			card.change.TextColor3 = Theme.colors.tips
			card.price.Text = ""
			continue
		end

		-- Current value --> next value, in the stat's own units, which is what
		-- makes the purchase legible: not "+1 level" but "250 --> 300".
		local now = Upgrades.valueAt(def, level)
		local next_ = Upgrades.valueAt(def, level + 1)
		card.change.Text = `{Format.count(now)} --> {Format.count(next_)}`
		card.change.TextColor3 = Theme.colors.text

		card.price.Text = Format.cash(cost)
		card.price.TextColor3 = if state.cash >= cost then Theme.colors.cash else Theme.colors.subtext
	end
end

--- Finds the station boards whenever a fresh world appears, and again when the
--- next run rebuilds them.
local function adopt(folder: Folder)
	if watched == folder then
		return
	end
	watched = folder
	table.clear(cards)

	for _, child in folder:GetChildren() do
		local upgradeId = child:GetAttribute("UpgradeId")
		if child:IsA("BasePart") and type(upgradeId) == "string" then
			attach(child, upgradeId)
		end
	end
	folder.ChildAdded:Connect(function(child)
		local upgradeId = child:GetAttribute("UpgradeId")
		if child:IsA("BasePart") and type(upgradeId) == "string" then
			attach(child, upgradeId)
			refresh()
		end
	end)
	refresh()
end

function StationController.start()
	local function scan()
		local world = Workspace:FindFirstChild("MowWorld")
		local stations = world and world:FindFirstChild("UpgradeStations")
		if stations and stations:IsA("Folder") then
			adopt(stations)
		end
	end

	scan()
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "MowWorld" then
			task.defer(scan)
		end
	end)
	task.spawn(function()
		-- The stations folder appears a beat after the world folder does, so a
		-- lazy re-scan covers joining mid-build.
		while watched == nil do
			task.wait(1)
			scan()
		end
	end)

	PlayerState.Changed:Connect(refresh)
end

return StationController
