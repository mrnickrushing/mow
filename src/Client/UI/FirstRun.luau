--!strict
--[[
	FirstRun — the loop, taught without a tour.

	Screen 6 of the handoff, and its idea is one sentence: **the HUD arrives a
	piece at a time.** The first thing a new player sees is a lawn, a
	completion bar, and one lit button; the bag turns up when there is
	something in it, the hotbar and the rail when there is something to buy,
	and the rest when the fourth step has been reached. Nothing is explained
	before it exists.

	The four steps are the GDD's own, in its own order, and the last one is
	deliberately not a shop tour:

	    1  hold to work
	    2  fill the bag, walk to the trailer
	    3  buy a wider deck
	    4  hit the overgrowth wall

	Ending on the wall is the point. A tour of the shed teaches a player where
	the buttons are; walking a mower into grass it cannot cut teaches them what
	the shed is *for*, and they go there on their own. That is also why every
	step's exit condition is something the player does rather than a button
	they press: the only button on the card is SKIP.

	Walked once. The profile remembers, exactly as it does for the opening.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Loop = require(Shared.Util.Loop)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Hud = require(script.Parent.Hud)
local RoundBar = require(script.Parent.RoundBar)
local RunOnly = require(script.Parent.RunOnly)
local Theme = require(script.Parent.Theme)

local FirstRun = {}

local player = Players.LocalPlayer

--[[
	A step: what it says, what has to happen, and how much of the HUD is up
	while it is on screen.

	`reveal` is cumulative in spirit but written out in full, because a list
	that says exactly what is on the screen can be checked against the handoff
	and a list of additions cannot.
]]
type Step = {
	title: string,
	body: string,
	exit: string,
	reveal: { string },
	--- True once the player has done the thing. Polled, because every one of
	--- these is a fact about player state rather than an event.
	done: () -> boolean,
}

--- The widest deck bare hands have. Anything past it is "a wider deck".
local HANDS_DECK = 1

--[[
	How long step four waits before it lets go.

	The wall is the one step whose condition the player cannot reach by
	deciding to: it needs grass the tool in their hand will not cut, and on
	the front lawn with the right mower that combination may simply not come
	up. So the last step says its sentence, hands back the rest of the HUD —
	it is the last step, there is nothing left to hold — and gets out of the
	way after two and a half minutes whether the wall was met or not.
]]
local WALL_PATIENCE = 150

local overgrowthSeen = false

local STEPS: { Step } = {
	{
		title = "Hold to work",
		body = "Hold the button and walk. Debris comes up in a swath as wide as your tool.",
		exit = "Cut anything",
		reveal = { "hero", "tool" },
		done = function()
			return PlayerState.get().bagWeight > 0
		end,
	},
	{
		title = "Fill the bag, walk to the trailer",
		body = "The bag is small and it will fill. Walk it back — the trailer sells on approach. No prompt, no queue.",
		exit = "Sell a load",
		reveal = { "hero", "tool", "bag" },
		done = function()
			return PlayerState.get().cash > 0
		end,
	},
	{
		title = "Buy a wider deck",
		body = "Open the shed and spend it. Width is felt far more than speed — two tiles a pass is twice the lawn.",
		exit = "Own something wider than your hands",
		reveal = { "hero", "tool", "bag", "hotbar", "rail", "toasts" },
		done = function()
			for id in PlayerState.get().ownedTools do
				local tool = Tools.get(id)
				if tool and tool.deck > HANDS_DECK then
					return true
				end
			end
			return false
		end,
	},
	{
		title = "Then hit the wall",
		body = "Somewhere out there is grass too thick for what you are holding. It will not cut. That is the shed telling you what to buy next.",
		exit = "Find ground your tool refuses",
		--[[
			Everything except the objective panel, which stays down until the
			card is gone.

			Screen 6 does not draw it, and the reason is the card: for as long
			as the walkthrough is on screen it *is* the objective, and two
			panels each telling a new player what to do next is one too many.
			`RoundBar.setReduced` is what holds it, and it lets go when the
			bar goes back to three rows.
		]]
		reveal = { "hero", "tool", "bag", "hotbar", "rail", "toasts", "fuel", "rate" },
		done = function()
			return overgrowthSeen
		end,
	},
}

local gui: ScreenGui
local shadeGui: ScreenGui
local card: Frame
local badgeLabel: TextLabel
local titleLabel: TextLabel
local bodyLabel: TextLabel
local exitLabel: TextLabel
local pips: { Frame } = {}

local step = 0
local running = false
local finished = false
local stepStarted = 0

--------------------------------------------------------------------
-- Chrome
--------------------------------------------------------------------

local CARD_WIDTH = 660
local CARD_BOTTOM = 70

local function build()
	--[[
		Two screens, because the dim goes under the HUD and the card goes over
		it. One `ScreenGui` cannot be both, and a dim drawn over the tool
		button would put out the one thing the first step is lighting.
	]]
	shadeGui = Instance.new("ScreenGui")
	shadeGui.Name = "MowFirstRunShade"
	shadeGui.ResetOnSpawn = false
	shadeGui.Enabled = false
	shadeGui.IgnoreGuiInset = true
	shadeGui.DisplayOrder = -1
	shadeGui.Parent = player:WaitForChild("PlayerGui")

	local shade = Instance.new("Frame")
	shade.Name = "Shade"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.fromRGB(20, 14, 8)
	shade.BackgroundTransparency = 0.5
	shade.BorderSizePixel = 0
	shade.Parent = shadeGui

	gui = Instance.new("ScreenGui")
	gui.Name = "MowFirstRun"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 8
	gui.Parent = player.PlayerGui

	card = Theme.chunkPanel({
		name = "Coach",
		size = UDim2.fromOffset(CARD_WIDTH, 196),
		position = UDim2.new(0.5, 0, 1, -CARD_BOTTOM),
		anchor = Vector2.new(0.5, 1),
		parent = gui,
		radius = 22,
		drop = 8,
		outline = 5,
	})
	Theme.pad(card, 20, 24, 22, 24)
	Theme.fitToViewport(card.Parent :: GuiObject, CARD_WIDTH + 40, 300)

	--- The step's number, on the gold square every panel in the game is
	--- headed by.
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.fromOffset(52, 52)
	badge.BackgroundColor3 = Color3.fromRGB(255, 224, 138)
	badge.BorderSizePixel = 0
	badge.Parent = card
	Theme.corner(badge, 14)
	local badgeGrade = Instance.new("UIGradient")
	badgeGrade.Color = ColorSequence.new(Color3.fromRGB(255, 224, 138), Color3.fromRGB(255, 176, 32))
	badgeGrade.Rotation = 90
	badgeGrade.Parent = badge
	Theme.stroke(badge, 4, Theme.colors.outline, 0)

	badgeLabel = Theme.text({
		name = "Number",
		text = "1",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = badge,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.outline,
		textSize = 26,
	})

	titleLabel = Theme.text({
		name = "Title",
		text = "",
		size = UDim2.new(1, -68, 0, 34),
		position = UDim2.fromOffset(68, 6),
		parent = card,
		align = Enum.TextXAlignment.Left,
		textSize = 27,
	})

	bodyLabel = Theme.text({
		name = "Body",
		text = "",
		size = UDim2.new(1, 0, 0, 52),
		position = UDim2.fromOffset(0, 60),
		parent = card,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.body,
		textSize = 17,
		bold = false,
	})
	bodyLabel.TextWrapped = true
	bodyLabel.TextYAlignment = Enum.TextYAlignment.Top

	--- The step pips: how far along this is, without a number to read.
	local pipRow = Instance.new("Frame")
	pipRow.Name = "Pips"
	pipRow.Size = UDim2.fromOffset(200, 8)
	pipRow.Position = UDim2.fromOffset(0, 128)
	pipRow.BackgroundTransparency = 1
	pipRow.Parent = card
	Theme.flow(pipRow, Enum.FillDirection.Horizontal, 7)

	for index = 1, #STEPS do
		local pip = Instance.new("Frame")
		pip.Name = `Pip{index}`
		pip.Size = UDim2.fromOffset(16, 8)
		pip.LayoutOrder = index
		pip.BackgroundColor3 = Color3.fromRGB(74, 56, 38)
		pip.BorderSizePixel = 0
		pip.Parent = pipRow
		Theme.corner(pip, 4)
		Theme.stroke(pip, 2, Theme.colors.outline, 0)
		table.insert(pips, pip)
	end

	exitLabel = Theme.text({
		name = "Exit",
		text = "",
		size = UDim2.new(1, -300, 0, 20),
		position = UDim2.fromOffset(0, 146),
		parent = card,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.label,
		textSize = 15,
		bold = false,
	})

	--[[
		The only button on the card.

		A player who has done this before, or who would rather find out for
		themselves, should not have to complete four objectives to get their
		HUD back. Skipping counts as done: the profile remembers, and the
		steps never come again.
	]]
	local skip = Instance.new("TextButton")
	skip.Name = "Skip"
	skip.Size = UDim2.fromOffset(96, 34)
	skip.Position = UDim2.new(1, 0, 0, 140)
	skip.AnchorPoint = Vector2.new(1, 0)
	skip.BackgroundColor3 = Color3.fromRGB(44, 33, 24)
	skip.BorderSizePixel = 0
	skip.AutoButtonColor = false
	skip.Font = Theme.font
	skip.Text = "SKIP"
	skip.TextColor3 = Theme.colors.label
	skip.TextSize = 15
	skip.Parent = card
	Theme.corner(skip, 12)
	Theme.stroke(skip, 3, Theme.colors.outline, 0)
	skip.Activated:Connect(function()
		FirstRun.finish()
	end)
end

--------------------------------------------------------------------
-- The steps
--------------------------------------------------------------------

local function paint()
	local current = STEPS[step]
	if not current then
		return
	end

	badgeLabel.Text = tostring(step)
	titleLabel.Text = current.title
	bodyLabel.Text = current.body
	exitLabel.Text = string.upper(current.exit)

	for index, pip in pips do
		local on = index <= step
		pip.Size = UDim2.fromOffset(if on then 34 else 16, 8)
		pip.BackgroundColor3 = if on then Theme.colors.tips else Color3.fromRGB(74, 56, 38)
	end

	RunOnly.reveal(current.reveal)
	--- Only the first step lights the button; after that the player knows
	--- where it is and the glow is decoration on a screen that has work on it.
	Hud.spotlight(step == 1, if step == 1 then "HOLD" else nil)
	Hud.dimPurse(step == 1)
	RoundBar.setReduced(true)
	shadeGui.Enabled = step <= 2

	--[[
		The card gets out of the hotbar's way when the hotbar arrives.

		Seventy above the bottom is the handoff's number, and it is right for
		the first two steps, where the bottom of the screen is empty. From step
		three the row of slots is down there — centred under a thumb on touch —
		and a coaching card sitting on it would be teaching the player to buy a
		tool with the tool row underneath the instruction.
	]]
	local holder = card.Parent :: Frame
	holder.Position = UDim2.new(0.5, 0, 1, -(if step >= 3 then 156 else CARD_BOTTOM))
end

local function enter(index: number)
	step = index
	stepStarted = os.clock()
	paint()

	--- A small lift on the way in, the same one the journal opens with, so a
	--- new step reads as a new thing rather than as text changing.
	local holder = card.Parent :: Frame
	holder.Size = UDim2.fromOffset(CARD_WIDTH - 24, 196)
	TweenService:Create(holder, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(CARD_WIDTH, 196),
	}):Play()
end

--- Puts the card away and hands the HUD back, without deciding anything about
--- whether the walkthrough is over.
local function standDown()
	running = false
	gui.Enabled = false
	shadeGui.Enabled = false
	Hud.spotlight(false)
	Hud.dimPurse(false)
	RoundBar.setReduced(false)
	RunOnly.reveal(nil)
end

--- Ends the walkthrough, whether it was walked or skipped, and gives the whole
--- HUD back.
function FirstRun.finish()
	if finished then
		return
	end
	finished = true
	step = 0
	standDown()
	Remotes.event(Remotes.FIRST_RUN_DONE):FireServer()
end

--[[
	The run ended underneath it.

	Not the same as finishing. A player who joined halfway through somebody
	else's round and watched the clock run out has not been taught anything,
	and marking the profile done there would cost them the walkthrough for
	good. The step is kept and the next round picks it up where it was.
]]
local function pause()
	if not running then
		return
	end
	standDown()
end

local function begin()
	if running or finished then
		return
	end
	running = true
	gui.Enabled = true
	enter(if step > 0 then step else 1)
end

local function tick()
	if not running then
		return
	end
	local current = STEPS[step]
	if not current then
		return
	end

	local over = current.done()
	if not over and step == #STEPS and os.clock() - stepStarted > WALL_PATIENCE then
		over = true
	end
	if not over then
		return
	end

	if step >= #STEPS then
		FirstRun.finish()
	else
		enter(step + 1)
	end
end

function FirstRun.start()
	build()

	--[[
		The wall, when it comes, is the fourth step's whole condition.

		`Overgrowth` already draws its own card when a tool refuses ground, and
		that card says which tool and which fix — everything the step was
		promising. So the step does not repeat it; it just notices.
	]]
	Remotes.event(Remotes.OVERGROWTH).OnClientEvent:Connect(function()
		overgrowthSeen = true
	end)

	--[[
		Started by the round, not by joining.

		`showFirstRun` is false until a profile has actually loaded, so a
		client that starts before its save arrives does not walk somebody
		through a lesson they finished a fortnight ago. And there is nothing to
		teach in the lobby: every step is about a lawn.
	]]
	Remotes.event(Remotes.ROUND_STATE).OnClientEvent:Connect(function(state: any)
		if type(state) ~= "table" then
			return
		end
		local phase = (state :: any).phase
		if phase == nil or phase == "lobby" then
			pause()
			return
		end
		if PlayerState.get().showFirstRun then
			begin()
		end
	end)

	Loop.forever("FirstRun.step", function()
		task.wait(0.5)
		tick()
	end)
end

return FirstRun
