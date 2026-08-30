--!strict
--[[
	Hud — everything on screen that is not the world.

	Laid out to match the reference. The right-hand column carries the numbers
	that change while you work — the multiplier, the cash, the tool and whether
	it is running. The bag sits bottom-left, out of the way of the ground you are
	looking at. Nothing has a panel behind it: the outline on every label is what
	carries legibility against a lawn covered in bright orange leaves.

	The middle of the screen is left almost empty on purpose. A crosshair, the
	rate you are being paid, and the money each armful just earned floating up
	beside it — that is the whole feedback loop, and putting any of it in a
	corner would mean looking away from the leaves to read it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Debris = require(Shared.Config.Debris)
local Format = require(Shared.Util.Format)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local MowController = require(script.Parent.Parent.Controllers.MowController)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Theme = require(script.Parent.Theme)

local Hud = {}

local player = Players.LocalPlayer

local cashLabel: TextLabel
local multiplierLabel: TextLabel
local bagCountLabel: TextLabel
local bagCapacityLabel: TextLabel
local rateLabel: TextLabel
local toolButton: TextButton
local toolIcon: TextLabel
local toolStateLabel: TextLabel
local journalBadge: Frame
local gainHolder: Frame
local toastHolder: Frame
local bannerHolder: Frame
local fuelPanel: Frame
local fuelFill: Frame
local fuelLabel: TextLabel
local hintLabel: TextLabel

local toastOrder = 0

local NOTICE_COLORS: { [string]: Color3 } = {
	sale = Theme.colors.cash,
	stripe = Theme.colors.tips,
	locked = Theme.colors.warn,
	stall = Theme.colors.warn,
	bagFull = Theme.colors.danger,
	tooFar = Theme.colors.warn,
	purchase = Theme.colors.grass,
	reward = Theme.colors.tips,
	quest = Theme.colors.cash,
	round = Theme.colors.accent,
	denied = Theme.colors.danger,
	afford = Theme.colors.cash,
	sectionClear = Theme.colors.cash,
}

local ICONS: { [string]: string } = {
	Hand = "🧤",
	Shears = "✂️",
	Rake = "🍂",
	Mower = "🚜",
	Trimmer = "🌾",
	Blower = "💨",
	HedgeTrimmer = "🌿",
	Saw = "🪚",
	Chainsaw = "🪓",
	Grinder = "⚙️",
	Chipper = "🪵",
}

--------------------------------------------------------------------
-- Pieces
--------------------------------------------------------------------

--- A filled circle. Roblox has no circle primitive, so it is a square with its
--- corner radius run all the way to half its width.
local function circle(parent: Instance, diameter: number, color: Color3): Frame
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(diameter, diameter)
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = frame

	return frame
end

--------------------------------------------------------------------
-- Build
--------------------------------------------------------------------

local function buildCrosshair(gui: ScreenGui)
	-- A small hollow diamond: a rotated square outline, which is exactly what
	-- the reference uses. Big enough to find, small enough not to cover the leaf
	-- it is sitting on.
	local mark = Instance.new("Frame")
	mark.Name = "Crosshair"
	mark.Size = UDim2.fromOffset(11, 11)
	mark.Position = UDim2.fromScale(0.5, 0.5)
	mark.AnchorPoint = Vector2.new(0.5, 0.5)
	mark.Rotation = 45
	mark.BackgroundTransparency = 1
	mark.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Theme.colors.text
	stroke.Transparency = 0.15
	stroke.Parent = mark
end

local function buildRightColumn(gui: ScreenGui)
	local column = Instance.new("Frame")
	column.Name = "Status"
	column.Size = UDim2.fromOffset(220, 420)
	column.Position = UDim2.new(1, -20, 0, 78)
	column.AnchorPoint = Vector2.new(1, 0)
	column.BackgroundTransparency = 1
	column.Parent = gui

	multiplierLabel = Theme.text({
		name = "Multiplier",
		text = "",
		size = UDim2.fromOffset(200, 22),
		position = UDim2.new(1, -6, 0, 0),
		anchor = Vector2.new(1, 0),
		parent = column,
		align = Enum.TextXAlignment.Right,
		color = Theme.colors.tips,
		textSize = 18,
	})

	cashLabel = Theme.text({
		name = "Cash",
		text = "$0.00",
		size = UDim2.fromOffset(170, 40),
		position = UDim2.new(1, -46, 0, 22),
		anchor = Vector2.new(1, 0),
		parent = column,
		align = Enum.TextXAlignment.Right,
		textSize = 32,
	})

	-- The coin is drawn rather than an image so there is no asset to upload, and
	-- it reads at a glance as "this number is money" the way a $ alone does not.
	local coin = circle(column, 38, Theme.colors.tips)
	coin.Name = "Coin"
	coin.Position = UDim2.new(1, -2, 0, 23)
	coin.AnchorPoint = Vector2.new(1, 0)
	Theme.stroke(coin, 3, Theme.colors.outline, 0.1)

	local inner = circle(coin, 22, Color3.fromRGB(246, 196, 84))
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.AnchorPoint = Vector2.new(0.5, 0.5)

	-- The journal, with a badge when something in it is waiting to be read.
	local book = Instance.new("TextButton")
	book.Name = "Journal"
	book.Size = UDim2.fromOffset(62, 62)
	book.Position = UDim2.new(1, -14, 0, 76)
	book.AnchorPoint = Vector2.new(1, 0)
	book.BackgroundColor3 = Theme.colors.progress
	book.BorderSizePixel = 0
	book.Rotation = -6
	book.Text = "📔"
	book.TextSize = 34
	book.Font = Theme.font
	book.AutoButtonColor = true
	book.Parent = column
	Theme.corner(book, 8)
	Theme.stroke(book, 3, Theme.colors.outline, 0.05)

	journalBadge = circle(book, 22, Theme.colors.danger)
	journalBadge.Name = "Badge"
	journalBadge.Position = UDim2.fromOffset(-8, -6)
	Theme.stroke(journalBadge, 2.5, Theme.colors.outline, 0.05)

	local bang = Theme.text({
		name = "Bang",
		text = "!",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = journalBadge,
		align = Enum.TextXAlignment.Center,
		textSize = 16,
	})
	bang.TextYAlignment = Enum.TextYAlignment.Center

	local tabHint = Theme.text({
		name = "TabHint",
		text = "Tab",
		size = UDim2.fromOffset(58, 22),
		position = UDim2.new(1, -8, 0, 140),
		anchor = Vector2.new(1, 0),
		parent = column,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.outline,
		textSize = 16,
	})
	tabHint.BackgroundColor3 = Theme.colors.progress
	tabHint.BackgroundTransparency = 0
	Theme.corner(tabHint, 5)
	Theme.stroke(tabHint, 2, Theme.colors.outline, 0.2)

	-- The tool, and whether it is running. On touch this is also the button that
	-- runs it; on a mouse the camera is locked to the centre of the screen, so
	-- it can only ever be a readout.
	toolButton = Instance.new("TextButton")
	toolButton.Name = "Tool"
	toolButton.Size = UDim2.fromOffset(86, 86)
	toolButton.Position = UDim2.new(1, -6, 0, 190)
	toolButton.AnchorPoint = Vector2.new(1, 0)
	toolButton.BackgroundColor3 = Theme.colors.panelLight
	toolButton.BackgroundTransparency = 0.15
	toolButton.BorderSizePixel = 0
	toolButton.Text = ""
	toolButton.AutoButtonColor = false
	toolButton.Parent = column

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = toolButton
	Theme.stroke(toolButton, 3, Theme.colors.outline, 0.05)

	toolIcon = Theme.text({
		name = "Icon",
		text = "",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = toolButton,
		align = Enum.TextXAlignment.Center,
		textSize = 40,
	})

	toolStateLabel = Theme.text({
		name = "State",
		text = "",
		size = UDim2.fromOffset(120, 26),
		position = UDim2.new(1, -26, 0, 268),
		anchor = Vector2.new(1, 0),
		parent = column,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.cash,
		textSize = 22,
	})

	fuelPanel = Instance.new("Frame")
	fuelPanel.Name = "Fuel"
	fuelPanel.Size = UDim2.fromOffset(150, 34)
	fuelPanel.Position = UDim2.new(1, -8, 0, 304)
	fuelPanel.AnchorPoint = Vector2.new(1, 0)
	fuelPanel.BackgroundTransparency = 1
	fuelPanel.Visible = false
	fuelPanel.Parent = column

	local _, fill = Theme.bar(fuelPanel, UDim2.fromOffset(140, 13), UDim2.fromOffset(6, 18), Theme.colors.warn)
	fuelFill = fill

	fuelLabel = Theme.text({
		name = "FuelLabel",
		text = "",
		size = UDim2.fromOffset(140, 18),
		position = UDim2.fromOffset(6, 0),
		parent = fuelPanel,
		align = Enum.TextXAlignment.Right,
		textSize = 15,
	})
end

local function buildBag(gui: ScreenGui)
	local holder = Instance.new("Frame")
	holder.Name = "Bag"
	holder.Size = UDim2.fromOffset(190, 74)
	holder.Position = UDim2.new(0, 20, 1, -22)
	holder.AnchorPoint = Vector2.new(0, 1)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	-- A sack: a rounded body with a pinched neck above it.
	local sack = Instance.new("Frame")
	sack.Name = "Sack"
	sack.Size = UDim2.fromOffset(64, 56)
	sack.Position = UDim2.fromOffset(2, 16)
	sack.BackgroundColor3 = Color3.fromRGB(158, 158, 160)
	sack.BorderSizePixel = 0
	sack.Parent = holder
	Theme.corner(sack, 18)
	Theme.stroke(sack, 3, Theme.colors.outline, 0.05)

	local neck = Instance.new("Frame")
	neck.Name = "Neck"
	neck.Size = UDim2.fromOffset(26, 16)
	neck.Position = UDim2.fromOffset(21, 4)
	neck.BackgroundColor3 = Color3.fromRGB(120, 120, 124)
	neck.BorderSizePixel = 0
	neck.Parent = holder
	Theme.corner(neck, 6)
	Theme.stroke(neck, 3, Theme.colors.outline, 0.05)

	bagCapacityLabel = Theme.text({
		name = "Capacity",
		text = "0",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = sack,
		align = Enum.TextXAlignment.Center,
		textSize = 22,
	})

	bagCountLabel = Theme.text({
		name = "Count",
		text = "0",
		size = UDim2.fromOffset(110, 44),
		position = UDim2.fromOffset(74, 24),
		parent = holder,
		align = Enum.TextXAlignment.Left,
		textSize = 30,
	})
end

local function buildMiddle(gui: ScreenGui)
	rateLabel = Theme.text({
		name = "Rate",
		text = "",
		size = UDim2.fromOffset(340, 34),
		position = UDim2.fromScale(0.55, 0.05),
		anchor = Vector2.new(0.5, 0),
		parent = gui,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.cash,
		textSize = 27,
	})

	gainHolder = Instance.new("Frame")
	gainHolder.Name = "Gains"
	gainHolder.Size = UDim2.fromOffset(300, 150)
	gainHolder.Position = UDim2.fromScale(0.78, 0.09)
	gainHolder.AnchorPoint = Vector2.new(0.5, 0)
	gainHolder.BackgroundTransparency = 1
	gainHolder.Parent = gui

	hintLabel = Theme.text({
		name = "Hint",
		text = "",
		size = UDim2.fromOffset(520, 26),
		position = UDim2.fromScale(0.5, 0.86),
		anchor = Vector2.new(0.5, 0),
		parent = gui,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.tips,
		textSize = 18,
	})
end

local function build(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "MowHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.Parent = player:WaitForChild("PlayerGui")

	buildCrosshair(gui)
	buildRightColumn(gui)
	buildBag(gui)
	buildMiddle(gui)

	toastHolder = Instance.new("Frame")
	toastHolder.Name = "Toasts"
	toastHolder.Size = UDim2.fromOffset(560, 120)
	toastHolder.Position = UDim2.fromScale(0.5, 0.74)
	toastHolder.AnchorPoint = Vector2.new(0.5, 0)
	toastHolder.BackgroundTransparency = 1
	toastHolder.Parent = gui

	local toastLayout = Instance.new("UIListLayout")
	toastLayout.SortOrder = Enum.SortOrder.LayoutOrder
	toastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	toastLayout.Padding = UDim.new(0, 5)
	toastLayout.Parent = toastHolder

	bannerHolder = Instance.new("Frame")
	bannerHolder.Name = "Banners"
	bannerHolder.Size = UDim2.fromScale(1, 1)
	bannerHolder.BackgroundTransparency = 1
	bannerHolder.Parent = gui

	return gui
end

--------------------------------------------------------------------
-- Transient
--------------------------------------------------------------------

--[[
	The money an armful just earned, floating up beside the crosshair.

	Screen space rather than over the leaf itself: with a blower clearing a wide
	arc there is no single leaf it belongs to, and a number that appears in the
	same place every time is one the eye stops having to search for.
]]
function Hud.gain(amount: number)
	if amount <= 0 then
		return
	end

	local label = Theme.text({
		name = "Gain",
		text = `+{Format.cashSuffix(amount)}`,
		size = UDim2.fromOffset(240, 40),
		position = UDim2.fromOffset(30, 60),
		parent = gainHolder,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.tips,
		textSize = 30,
	})

	local info = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(label, info, { Position = UDim2.fromOffset(30, 0), TextTransparency = 1 }):Play()

	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		TweenService:Create(stroke, info, { Transparency = 1 }):Play()
	end

	task.delay(0.95, function()
		label:Destroy()
	end)
end

function Hud.toast(kind: string, message: string)
	toastOrder += 1

	local frame = Instance.new("Frame")
	frame.Name = "Toast"
	frame.Size = UDim2.fromOffset(520, 34)
	frame.BackgroundColor3 = Theme.colors.outline
	frame.BackgroundTransparency = 0.45
	frame.BorderSizePixel = 0
	frame.LayoutOrder = toastOrder
	frame.Parent = toastHolder
	Theme.corner(frame, 4)

	Theme.text({
		text = message,
		size = UDim2.new(1, -20, 1, 0),
		position = UDim2.fromOffset(10, 0),
		parent = frame,
		align = Enum.TextXAlignment.Center,
		color = NOTICE_COLORS[kind] or Theme.colors.text,
		textSize = 21,
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

--[[
	The card that drops in when a section is finished.

	A quest ticked off in the corner is easy to miss while you are staring at the
	ground; clearing a whole garage is the one moment in a run worth stopping
	the player for, so it gets a medal and the middle of the screen.
]]
function Hud.card(message: string, banner: string)
	local frame = Instance.new("Frame")
	frame.Name = "Card"
	frame.Size = UDim2.fromOffset(540, 128)
	frame.Position = UDim2.fromScale(0.5, 0.03)
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.BackgroundColor3 = Theme.colors.progress
	frame.BorderSizePixel = 0
	frame.Parent = bannerHolder
	Theme.corner(frame, 16)
	Theme.stroke(frame, 3, Theme.colors.outline, 0.1)

	local title = Theme.text({
		name = "Title",
		text = message,
		size = UDim2.new(1, -36, 0, 60),
		position = UDim2.fromOffset(18, 8),
		parent = frame,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.outline,
		textSize = 23,
	})
	title.TextWrapped = true
	local titleStroke = title:FindFirstChildOfClass("UIStroke")
	if titleStroke then
		titleStroke:Destroy()
	end

	local ribbon = Instance.new("Frame")
	ribbon.Name = "Ribbon"
	ribbon.Size = UDim2.fromOffset(400, 46)
	ribbon.Position = UDim2.new(0.5, 24, 0, 72)
	ribbon.AnchorPoint = Vector2.new(0.5, 0)
	ribbon.BackgroundColor3 = Color3.fromRGB(240, 230, 198)
	ribbon.BorderSizePixel = 0
	ribbon.Parent = frame
	Theme.corner(ribbon, 8)
	Theme.stroke(ribbon, 3, Theme.colors.outline, 0.1)

	local ribbonText = Theme.text({
		name = "Banner",
		text = banner,
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = ribbon,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.outline,
		textSize = 30,
	})
	local ribbonStroke = ribbonText:FindFirstChildOfClass("UIStroke")
	if ribbonStroke then
		ribbonStroke:Destroy()
	end

	local medal = circle(frame, 56, Theme.colors.tips)
	medal.Name = "Medal"
	medal.Position = UDim2.new(0.5, -206, 0, 66)
	medal.AnchorPoint = Vector2.new(0.5, 0)
	Theme.stroke(medal, 3, Theme.colors.outline, 0.1)

	local star = Theme.text({
		name = "Star",
		text = "★",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = medal,
		align = Enum.TextXAlignment.Center,
		color = Color3.fromRGB(232, 148, 36),
		textSize = 34,
	})
	star.TextYAlignment = Enum.TextYAlignment.Center

	task.delay(3.4, function()
		if not frame.Parent then
			return
		end
		local fade = TweenService:Create(frame, TweenInfo.new(0.4), { BackgroundTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		frame:Destroy()
	end)
end

--- Kept for callers that want the old wide strip rather than the card.
function Hud.banner(message: string)
	Hud.toast("quest", message)
end

--------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------

local function refresh()
	local state = PlayerState.get()

	cashLabel.Text = Format.cash(state.cash)

	-- Only shown once something has actually raised it, so a brand new run is
	-- not carrying a decoration that says nothing.
	multiplierLabel.Text = if state.cashMultiplier > 1.001
		then `(×{string.format("%.2f", state.cashMultiplier)})`
		else ""

	bagCountLabel.Text = Format.count(state.bagWeight)
	bagCapacityLabel.Text = Format.count(state.bagCapacity)
	bagCountLabel.TextColor3 = if state.bagWeight >= state.bagCapacity
		then Theme.colors.danger
		elseif state.bagWeight >= state.bagCapacity * 0.8 then Theme.colors.warn
		else Theme.colors.text

	-- What one leaf is worth right now, which is the number the whole economy
	-- is denominated in and the one an upgrade visibly moves.
	local perLeaf = Debris.get(Debris.Leaves).value * math.max(state.cashMultiplier, 1)
	rateLabel.Text = `{Format.cashSuffix(perLeaf)} / leaf`

	local tool = Tools.get(state.equippedTool)
	toolIcon.Text = if tool then ICONS[tool.category] or "🧰" else ""
	toolStateLabel.Text = MowController.actionLabel()
	toolStateLabel.TextColor3 = if MowController.isMowing() then Theme.colors.cash else Theme.colors.subtext
	toolButton.Visible = tool ~= nil

	local burnsFuel = tool ~= nil and tool.fuelBurn > 0
	fuelPanel.Visible = burnsFuel and state.fuelCapacity > 0
	if fuelPanel.Visible then
		local fuelFraction = math.clamp(state.fuel / state.fuelCapacity, 0, 1)
		fuelFill.Size = UDim2.fromScale(fuelFraction, 1)
		fuelFill.BackgroundColor3 = if fuelFraction <= 0.15 then Theme.colors.danger else Theme.colors.warn
		fuelLabel.Text = `{math.floor(state.fuel)} / {math.floor(state.fuelCapacity)}`
	end

	local fraction = PlayerState.bagFraction()
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
	else
		hintLabel.Text = ""
	end
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

function Hud.start()
	build()
	refresh()

	PlayerState.Changed:Connect(refresh)
	MowController.MowingChanged.Event:Connect(refresh)
	MowController.Collected.Event:Connect(Hud.gain)

	-- On touch the round tool button is the trigger as well as the readout. On a
	-- mouse the pointer is locked to the middle of the screen in first person,
	-- so there is nothing to click it with and it stays a readout.
	if UserInputService.TouchEnabled then
		toolButton.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				MowController.press()
			end
		end)
		toolButton.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				MowController.release()
			end
		end)
	end

	local notify = Remotes.event(Remotes.NOTIFY)
	notify.OnClientEvent:Connect(function(kind: any, message: any)
		if type(kind) ~= "string" or type(message) ~= "string" then
			return
		end

		if kind == "sectionClear" then
			Hud.card(message, "COMPLETED!")
		elseif kind == "quest" then
			Hud.toast(kind, `✅ {message}`)
		else
			Hud.toast(kind, message)
		end

	end)
end

--- Shows or hides the red dot on the journal.
function Hud.setJournalBadge(visible: boolean)
	journalBadge.Visible = visible
end

return Hud
