--!strict
--[[
	Hud — cash, the bag meter, the equipped tool and transient notifications.

	The bag meter is the single most important element on screen: the whole early
	game is a loop of filling it and walking back, so it turns amber as it fills
	and red when it is full, and shows what the load is worth.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Theme = require(script.Parent.Theme)

local Hud = {}

local player = Players.LocalPlayer
local cashLabel: TextLabel
local tipsLabel: TextLabel
local bagFill: Frame
local bagLabel: TextLabel
local bagValueLabel: TextLabel
local toolLabel: TextLabel
local sellLabel: TextLabel
local hintLabel: TextLabel
local toastHolder: Frame
local fuelPanel: Frame
local fuelFill: Frame
local fuelLabel: TextLabel

local NOTICE_COLORS: { [string]: Color3 } = {
	sale = Theme.colors.cash,
	stripe = Theme.colors.tips,
	locked = Theme.colors.warn,
	stall = Theme.colors.warn,
	bagFull = Theme.colors.danger,
	tooFar = Theme.colors.warn,
	purchase = Theme.colors.grass,
	reward = Theme.colors.tips,
}

--------------------------------------------------------------------
-- Build
--------------------------------------------------------------------

local function build(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "MowHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Wallet, top right, where the reference keeps its running total.
	cashLabel = Theme.text({
		name = "Cash",
		text = "$0.00",
		size = UDim2.fromOffset(240, 40),
		position = UDim2.new(1, -22, 0, 84),
		anchor = Vector2.new(1, 0),
		parent = gui,
		align = Enum.TextXAlignment.Right,
		textSize = 32,
	})
	tipsLabel = Theme.text({
		name = "Tips",
		text = "0 tips",
		size = UDim2.fromOffset(240, 26),
		position = UDim2.new(1, -22, 0, 124),
		anchor = Vector2.new(1, 0),
		parent = gui,
		color = Theme.colors.tips,
		align = Enum.TextXAlignment.Right,
		textSize = 20,
	})

	-- Sell rate, so the value of a bagful is always on screen.
	sellLabel = Theme.text({
		name = "SellRate",
		text = "",
		size = UDim2.fromOffset(280, 26),
		position = UDim2.new(1, -22, 0, 152),
		anchor = Vector2.new(1, 0),
		parent = gui,
		color = Theme.colors.cash,
		align = Enum.TextXAlignment.Right,
		textSize = 19,
	})

	-- Bag, bottom left: a sack icon with what is in it, as in the reference.
	local bag = Instance.new("Frame")
	bag.Name = "Bag"
	bag.Size = UDim2.fromOffset(300, 74)
	bag.Position = UDim2.new(0, 18, 1, -18)
	bag.AnchorPoint = Vector2.new(0, 1)
	bag.BackgroundTransparency = 1
	bag.Parent = gui

	local sack = Instance.new("TextLabel")
	sack.Name = "Icon"
	sack.Text = "🧺"
	sack.Size = UDim2.fromOffset(52, 52)
	sack.Position = UDim2.fromOffset(0, 4)
	sack.BackgroundTransparency = 1
	sack.TextSize = 42
	sack.Font = Theme.font
	sack.Parent = bag

	bagLabel = Theme.text({
		name = "Amount",
		text = "0 / 0",
		size = UDim2.fromOffset(230, 30),
		position = UDim2.fromOffset(58, 2),
		parent = bag,
		textSize = 26,
	})
	bagValueLabel = Theme.text({
		name = "Value",
		text = "$0.00",
		size = UDim2.fromOffset(230, 24),
		position = UDim2.fromOffset(58, 32),
		parent = bag,
		color = Theme.colors.cash,
		textSize = 20,
	})
	local _, fill = Theme.bar(bag, UDim2.fromOffset(240, 12), UDim2.fromOffset(58, 58), Theme.colors.bag)
	bagFill = fill

	-- Equipped tool, above the hotbar in the centre.
	toolLabel = Theme.text({
		name = "Tool",
		text = "Hand Shears",
		size = UDim2.fromOffset(420, 30),
		position = UDim2.new(0.5, 0, 1, -96),
		anchor = Vector2.new(0.5, 1),
		parent = gui,
		align = Enum.TextXAlignment.Center,
		textSize = 24,
	})

	-- Fuel, only shown while holding something that burns it.
	fuelPanel = Theme.panel({
		name = "Fuel",
		size = UDim2.fromOffset(250, 52),
		position = UDim2.new(0, 18, 1, -102),
		anchor = Vector2.new(0, 1),
		parent = gui,
	})
	Theme.text({
		name = "Title",
		text = "FUEL",
		size = UDim2.fromOffset(50, 16),
		position = UDim2.fromOffset(12, 6),
		parent = fuelPanel,
		color = Theme.colors.subtext,
		textSize = 12,
	})
	fuelLabel = Theme.text({
		name = "Amount",
		text = "",
		size = UDim2.new(1, -24, 0, 16),
		position = UDim2.fromOffset(12, 6),
		parent = fuelPanel,
		color = Theme.colors.subtext,
		align = Enum.TextXAlignment.Right,
		textSize = 12,
		bold = false,
	})
	local _, fuel = Theme.bar(fuelPanel, UDim2.new(1, -24, 0, 16), UDim2.fromOffset(12, 26), Theme.colors.warn)
	fuelFill = fuel

	-- Contextual hint just above the bag meter.
	hintLabel = Theme.text({
		name = "Hint",
		text = "",
		size = UDim2.fromOffset(560, 30),
		position = UDim2.new(0.5, 0, 1, -128),
		anchor = Vector2.new(0.5, 1),
		parent = gui,
		color = Theme.colors.tips,
		align = Enum.TextXAlignment.Center,
		textSize = 22,
	})

	-- Toast column, right side.
	toastHolder = Instance.new("Frame")
	toastHolder.Name = "Toasts"
	toastHolder.Size = UDim2.fromOffset(300, 320)
	toastHolder.Position = UDim2.new(1, -16, 0, 16)
	toastHolder.AnchorPoint = Vector2.new(1, 0)
	toastHolder.BackgroundTransparency = 1
	toastHolder.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.Padding = UDim.new(0, 6)
	layout.Parent = toastHolder

	return gui
end

--------------------------------------------------------------------
-- Toasts
--------------------------------------------------------------------

local toastOrder = 0

function Hud.toast(kind: string, message: string)
	toastOrder += 1

	local frame = Theme.panel({
		name = "Toast",
		size = UDim2.fromOffset(292, 38),
		position = UDim2.fromScale(0, 0),
		parent = toastHolder,
		transparency = 0.1,
	})
	frame.LayoutOrder = toastOrder

	Theme.text({
		text = message,
		size = UDim2.new(1, -20, 1, 0),
		position = UDim2.fromOffset(12, 0),
		parent = frame,
		color = NOTICE_COLORS[kind] or Theme.colors.text,
		textSize = 15,
	})

	task.delay(2.6, function()
		if not frame.Parent then
			return
		end
		local fade = TweenService:Create(frame, TweenInfo.new(0.35), { BackgroundTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		frame:Destroy()
	end)
end

--------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------

local function refresh()
	local state = PlayerState.get()

	cashLabel.Text = Format.cash(state.cash)
	tipsLabel.Text = `{Format.count(state.tips)} tips`

	local fraction = PlayerState.bagFraction()
	bagFill.Size = UDim2.fromScale(fraction, 1)
	bagFill.BackgroundColor3 = if fraction >= 1
		then Theme.colors.danger
		elseif fraction >= 0.75 then Theme.colors.warn
		else Theme.colors.grass

	bagLabel.Text = `{Format.count(state.bagWeight)} / {Format.count(state.bagCapacity)}`
	bagValueLabel.Text = Format.cash(state.bagValue)

	-- What the current load is worth per unit, so the bag always has a price.
	if state.bagWeight > 0 then
		sellLabel.Text = `Sell: {Format.cash(state.bagValue)}`
	else
		sellLabel.Text = ""
	end

	local tool = Tools.get(state.equippedTool)
	toolLabel.Text = if tool then tool.name else "Nothing equipped"

	-- Only surface fuel for gear that actually burns it, so a player on hand
	-- shears is never shown a gauge that will not move.
	local burnsFuel = tool ~= nil and tool.fuelBurn > 0
	fuelPanel.Visible = burnsFuel and state.fuelCapacity > 0
	if fuelPanel.Visible then
		local fuelFraction = math.clamp(state.fuel / state.fuelCapacity, 0, 1)
		fuelFill.Size = UDim2.fromScale(fuelFraction, 1)
		fuelFill.BackgroundColor3 = if fuelFraction <= 0.15 then Theme.colors.danger else Theme.colors.warn
		fuelLabel.Text = `{math.floor(state.fuel)} / {math.floor(state.fuelCapacity)}`
	end

	local rideable = tool ~= nil and tool.vehicle ~= nil
	if state.rentalSecondsLeft > 0 and state.rentalToolId ~= "" then
		local rented = Tools.get(state.rentalToolId)
		hintLabel.Text = `{if rented then rented.name else "Rental"} — {Format.clock(state.rentalSecondsLeft)} left`
	elseif fraction >= 1 then
		hintLabel.Text = "Bag full — head to the trailer"
	elseif burnsFuel and state.fuel <= 0 then
		hintLabel.Text = "Out of fuel — refill at the shed"
	elseif rideable then
		hintLabel.Text = "Press F to get on the mower"
	elseif fraction >= 0.85 then
		hintLabel.Text = "Bag nearly full"
	else
		hintLabel.Text = ""
	end
end

function Hud.start()
	build()
	refresh()

	PlayerState.Changed:Connect(refresh)

	local notify = Remotes.event(Remotes.NOTIFY)
	notify.OnClientEvent:Connect(function(kind: any, message: any)
		if type(kind) == "string" and type(message) == "string" then
			Hud.toast(kind, message)
		end
	end)
end

return Hud
