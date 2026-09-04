--!strict
--[[
	The loading screen.

	Roblox's default is a dark page with the game's icon on it, and behind it
	this game assembles a whole property at runtime — ground, house, trees,
	thousands of grass clumps — so the first thing a new player saw was the
	default screen giving way to a world still building itself. This stands in
	front of all of that, in the game's own colours, and steps aside when there
	is genuinely something to look at.

	It lives in ReplicatedFirst and depends on nothing — no modules, no uploaded
	images, no fonts beyond the built-in ones — because everything it could
	depend on is exactly what has not arrived yet. The mower is drawn out of
	frames for the same reason. The title is spelled out here rather than read
	from GameConfig, again for the same reason.

	The one rule this file must never break: it always goes away. Every wait is
	capped and there is a single deadline behind all of them, because a loading
	screen that can wedge shut is not a slow game, it is a broken one — the
	player sees a picture of a lawn for ever and has nothing to press.
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

local SKY_TOP = Color3.fromRGB(122, 194, 230)
local SKY_LOW = Color3.fromRGB(196, 226, 240)
local LAWN_LONG = Color3.fromRGB(104, 150, 54)
local LAWN_CUT = Color3.fromRGB(146, 196, 78)
local INK = Color3.fromRGB(24, 18, 10)

local gui = Instance.new("ScreenGui")
gui.Name = "MowLoading"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 100
gui.Parent = playerGui

local back = Instance.new("Frame")
back.Name = "Back"
back.Size = UDim2.fromScale(1, 1)
back.BackgroundColor3 = SKY_TOP
back.BorderSizePixel = 0
back.Parent = gui

local sky = Instance.new("UIGradient")
sky.Rotation = 90
sky.Color = ColorSequence.new(SKY_TOP, SKY_LOW)
sky.Parent = back

--[[
	A few clouds, drifting.

	Cheap parallax: the only thing behind the lawn that moves, so the sky does
	not read as a flat colour while you wait.
]]
for index = 1, 4 do
	local cloud = Instance.new("Frame")
	cloud.Name = `Cloud{index}`
	cloud.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	cloud.BackgroundTransparency = 0.25
	cloud.BorderSizePixel = 0
	cloud.Size = UDim2.fromScale(0.16 + index * 0.03, 0.05)
	cloud.Position = UDim2.fromScale(-0.3, 0.08 + index * 0.07)
	cloud.Parent = back
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = cloud

	task.spawn(function()
		local speed = 22 + index * 7
		while gui.Parent do
			cloud.Position = UDim2.fromScale(-0.3, cloud.Position.Y.Scale)
			local drift = TweenService:Create(
				cloud,
				TweenInfo.new(speed, Enum.EasingStyle.Linear),
				{ Position = UDim2.fromScale(1.3, cloud.Position.Y.Scale) }
			)
			drift:Play()
			drift.Completed:Wait()
		end
	end)
end

--------------------------------------------------------------------
-- The lawn, and the mower going up and down it
--------------------------------------------------------------------

local lawn = Instance.new("Frame")
lawn.Name = "Lawn"
lawn.AnchorPoint = Vector2.new(0, 1)
lawn.Position = UDim2.fromScale(0, 1)
lawn.Size = UDim2.fromScale(1, 0.46)
lawn.BackgroundColor3 = LAWN_LONG
lawn.BorderSizePixel = 0
lawn.ClipsDescendants = true
lawn.Parent = back

--[[
	The cut band, which is the progress bar.

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
for index = 1, 14 do
	local stripe = Instance.new("Frame")
	stripe.Name = `Stripe{index}`
	stripe.BackgroundColor3 = Color3.fromRGB(126, 178, 66)
	stripe.BackgroundTransparency = 0.55
	stripe.BorderSizePixel = 0
	stripe.Size = UDim2.new(1, 0, 0, 6)
	stripe.Position = UDim2.new(0, 0, 0, index * 22)
	stripe.Parent = cut
end

--- The mower: a body, a darker deck, two wheels and a handle. Drawn rather
--- than uploaded, because an image here is one more thing that has to load.
local mower = Instance.new("Frame")
mower.Name = "Mower"
mower.AnchorPoint = Vector2.new(0.5, 1)
mower.Size = UDim2.fromOffset(78, 46)
mower.Position = UDim2.new(0, -80, 0, 0)
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
-- Words
--------------------------------------------------------------------

local function label(name: string, text: string, y: number, height: number, size: number, thickness: number): TextLabel
	local it = Instance.new("TextLabel")
	it.Name = name
	it.AnchorPoint = Vector2.new(0.5, 0.5)
	it.Position = UDim2.fromScale(0.5, y)
	it.Size = UDim2.fromScale(0.86, height)
	it.BackgroundTransparency = 1
	it.Font = Enum.Font.GothamBlack
	it.Text = text
	it.TextColor3 = Color3.fromRGB(255, 252, 244)
	it.TextScaled = true
	it.Parent = back
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness
	stroke.Color = INK
	stroke.Parent = it
	local _ = size
	return it
end

local title = label("Title", "MOW MONEY, MOW PROBLEMS!", 0.30, 0.11, 40, 4)
local status = label("Status", "Waking the neighbourhood…", 0.42, 0.045, 20, 2.5)
status.Font = Enum.Font.GothamBold

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

		--[[
			The mower rides the leading edge of the cut, not a timer.

			Tying it to the band means it is always exactly where the grass
			stops being long, so the picture never contradicts itself — no
			mower out in front of nothing, no cut grass with no mower.
		]]
		local width = lawn.AbsoluteSize.X
		local height = lawn.AbsoluteSize.Y
		mower.Position = UDim2.fromOffset(shown * width, height * 0.72)

		local now = os.clock()
		if shown > 0.02 and shown < 0.99 and now - lastThrow > 0.09 then
			lastThrow = now
			throwClipping(shown * width - 30, height * 0.72 - 26)
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
