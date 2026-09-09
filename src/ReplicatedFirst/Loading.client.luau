--!strict
--[[
	The join screen — the first thing every player sees.

	Roblox's default is a dark page with the game's icon on it, and behind it
	this game assembles a whole property at runtime — ground, house, trees,
	thousands of grass clumps — so the first thing a new player saw was the
	default screen giving way to a world still building itself. This stands in
	front of all of that, in the game's own colours, and steps aside when there
	is genuinely something to look at.

	It lives in ReplicatedFirst and depends on nothing — no modules, no fonts
	beyond the built-in ones — because everything it could depend on is exactly
	what has not arrived yet. The mower is drawn out of frames for the same
	reason. The title is spelled out here rather than read from GameConfig,
	again for the same reason.

	The one rule this file must never break: it always goes away. Every wait is
	capped and there is a single deadline behind all of them, because a loading
	screen that can wedge shut is not a slow game, it is a broken one — the
	player sees a picture of a lawn for ever and has nothing to press.

	The layout is the handoff's screen 11: an amber sky over a mown band, the
	lockup, a load bar that says what it is waiting for in the game's own words,
	and a tip. What the handoff does not have, and what is kept from the screen
	before it, is the mower: it rides the leading edge of the cut, so the
	picture of the loading is the game's own verb rather than a spinner.
]]

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--- Nothing keeps this on screen longer than this, whatever else is happening.
local HARD_DEADLINE = 30

--[[
	The palette, spelled out.

	These are `Palette.luau`'s own values, written again here rather than
	required, for the reason at the top: ReplicatedStorage may not have arrived
	when this runs. If the palette moves, this file is the second place to
	change — which is the price of a screen that cannot depend on anything.
]]
local SKY_HIGH = Color3.fromRGB(255, 215, 154)
local SKY_MID = Color3.fromRGB(252, 186, 96)
local SKY_LOW = Color3.fromRGB(240, 154, 60)
local LAWN_LONG = Color3.fromRGB(111, 165, 62)
local LAWN_CUT = Color3.fromRGB(142, 194, 76)
local INK = Color3.fromRGB(24, 18, 10)
local TIPS = Color3.fromRGB(255, 206, 74)
local CASH = Color3.fromRGB(126, 226, 108)
local PROGRESS = Color3.fromRGB(255, 232, 224)
local LABEL = Color3.fromRGB(179, 156, 126)
local PANEL_TOP = Color3.fromRGB(62, 46, 32)
local PANEL_LOW = Color3.fromRGB(38, 28, 20)
local PRIMARY_TOP = Color3.fromRGB(143, 224, 124)
local PRIMARY_LOW = Color3.fromRGB(79, 184, 60)

--[[
	The game's own icon.

	`art/branding/mow-all-the-lawns-icon-512.png`, uploaded. Empty, the lockup
	still draws — the gold badge underneath carries a mower silhouette, which
	is the same badge the picture sits on — so the screen was right without it
	and is the game's own face with it.
]]
local ICON_ASSET = "rbxassetid://113572916730301"

--- A server holds twelve, which is the number the performance budget in
--- docs/GDD.md is written against. The party on a lobby pad is four.
local SERVER_SEATS = 12

local gui = Instance.new("ScreenGui")
gui.Name = "MowLoading"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 100
gui.Parent = playerGui

local back = Instance.new("Frame")
back.Name = "Back"
back.Size = UDim2.fromScale(1, 1)
back.BackgroundColor3 = SKY_MID
back.BorderSizePixel = 0
back.ClipsDescendants = true
back.Parent = gui

local sky = Instance.new("UIGradient")
sky.Rotation = 90
sky.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, SKY_HIGH),
	ColorSequenceKeypoint.new(0.55, SKY_MID),
	ColorSequenceKeypoint.new(1, SKY_LOW),
})
sky.Parent = back

--[[
	Bands of light across the sky at 115 degrees.

	The handoff asks for a repeating stripe overlay, which CSS does with one
	gradient and Roblox cannot do at all — a `UIGradient` runs once from edge to
	edge. So they are drawn: a handful of very pale rotated bars, wide enough
	that the rotation never shows an end.
]]
for index = 1, 7 do
	local band = Instance.new("Frame")
	band.Name = `Band{index}`
	band.AnchorPoint = Vector2.new(0.5, 0.5)
	band.Size = UDim2.fromScale(2.4, 0.055)
	band.Position = UDim2.fromScale(0.5, index * 0.15 - 0.1)
	band.Rotation = -25
	band.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	band.BackgroundTransparency = 0.9
	band.BorderSizePixel = 0
	band.Parent = back
