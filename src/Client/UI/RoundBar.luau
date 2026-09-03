--!strict
--[[
	RoundBar — where you are, how far through it you are, and how long is left.

	The reference puts all of this in the top-left corner with no panel behind
	it, and it reads the *section* you are standing in rather than the whole
	property: "Frontyard 45.9%" is a number you can act on, where the world's
	overall completion is not. The wave counter sits above it because clearing a
	section once is not the same as finishing it when other people are playing.

	The clock counts down bottom-right, ticking locally between the server's
	twice-a-second updates so it never visibly stutters.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local RunOnly = require(script.Parent.RunOnly)
local Remotes = require(Shared.Remotes)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Journal = require(script.Parent.Journal)
local Theme = require(script.Parent.Theme)

local RoundBar = {}

local player = Players.LocalPlayer
local waveLabel: TextLabel
local sectionLabel: TextLabel
local timerLabel: TextLabel
local percentLabel: TextLabel
local objectiveLabel: TextLabel
local objectiveBox: Frame
local fpsLabel: TextLabel
local fill: Frame

local secondsLeft = 0
local phase = "playing"

export type SectionRow = {
	id: string,
	name: string,
	open: boolean,
	wave: number,
	waves: number,
	remaining: number,
	total: number,
}

local rows: { SectionRow } = {}

--------------------------------------------------------------------
-- Build
--------------------------------------------------------------------

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "MowRound"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local corner = Instance.new("Frame")
	corner.Name = "Zone"
	corner.Size = UDim2.fromOffset(360, 108)
	corner.Position = UDim2.fromOffset(18, 70)
	corner.BackgroundTransparency = 1
	corner.Parent = gui

	waveLabel = Theme.text({
		name = "Wave",
		text = "",
		size = UDim2.fromOffset(340, 24),
		position = UDim2.fromOffset(4, 0),
		parent = corner,
		color = Theme.colors.tips,
		textSize = 20,
	})

	Theme.icon({
		name = "Pin",
		prop = "MapPin",
		size = UDim2.fromOffset(28, 28),
		position = UDim2.fromOffset(0, 26),
		parent = corner,
	})

	sectionLabel = Theme.text({
		name = "Section",
		text = "",
		size = UDim2.fromOffset(200, 28),
		position = UDim2.fromOffset(32, 26),
		parent = corner,
		textSize = 22,
	})

	percentLabel = Theme.text({
		name = "Percent",
		text = "0.0%",
		size = UDim2.fromOffset(100, 28),
		position = UDim2.fromOffset(240, 28),
		parent = corner,
		align = Enum.TextXAlignment.Right,
		textSize = 19,
	})

	local _, bar = Theme.bar(corner, UDim2.fromOffset(320, 15), UDim2.fromOffset(4, 56), Theme.colors.progress)
	fill = bar

	-- An empty tick box in front of the objective, so an unfinished quest looks
	-- like something you are meant to go and tick off.
	objectiveBox = Instance.new("Frame")
	objectiveBox.Name = "Box"
	objectiveBox.Size = UDim2.fromOffset(19, 19)
	objectiveBox.Position = UDim2.fromOffset(4, 80)
	objectiveBox.BackgroundColor3 = Theme.colors.panel
	objectiveBox.BackgroundTransparency = 0.35
	objectiveBox.BorderSizePixel = 0
	objectiveBox.Parent = corner
	Theme.corner(objectiveBox, 4)
	Theme.stroke(objectiveBox, 2.5, Theme.colors.text, 0.05)

	objectiveLabel = Theme.text({
		name = "Objective",
		text = "",
		size = UDim2.fromOffset(310, 34),
		position = UDim2.fromOffset(30, 74),
		parent = corner,
		textSize = 17,
	})
	objectiveLabel.TextWrapped = true
	objectiveLabel.TextYAlignment = Enum.TextYAlignment.Top

	timerLabel = Theme.text({
		name = "Timer",
		text = "0:00",
		size = UDim2.fromOffset(240, 46),
		position = UDim2.new(1, -22, 1, -14),
		anchor = Vector2.new(1, 1),
		parent = gui,
		align = Enum.TextXAlignment.Right,
		textSize = 36,
	})
	RunOnly.add(timerLabel)

	-- Tucked left of the status column rather than directly under it: the
	-- column grows downward and the two met on a short viewport.
	fpsLabel = Theme.text({
		name = "Fps",
		text = "",
		size = UDim2.fromOffset(120, 20),
		position = UDim2.new(1, -160, 1, -62),
		anchor = Vector2.new(1, 1),
		parent = gui,
		align = Enum.TextXAlignment.Right,
		color = Theme.colors.subtext,
		textSize = 14,
	})
end

--------------------------------------------------------------------
-- Which section the player is in
--------------------------------------------------------------------

--[[
	The row for the section under the player's feet.

	Falls back to the last open section rather than to nothing: standing on a
	path between two gardens should not blank the display, and the section you
	most recently walked out of is a better guess than the first in the list.
]]
local function currentRow(): SectionRow?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if root and root:IsA("BasePart") then
		local sectionId = PlayerState.sectionIdAtPosition(root.Position)
		for _, row in rows do
			if row.id == sectionId then
				return row
			end
		end
	end

	local fallback: SectionRow? = nil
	for _, row in rows do
		if row.open then
			fallback = row
		end
	end
	return fallback
end

local function refreshSection()
	local row = currentRow()

	if phase == "won" then
		sectionLabel.Text = "Beaten!"
	elseif phase == "lost" then
		sectionLabel.Text = "Out of time"
	elseif phase == "lobby" then
		sectionLabel.Text = "Next up"
	else
		sectionLabel.Text = if row then row.name else ""
	end

	if not row then
		waveLabel.Text = ""
		percentLabel.Text = ""
		fill.Size = UDim2.fromScale(0, 1)
		return
	end

	--[[
		Which wave you are on, not how many you have finished.

		`row.wave` is the count already cleared, and it was printed straight —
		so a solo player, whose sections all need exactly one wave, read
		"Wave : 0/1" for the whole run, a counter that says zero until the
		moment the section ends. Worse, the server announces the same event as
		`wave {cleared + 1} of {needed}`, so on a four-player server clearing
		the first wave popped a toast reading "wave 2 of 4" beside a bar
		reading "Wave : 1/4".

		The server's numbering is the right one — you are on the wave you are
		cutting — and a section that only ever has one wave does not need a
		counter at all.
	]]
	if row.waves > 1 then
		waveLabel.Text = `Wave : {math.min(row.wave + 1, row.waves)}/{row.waves}`
	else
		waveLabel.Text = ""
	end

	-- A section with nothing in it reads as finished rather than as 0%, which is
	-- what an empty denominator would otherwise give.
	local done = if row.total > 0 then 1 - row.remaining / row.total else 1
	fill.Size = UDim2.fromScale(math.clamp(done, 0, 1), 1)
	fill.BackgroundColor3 = if done >= 1 then Theme.colors.tips else Theme.colors.progress
	percentLabel.Text = Format.percent(done)
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

function RoundBar.start()
	build()

	local roundState = Remotes.event(Remotes.ROUND_STATE)
	roundState.OnClientEvent:Connect(function(state: any)
		if type(state) ~= "table" then
			return
		end

		phase = state.phase or "running"
		secondsLeft = if type(state.secondsLeft) == "number" then state.secondsLeft else 0

		if type(state.sections) == "table" then
			table.clear(rows)
			local open: { [string]: boolean } = {}
			for _, entry in state.sections :: { any } do
				if type(entry) == "table" and type(entry.id) == "string" then
					table.insert(rows, {
						id = entry.id,
						name = if type(entry.name) == "string" then entry.name else entry.id,
						open = entry.open == true,
						wave = if type(entry.wave) == "number" then entry.wave else 0,
						waves = if type(entry.waves) == "number" then entry.waves else 1,
						remaining = if type(entry.remaining) == "number" then entry.remaining else 0,
						total = if type(entry.total) == "number" then entry.total else 0,
					})
					if entry.open then
						open[entry.id] = true
					end
				end
			end
			-- Gates open for the whole run, so the open set arrives here rather
			-- than with the per-player state.
			PlayerState.setOpenSections(open)
		end

		refreshSection()
	end)

	-- The objective under the bar is the current quest, which is what actually
	-- tells a new player what to do next.
	task.spawn(function()
		while true do
			task.wait(0.35)
			refreshSection()

			local text, progress, target = Journal.currentObjective()
			if text then
				objectiveLabel.Text = `{text} ({progress}/{target})`
				objectiveLabel.TextColor3 = Theme.colors.text
				objectiveBox.Visible = true
			else
				objectiveLabel.Text = "Clear the property before the clock runs out"
				objectiveLabel.TextColor3 = Theme.colors.subtext
				objectiveBox.Visible = false
			end
		end
	end)

	-- Tick locally between updates so the clock reads smoothly.
	local frames, elapsed = 0, 0
	RunService.Heartbeat:Connect(function(delta)
		secondsLeft = math.max(secondsLeft - delta, 0)
		timerLabel.Text = Format.clock(secondsLeft)
		timerLabel.TextColor3 = if phase ~= "running"
			then Theme.colors.subtext
			elseif secondsLeft <= 60 then Theme.colors.danger
			else Theme.colors.text

		frames += 1
		elapsed += delta
		if elapsed >= 0.5 then
			fpsLabel.Text = `{math.floor(frames / elapsed + 0.5)} FPS`
			frames, elapsed = 0, 0
		end
	end)
end

return RoundBar
