--!strict
--[[
	RoundBar — the shared completion bar and the clock.

	This is the one piece of UI everyone on the server is looking at, so it sits
	dead centre at the top and shows the whole server's progress rather than the
	player's own. The timer counts down locally between the server's twice-a-
	second updates so it never visibly stutters.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Remotes = require(Shared.Remotes)
local Journal = require(script.Parent.Journal)
local Theme = require(script.Parent.Theme)

local RoundBar = {}

local player = Players.LocalPlayer
local propertyLabel: TextLabel
local timerLabel: TextLabel
local percentLabel: TextLabel
local objectiveLabel: TextLabel
local fill: Frame

local secondsLeft = 0
local phase = "playing"

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "MowRound"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Zone name and progress sit top-left with no panel behind them, the way the
	-- reference does it: the outline carries the legibility instead.
	local corner = Instance.new("Frame")
	corner.Name = "Zone"
	corner.Size = UDim2.fromOffset(360, 70)
	corner.Position = UDim2.fromOffset(18, 76)
	corner.BackgroundTransparency = 1
	corner.Parent = gui

	local pin = Instance.new("TextLabel")
	pin.Name = "Pin"
	pin.Text = "📍"
	pin.Size = UDim2.fromOffset(28, 28)
	pin.Position = UDim2.fromOffset(0, 0)
	pin.BackgroundTransparency = 1
	pin.TextSize = 24
	pin.Font = Theme.font
	pin.Parent = corner

	propertyLabel = Theme.text({
		name = "Property",
		text = "",
		size = UDim2.fromOffset(220, 28),
		position = UDim2.fromOffset(32, 0),
		parent = corner,
		textSize = 22,
	})

	percentLabel = Theme.text({
		name = "Percent",
		text = "0.0%",
		size = UDim2.fromOffset(100, 28),
		position = UDim2.fromOffset(258, 0),
		parent = corner,
		align = Enum.TextXAlignment.Right,
		textSize = 20,
	})

	local _, bar = Theme.bar(corner, UDim2.fromOffset(340, 16), UDim2.fromOffset(4, 32), Theme.colors.progress)
	fill = bar

	objectiveLabel = Theme.text({
		name = "Objective",
		text = "",
		size = UDim2.fromOffset(340, 24),
		position = UDim2.fromOffset(4, 52),
		parent = corner,
		textSize = 17,
	})

	-- The clock lives bottom-right, counting down, as in the reference.
	timerLabel = Theme.text({
		name = "Timer",
		text = "0:00",
		size = UDim2.fromOffset(240, 46),
		position = UDim2.new(1, -22, 1, -16),
		anchor = Vector2.new(1, 1),
		parent = gui,
		align = Enum.TextXAlignment.Right,
		textSize = 38,
	})
end

function RoundBar.start()
	build()

	local roundState = Remotes.event(Remotes.ROUND_STATE)
	roundState.OnClientEvent:Connect(function(state: any)
		if type(state) ~= "table" then
			return
		end

		phase = state.phase or "playing"
		secondsLeft = if type(state.secondsLeft) == "number" then state.secondsLeft else 0

		local completion = if type(state.completion) == "number" then state.completion else 0
		fill.Size = UDim2.fromScale(math.clamp(completion, 0, 1), 1)
		percentLabel.Text = Format.percent(completion)

		if phase == "intermission" then
			propertyLabel.Text = "Next up"
			fill.BackgroundColor3 = Theme.colors.tips
		else
			propertyLabel.Text = state.propertyName or ""
			fill.BackgroundColor3 = if completion >= 1 then Theme.colors.tips else Theme.colors.progress
		end
	end)

	-- The objective under the bar is the current quest, which is what actually
	-- tells a new player what to do next.
	task.spawn(function()
		while true do
			task.wait(0.35)
			local text, progress, target = Journal.currentObjective()
			if text then
				objectiveLabel.Text = `☐ {text} ({progress}/{target})`
				objectiveLabel.TextColor3 = Theme.colors.text
			else
				objectiveLabel.Text = "Clear the property before the clock runs out"
				objectiveLabel.TextColor3 = Theme.colors.subtext
			end
		end
	end)

	-- Tick locally between updates so the clock reads smoothly.
	RunService.Heartbeat:Connect(function(delta)
		secondsLeft = math.max(secondsLeft - delta, 0)
		timerLabel.Text = Format.clock(secondsLeft)
		timerLabel.TextColor3 = if phase == "intermission"
			then Theme.colors.subtext
			elseif secondsLeft <= 60 then Theme.colors.danger
			else Theme.colors.tips
	end)
end

return RoundBar