end

--[[
	No clouds.

	The screen before this one had four of them drifting across a blue sky, and
	they were the only thing moving while you waited. On the amber sky they are
	four pale bars crossing seven other pale bars, and the two readings fight:
	the stripe overlay is the light, so anything else pale in the sky reads as
	a mistake in it. The mower on the lawn is the thing that moves now.
]]

--------------------------------------------------------------------
-- The lawn, and the mower going up and down it
--------------------------------------------------------------------

local lawn = Instance.new("Frame")
lawn.Name = "Lawn"
lawn.AnchorPoint = Vector2.new(0, 1)
lawn.Position = UDim2.fromScale(0, 1)
lawn.Size = UDim2.fromScale(1, 0.26)
lawn.BackgroundColor3 = LAWN_LONG
lawn.BorderSizePixel = 0
lawn.ClipsDescendants = true
lawn.Parent = back

--[[
	The cut band, which is the progress bar behind the progress bar.

	It is the game's own verb standing in for a percentage: the mower goes
	across, the grass behind it is a lighter green, and how much of the lawn is
	cut is how far along loading is. No number is invented, and the one thing
	the screen is actually waiting for is the thing it draws.
]]
local cut = Instance.new("Frame")
cut.Name = "Cut"
cut.Size = UDim2.fromScale(0, 1)
cut.BackgroundColor3 = LAWN_CUT
cut.BorderSizePixel = 0
cut.Parent = lawn

-- Mown stripes, so the cut band reads as mown rather than merely paler.
for index = 1, 10 do
	local stripe = Instance.new("Frame")
	stripe.Name = `Stripe{index}`
	stripe.BackgroundColor3 = Color3.fromRGB(126, 178, 66)
	stripe.BackgroundTransparency = 0.55
	stripe.BorderSizePixel = 0
	stripe.Size = UDim2.new(1, 0, 0, 6)
	stripe.Position = UDim2.fromOffset(0, index * 22)
	stripe.Parent = cut
end

--- The mower: a body, a darker deck, two wheels and a handle. Drawn rather
--- than uploaded, because an image here is one more thing that has to load.
local mower = Instance.new("Frame")
mower.Name = "Mower"
mower.AnchorPoint = Vector2.new(0.5, 1)
mower.Size = UDim2.fromOffset(78, 46)
mower.Position = UDim2.fromOffset(-80, 0)
mower.BackgroundTransparency = 1
mower.Parent = lawn

local deck = Instance.new("Frame")
deck.Name = "Deck"
deck.Size = UDim2.fromOffset(72, 26)
deck.Position = UDim2.fromOffset(3, 8)
deck.BackgroundColor3 = Color3.fromRGB(206, 62, 50)
deck.BorderSizePixel = 0
deck.Parent = mower
local deckRound = Instance.new("UICorner")
deckRound.CornerRadius = UDim.new(0, 8)
deckRound.Parent = deck
local deckEdge = Instance.new("UIStroke")
deckEdge.Thickness = 3
deckEdge.Color = INK
deckEdge.Parent = deck

local vent = Instance.new("Frame")
vent.Size = UDim2.fromOffset(48, 7)
vent.Position = UDim2.fromOffset(15, 14)
vent.BackgroundColor3 = Color3.fromRGB(238, 132, 118)
vent.BorderSizePixel = 0
vent.Parent = mower

local handle = Instance.new("Frame")
handle.Size = UDim2.fromOffset(4, 30)
handle.Position = UDim2.fromOffset(60, -18)
handle.BackgroundColor3 = INK
handle.BorderSizePixel = 0
handle.Rotation = 24
handle.Parent = mower

local grip = Instance.new("Frame")
grip.Size = UDim2.fromOffset(26, 4)
grip.Position = UDim2.fromOffset(62, -20)
grip.BackgroundColor3 = INK
grip.BorderSizePixel = 0
grip.Parent = mower

