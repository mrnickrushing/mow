--!strict
--[[
	The loading screen.

	Roblox's default is a dark page with the game's icon on it, and behind it
	this game assembles a whole property at runtime — ground, house, trees,
	thousands of grass clumps — so the first thing a new player saw was the
	default screen giving way to a world still building itself. This stands in
	front of all of that, in the game's own colours, and steps aside only when
	there is genuinely something to look at: the game replicated, the world
	built, and a character standing on it.

	It lives in ReplicatedFirst and depends on nothing, because everything it
	could depend on is exactly what has not arrived yet. The title is spelled
	out here rather than read from GameConfig for the same reason.
]]

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "MowLoading"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 100
gui.Parent = playerGui

-- The sky, then the lawn: the same picture the game itself opens on.
local back = Instance.new("Frame")
back.Name = "Back"
back.Size = UDim2.fromScale(1, 1)
back.BackgroundColor3 = Color3.fromRGB(122, 194, 230)
back.BorderSizePixel = 0
back.Parent = gui

local lawn = Instance.new("Frame")
lawn.Name = "Lawn"
lawn.AnchorPoint = Vector2.new(0, 1)
lawn.Position = UDim2.fromScale(0, 1)
lawn.Size = UDim2.fromScale(1, 0.42)
lawn.BackgroundColor3 = Color3.fromRGB(112, 160, 58)
lawn.BorderSizePixel = 0
lawn.Parent = back

local lawnShade = Instance.new("UIGradient")
lawnShade.Rotation = 90
lawnShade.Color = ColorSequence.new(Color3.fromRGB(138, 188, 74), Color3.fromRGB(96, 142, 52))
lawnShade.Parent = lawn

--[[
	The mown stripe: a lighter band that sweeps across the lawn over and over.

	It is the game's own verb doing the waiting — a lawn being mowed — and a
	thing visibly moving is what says "loading" without a percentage it would
	only have to invent.
]]
local stripe = Instance.new("Frame")
stripe.Name = "Stripe"
stripe.Size = UDim2.fromScale(0.22, 1)
stripe.Position = UDim2.fromScale(-0.25, 0)
stripe.BackgroundColor3 = Color3.fromRGB(160, 206, 92)
stripe.BackgroundTransparency = 0.25
stripe.BorderSizePixel = 0
stripe.Parent = lawn

task.spawn(function()
	while gui.Parent do
		stripe.Position = UDim2.fromScale(-0.25, 0)
		local sweep = TweenService:Create(
			stripe,
			TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ Position = UDim2.fromScale(1.05, 0) }
		)
		sweep:Play()
		sweep.Completed:Wait()
		task.wait(0.2)
	end
end)

local title = Instance.new("TextLabel")
title.Name = "Title"
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.fromScale(0.5, 0.36)
title.Size = UDim2.fromScale(0.9, 0.18)
title.BackgroundTransparency = 1
title.Font = Enum.Font.FredokaOne
title.Text = "MOW MONEY, MOW PROBLEMS!"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextScaled = true
title.Parent = back

local titleStroke = Instance.new("UIStroke")
titleStroke.Thickness = 4
titleStroke.Color = Color3.fromRGB(24, 18, 10)
titleStroke.Parent = title

local word = Instance.new("TextLabel")
word.Name = "Word"
word.AnchorPoint = Vector2.new(0.5, 0.5)
word.Position = UDim2.fromScale(0.5, 0.5)
word.Size = UDim2.fromScale(0.8, 0.06)
word.BackgroundTransparency = 1
word.Font = Enum.Font.GothamBold
word.Text = "Rolling out the lawns…"
word.TextColor3 = Color3.fromRGB(255, 250, 235)
word.TextScaled = true
word.Parent = back

local wordStroke = Instance.new("UIStroke")
wordStroke.Thickness = 2.5
wordStroke.Color = Color3.fromRGB(24, 18, 10)
wordStroke.Parent = word

--[[
	Step aside when there is a game to see, and not a moment sooner.

	Three things have to be true: the engine finished replicating, the server
	has built a world (the lobby counts — it is a property you stand on), and
	this player has a character standing in it. Each wait is capped, because a
	loading screen that can wedge shut is worse than the pop-in it hides.
]]
task.spawn(function()
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
	Workspace:WaitForChild("MowWorld", 20)
	if not player.Character then
		local timeout = task.delay(10, function() end)
		player.CharacterAdded:Wait()
		task.cancel(timeout)
	end
	-- A beat for the first render of the world behind the curtain.
	task.wait(0.6)

	local fade = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(back, fade, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(lawn, fade, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(stripe, fade, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(title, fade, { TextTransparency = 1 }):Play()
	TweenService:Create(word, fade, { TextTransparency = 1 }):Play()
	TweenService:Create(titleStroke, fade, { Transparency = 1 }):Play()
	local last = TweenService:Create(wordStroke, fade, { Transparency = 1 })
	last:Play()
	last.Completed:Wait()
	gui:Destroy()
end)
