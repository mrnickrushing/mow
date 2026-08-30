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
local Theme = require(script.Parent.Theme)

local RoundBar = {}

local player = Players.LocalPlayer
local propertyLabel: TextLabel
local timerLabel: TextLabel
local percentLabel: TextLabel
local fill: Frame

local secondsLeft = 0
local phase = "playing"

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "MowRound"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Theme.panel({
		name = "Round",
		size = UDim2.fromOffset(420, 78),
		position = UDim2.new(0.5, 0, 0, 12),
		anchor = Vector2.new(0.5, 0),
		parent = gui,
	})

	propertyLabel = Theme.text({
		name = "Property",
		text = "",
		size = UDim2.new(1, -140, 0, 22),
		position = UDim2.fromOffset(14, 8),
		parent = panel,
		textSize = 17,
	})

	timerLabel = Theme.text({
		name = "Timer",
		text = "0:00",
		size = UDim2.fromOffset(110, 22),
		position = UDim2.new(1, -14, 0, 8),
		anchor = Vector2.new(1, 0),
		parent = panel,
		color = Theme.colors.tips,
		align = Enum.TextXAlignment.Right,
		textSize = 19,
	})

	local _, bar = Theme.bar(panel, UDim2.new(1, -28, 0, 18), UDim2.fromOffset(14, 36), Theme.colors.grass)
	fill = bar

	percentLabel = Theme.text({
		name = "Percent",
		text = "0%",
		size = UDim2.new(1, -28, 0, 16),
		position = UDim2.fromOffset(14, 58),
		parent = panel,
		color = Theme.colors.subtext,
		align = Enum.TextXAlignment.Right,
		textSize = 13,
		bold = false,
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
		percentLabel.Text = `{Format.percent(completion)} of the property clear`

		if phase == "intermission" then
			propertyLabel.Text = "Next property coming up"
			fill.BackgroundColor3 = Theme.colors.tips
		else
			propertyLabel.Text = state.propertyName or ""
			-- Turning amber near the end is the only cue that the clock matters.
			fill.BackgroundColor3 = if completion >= 1 then Theme.colors.tips else Theme.colors.grass
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