for _, x in { 14, 54 } do
	local wheel = Instance.new("Frame")
	wheel.Size = UDim2.fromOffset(18, 18)
	wheel.Position = UDim2.fromOffset(x, 28)
	wheel.BackgroundColor3 = Color3.fromRGB(54, 54, 58)
	wheel.BorderSizePixel = 0
	wheel.Parent = mower
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = wheel
	local hub = Instance.new("Frame")
	hub.Size = UDim2.fromOffset(7, 7)
	hub.Position = UDim2.fromOffset(5, 5)
	hub.BackgroundColor3 = Color3.fromRGB(204, 208, 214)
	hub.BorderSizePixel = 0
	hub.Parent = wheel
	local hubRound = Instance.new("UICorner")
	hubRound.CornerRadius = UDim.new(1, 0)
	hubRound.Parent = hub
end

--[[
	Clippings thrown out of the side as it passes.

	Six frames reused rather than created and destroyed: this screen runs while
	the client is at its busiest, and the one thing it must not do is make the
	thing it is waiting for take longer.
]]
local clippings = {}
for index = 1, 6 do
	local bit = Instance.new("Frame")
	bit.Name = `Clip{index}`
	bit.Size = UDim2.fromOffset(7, 5)
	bit.BackgroundColor3 = Color3.fromRGB(150, 202, 84)
	bit.BorderSizePixel = 0
	bit.Visible = false
	bit.Parent = lawn
	clippings[index] = bit
end

local nextClip = 1
local function throwClipping(atX: number, atY: number)
	local bit = clippings[nextClip]
	nextClip = nextClip % #clippings + 1
	bit.Position = UDim2.fromOffset(atX, atY)
	bit.Rotation = math.random(0, 180)
	bit.BackgroundTransparency = 0
	bit.Visible = true
	local fly = TweenService:Create(
		bit,
		TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			Position = UDim2.fromOffset(atX - math.random(30, 70), atY - math.random(20, 46)),
			Rotation = bit.Rotation + math.random(120, 300),
			BackgroundTransparency = 1,
		}
	)
	fly:Play()
end

--------------------------------------------------------------------
-- The lockup
--------------------------------------------------------------------

--[[
	One column, authored at the size the handoff draws it and scaled to fit.

	`Theme.fitToViewport` does this everywhere else in the game and cannot be
	required from here, so this is the same idea in eight lines: the column is
	built at its full size and a `UIScale` shrinks it to whatever the screen
	turns out to be. It never grows past 1 — a phone gets a smaller lockup, a
	tablet gets the drawing.
]]
local COLUMN_W, COLUMN_H = 660, 700

local column = Instance.new("Frame")
column.Name = "Lockup"
column.AnchorPoint = Vector2.new(0.5, 0.5)
column.Position = UDim2.fromScale(0.5, 0.46)
column.Size = UDim2.fromOffset(COLUMN_W, COLUMN_H)
column.BackgroundTransparency = 1
column.Parent = back

local columnScale = Instance.new("UIScale")
columnScale.Parent = column

local function fit()
	local view = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize
	if not view or view.X <= 0 then
		return
	end
	columnScale.Scale = math.min(1, (view.X - 60) / COLUMN_W, (view.Y - 120) / COLUMN_H)
end

fit()
if Workspace.CurrentCamera then
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
end

--- The icon, on the gold badge it sits on. Both, so the badge is the picture
--- until the picture arrives.
local badge = Instance.new("Frame")
badge.Name = "Badge"
badge.AnchorPoint = Vector2.new(0.5, 0)
badge.Position = UDim2.fromScale(0.5, 0)
badge.Size = UDim2.fromOffset(172, 172)
badge.BackgroundColor3 = Color3.fromRGB(255, 217, 104)
badge.BorderSizePixel = 0
badge.Parent = column
local badgeRound = Instance.new("UICorner")
badgeRound.CornerRadius = UDim.new(0, 40)
badgeRound.Parent = badge
local badgeEdge = Instance.new("UIStroke")
badgeEdge.Thickness = 6
badgeEdge.Color = INK
badgeEdge.Parent = badge
local badgeFill = Instance.new("UIGradient")
badgeFill.Rotation = 90
badgeFill.Color = ColorSequence.new(Color3.fromRGB(255, 224, 138), Color3.fromRGB(255, 176, 32))
badgeFill.Parent = badge

local badgeDrop = Instance.new("Frame")
badgeDrop.Name = "Drop"
badgeDrop.AnchorPoint = Vector2.new(0.5, 0)
badgeDrop.Position = UDim2.new(0.5, 0, 0, 9)
badgeDrop.Size = UDim2.fromOffset(172, 172)
badgeDrop.BackgroundColor3 = INK
badgeDrop.BorderSizePixel = 0
badgeDrop.ZIndex = badge.ZIndex - 1
badgeDrop.Parent = column
local dropRound = Instance.new("UICorner")
dropRound.CornerRadius = UDim.new(0, 40)
dropRound.Parent = badgeDrop

if ICON_ASSET ~= "" then
	local picture = Instance.new("ImageLabel")
	picture.Name = "Icon"
	picture.Size = UDim2.fromScale(1, 1)
	picture.BackgroundTransparency = 1
	picture.Image = ICON_ASSET
	picture.ScaleType = Enum.ScaleType.Fit
	picture.Parent = badge
	local clip = Instance.new("UICorner")
	clip.CornerRadius = UDim.new(0, 34)
	clip.Parent = picture
else
	--- A mower's silhouette, in the same two strokes the one on the lawn is
	--- drawn with, so the badge is a picture of the game rather than a blank.
	local body = Instance.new("Frame")
	body.Name = "Mark"
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Position = UDim2.fromScale(0.5, 0.54)
	body.Size = UDim2.fromOffset(104, 40)
	body.BackgroundColor3 = Color3.fromRGB(206, 62, 50)
	body.BorderSizePixel = 0
	body.Parent = badge
	local bodyRound = Instance.new("UICorner")
	bodyRound.CornerRadius = UDim.new(0, 10)
	bodyRound.Parent = body
	local bodyEdge = Instance.new("UIStroke")
	bodyEdge.Thickness = 5
	bodyEdge.Color = INK
	bodyEdge.Parent = body
	for _, x in { -30, 30 } do
		local wheel = Instance.new("Frame")
		wheel.AnchorPoint = Vector2.new(0.5, 0.5)
		wheel.Position = UDim2.new(0.5, x, 1, 2)
		wheel.Size = UDim2.fromOffset(26, 26)
		wheel.BackgroundColor3 = Color3.fromRGB(54, 54, 58)
		wheel.BorderSizePixel = 0
		wheel.Parent = body
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(1, 0)
		round.Parent = wheel
		local edge = Instance.new("UIStroke")
		edge.Thickness = 4
		edge.Color = INK
		edge.Parent = wheel
	end
end

--[[
	The title, over two lines, with the outline it wears everywhere else and
	one shadow more.

	Roblox has one `UIStroke` per label and no `text-shadow`, so the drop is a
	second copy of the words sitting nine pixels lower in ink. It is the only
	place in the design that gets two shadows, and this is how you draw the
	second one.
]]
local function titleLine(text: string, y: number, colour: Color3, thickness: number, zIndex: number): TextLabel
	local line = Instance.new("TextLabel")
	line.Name = "Title"
	line.AnchorPoint = Vector2.new(0.5, 0)
	line.Position = UDim2.new(0.5, 0, 0, y)
	line.Size = UDim2.fromOffset(COLUMN_W, 66)
	line.BackgroundTransparency = 1
	line.Font = Enum.Font.FredokaOne
	line.Text = text
	line.TextColor3 = colour
	line.TextSize = 64
	line.ZIndex = zIndex
	line.Parent = column
	if thickness > 0 then
		local edge = Instance.new("UIStroke")
		edge.Thickness = thickness
		edge.Color = INK
		edge.Parent = line
	end
	return line
end

titleLine("Mow Money,", 196 + 9, INK, 4, 1)
titleLine("Mow Problems!", 262 + 9, INK, 4, 1)
titleLine("Mow Money,", 196, Color3.fromRGB(255, 255, 255), 4, 2)
titleLine("Mow Problems!", 262, Color3.fromRGB(255, 255, 255), 4, 2)

local promise = Instance.new("TextLabel")
promise.Name = "Promise"
promise.AnchorPoint = Vector2.new(0.5, 0)
promise.Position = UDim2.new(0.5, 0, 0, 344)
promise.Size = UDim2.fromOffset(560, 44)
promise.BackgroundColor3 = INK
promise.BackgroundTransparency = 0.12
promise.Font = Enum.Font.FredokaOne
promise.Text = "CLEAR IT ALL BEFORE THE CLOCK RUNS OUT"
promise.TextColor3 = TIPS
promise.TextSize = 20
promise.ZIndex = 2
promise.Parent = column
local promiseRound = Instance.new("UICorner")
promiseRound.CornerRadius = UDim.new(1, 0)
promiseRound.Parent = promise

--------------------------------------------------------------------
-- The bar, and what it is waiting for
--------------------------------------------------------------------

local track = Instance.new("Frame")
track.Name = "Track"
track.AnchorPoint = Vector2.new(0.5, 0)
track.Position = UDim2.new(0.5, 0, 0, 418)
track.Size = UDim2.fromOffset(520, 30)
track.BackgroundColor3 = INK
track.BorderSizePixel = 0
track.ClipsDescendants = true
track.Parent = column
local trackRound = Instance.new("UICorner")
trackRound.CornerRadius = UDim.new(0, 15)
trackRound.Parent = track

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = PRIMARY_TOP
fill.BorderSizePixel = 0
fill.Parent = track
local fillRound = Instance.new("UICorner")
fillRound.CornerRadius = UDim.new(0, 15)
fillRound.Parent = fill
local fillShade = Instance.new("UIGradient")
fillShade.Rotation = 90
fillShade.Color = ColorSequence.new(PRIMARY_TOP, PRIMARY_LOW)
fillShade.Parent = fill

local function bottomLabel(name: string, text: string, x: number, align: Enum.TextXAlignment): TextLabel
	local it = Instance.new("TextLabel")
	it.Name = name
	it.Position = UDim2.fromOffset(x, 458)
	it.Size = UDim2.fromOffset(260, 26)
	it.BackgroundTransparency = 1
	it.Font = Enum.Font.FredokaOne
	it.Text = text
	it.TextColor3 = Color3.fromRGB(255, 255, 255)
	it.TextSize = 17
	it.TextXAlignment = align
	it.Parent = column
	local edge = Instance.new("UIStroke")
	edge.Thickness = 3
	edge.Color = INK
	edge.Parent = it
	return it
end

local status = bottomLabel("Status", "Growing the grass…", 70, Enum.TextXAlignment.Left)
local percent = bottomLabel("Percent", "0%", COLUMN_W - 330, Enum.TextXAlignment.Right)

--------------------------------------------------------------------
-- A tip, because the wait is the only quiet moment in the game
--------------------------------------------------------------------

local card = Instance.new("Frame")
card.Name = "Tip"
card.AnchorPoint = Vector2.new(0.5, 0)
card.Position = UDim2.new(0.5, 0, 0, 512)
card.Size = UDim2.fromOffset(620, 88)
card.BackgroundColor3 = PANEL_TOP
card.BorderSizePixel = 0
card.Parent = column
local cardRound = Instance.new("UICorner")
cardRound.CornerRadius = UDim.new(0, 18)
cardRound.Parent = card
local cardEdge = Instance.new("UIStroke")
cardEdge.Thickness = 4
cardEdge.Color = INK
cardEdge.Parent = card
local cardFill = Instance.new("UIGradient")
cardFill.Rotation = 90
cardFill.Color = ColorSequence.new(PANEL_TOP, PANEL_LOW)
cardFill.Parent = card

local cardDiamond = Instance.new("Frame")
cardDiamond.Name = "Mark"
cardDiamond.AnchorPoint = Vector2.new(0, 0.5)
cardDiamond.Position = UDim2.fromOffset(22, 26)
cardDiamond.Size = UDim2.fromOffset(12, 12)
cardDiamond.Rotation = 45
cardDiamond.BackgroundColor3 = TIPS
cardDiamond.BorderSizePixel = 0
cardDiamond.Parent = card

local tipHeading = Instance.new("TextLabel")
tipHeading.Name = "Heading"
tipHeading.Position = UDim2.fromOffset(44, 12)
tipHeading.Size = UDim2.fromOffset(120, 26)
tipHeading.BackgroundTransparency = 1
tipHeading.Font = Enum.Font.FredokaOne
tipHeading.Text = "TIP"
tipHeading.TextColor3 = LABEL
tipHeading.TextSize = 14
tipHeading.TextXAlignment = Enum.TextXAlignment.Left
tipHeading.Parent = card

local tipText = Instance.new("TextLabel")
tipText.Name = "Text"
tipText.Position = UDim2.fromOffset(22, 36)
tipText.Size = UDim2.fromOffset(576, 44)
tipText.BackgroundTransparency = 1
tipText.Font = Enum.Font.FredokaOne
tipText.Text = ""
tipText.TextColor3 = PROGRESS
tipText.TextSize = 18
tipText.TextWrapped = true
tipText.TextXAlignment = Enum.TextXAlignment.Left
tipText.TextYAlignment = Enum.TextYAlignment.Top
tipText.Parent = card

--[[
	The stripe bonus goes first, deliberately.

	It is the only skill expression in the game, and the one thing a player can
	be good at on their first lawn without buying anything.
]]
local TIPS_TEXT = {
	"Cut in long straight lines. A clean stripe pays a bonus, and it is the only thing here you can be good at.",
	"The trailer sells on approach. Walk into it — there is no button to press.",
	"Deck width beats speed. A wider tool is felt on every pass; a faster one is not.",
	"Grass too thick for your mower bogs it down. That is the shed telling you what to buy.",
	"Bare hands can shift anything. Slowly — but no run is ever stuck.",
	"Cash and tools last one run. Tips are yours to keep for good.",
	"There is a golden blade hidden in every section, and it is never needed to finish.",
	"The round bonus splits by ground actually cleared, so the person who mowed it gets paid.",
}
tipText.Text = TIPS_TEXT[1]

task.spawn(function()
	local shown = 1
	while gui.Parent do
		task.wait(4.5)
		if not gui.Parent then
			return
		end
		shown = shown % #TIPS_TEXT + 1
		local fade = TweenInfo.new(0.25, Enum.EasingStyle.Quad)
		TweenService:Create(tipText, fade, { TextTransparency = 1 }):Play()
		task.wait(0.28)
		tipText.Text = TIPS_TEXT[shown]
		TweenService:Create(tipText, fade, { TextTransparency = 0 }):Play()
	end
end)

--------------------------------------------------------------------
-- The footer: who else is here, and which build this is
--------------------------------------------------------------------

local function footPill(name: string, anchorX: number, x: number): (Frame, TextLabel)
	local pill = Instance.new("Frame")
	pill.Name = name
	pill.AnchorPoint = Vector2.new(anchorX, 1)
	pill.Position = UDim2.new(anchorX, x, 1, -22)
	pill.Size = UDim2.fromOffset(10, 34)
	pill.AutomaticSize = Enum.AutomaticSize.X
	pill.BackgroundColor3 = INK
	pill.BackgroundTransparency = 0.2
	pill.BorderSizePixel = 0
	pill.Parent = back
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = pill
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 16)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = pill
	local flow = Instance.new("UIListLayout")
	flow.FillDirection = Enum.FillDirection.Horizontal
	flow.VerticalAlignment = Enum.VerticalAlignment.Center
	flow.SortOrder = Enum.SortOrder.LayoutOrder
	flow.Padding = UDim.new(0, 9)
	flow.Parent = pill

	local text = Instance.new("TextLabel")
	text.Name = "Text"
	text.Size = UDim2.fromOffset(10, 34)
	text.AutomaticSize = Enum.AutomaticSize.X
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.Text = ""
	text.TextColor3 = PROGRESS
	text.TextSize = 16
	text.LayoutOrder = 2
	text.Parent = pill
	return pill, text
end

local crowd, crowdText = footPill("Crowd", 0, 22)
local dot = Instance.new("Frame")
dot.Name = "Dot"
dot.Size = UDim2.fromOffset(10, 10)
dot.BackgroundColor3 = CASH
dot.BorderSizePixel = 0
dot.LayoutOrder = 1
dot.Parent = crowd
local dotRound = Instance.new("UICorner")
dotRound.CornerRadius = UDim.new(1, 0)
dotRound.Parent = dot

local _, buildText = footPill("Build", 1, -22)
buildText.Text = `v{game.PlaceVersion}`
buildText.TextColor3 = LABEL

local function countHeads()
	local here = #Players:GetPlayers()
	crowdText.Text = if here <= 1
		then "First one here"
		else `{here} of {SERVER_SEATS} already working`
end

countHeads()
Players.PlayerAdded:Connect(countHeads)
Players.PlayerRemoving:Connect(countHeads)

--------------------------------------------------------------------
-- The drive, and the wait
--------------------------------------------------------------------

local progress = 0
local finished = false

--- Where the cut band should be, eased so it never jumps backwards.
local shown = 0

task.spawn(function()
	local lastThrow = 0
	while gui.Parent and not finished do
		local dt = RunService.RenderStepped:Wait()
		shown += (progress - shown) * math.min(dt * 2.2, 1)
		cut.Size = UDim2.fromScale(shown, 1)
		fill.Size = UDim2.fromScale(shown, 1)
		percent.Text = `{math.floor(shown * 100)}%`

		--[[
			The mower rides the leading edge of the cut, not a timer.

			Tying it to the band means it is always exactly where the grass
			stops being long, so the picture never contradicts itself — no
			mower out in front of nothing, no cut grass with no mower.
		]]
		local width = lawn.AbsoluteSize.X
		local height = lawn.AbsoluteSize.Y
		mower.Position = UDim2.fromOffset(shown * width, height * 0.86)

		local now = os.clock()
		if shown > 0.02 and shown < 0.99 and now - lastThrow > 0.09 then
			lastThrow = now
			throwClipping(shown * width - 30, height * 0.86 - 26)
		end
	end
end)

--[[
	What it waits for, and the promise that it stops waiting.

	Three things have to be true: the engine finished replicating, the server
	built a world to stand in (the lobby counts — it is a property), and this
	player has a character on it.

	The character wait used to be written as

		local timeout = task.delay(10, function() end)
		player.CharacterAdded:Wait()

	which caps nothing at all. `task.delay` schedules an empty function; it
	does not interrupt the `Wait` below it. Worse, the check and the wait are
	two separate steps, so a character that arrives between them fires the
	event before anything is listening and the `Wait` never returns. That is a
	loading screen wedged shut for ever, and it is likelier on a fast server
	than a slow one, which is why it never showed up in Studio.

	`waitFor` polls a condition against a deadline instead. It cannot miss an
	event because it does not listen for one.
]]
local startedAt = os.clock()

local function waitFor(what: () -> boolean, seconds: number): boolean
	local until_ = os.clock() + seconds
	while os.clock() < until_ do
		if what() then
			return true
		end
		if os.clock() - startedAt > HARD_DEADLINE then
			return false
		end
		task.wait(0.1)
	end
	return false
end

task.spawn(function()
	-- The backstop behind every other cap: whatever happens above, the screen
	-- is gone by now.
	task.wait(HARD_DEADLINE)
	finished = true
end)

task.spawn(function()
	progress = 0.08
	if not game:IsLoaded() then
		waitFor(function()
			return game:IsLoaded()
		end, 15)
	end

	progress = 0.34
	status.Text = "Rolling out the lawns…"
	waitFor(function()
		return Workspace:FindFirstChild("MowWorld") ~= nil or Workspace:FindFirstChild("MowLobby") ~= nil
	end, 20)

	progress = 0.68
	status.Text = "Fetching your mower…"
	waitFor(function()
		return player.Character ~= nil and player.Character:FindFirstChild("HumanoidRootPart") ~= nil
	end, 12)

	progress = 1
	status.Text = "Off you go!"
	-- A beat, so the last of the lawn is visibly cut before it fades.
	task.wait(0.65)
	finished = true
end)

task.spawn(function()
	while gui.Parent and not finished do
		task.wait(0.1)
	end
	if not gui.Parent then
		return
	end

	local fade = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, thing in back:GetDescendants() do
		if thing:IsA("GuiObject") then
			TweenService:Create(thing, fade, { BackgroundTransparency = 1 }):Play()
			if thing:IsA("TextLabel") then
				TweenService:Create(thing, fade, { TextTransparency = 1 }):Play()
			end
		elseif thing:IsA("UIStroke") then
			TweenService:Create(thing, fade, { Transparency = 1 }):Play()
		end
	end
	TweenService:Create(back, fade, { BackgroundTransparency = 1 }):Play()
	task.wait(0.6)
	gui:Destroy()
end)
