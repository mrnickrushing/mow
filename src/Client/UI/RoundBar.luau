--!strict
--[[
	RoundBar — where you are, how far through it you are, and how long is left.

	It reads the *section* you are standing in rather than the whole property:
	"Front Yard 45.9%" is a number you can act on, where the world's overall
	completion is not. The wave counter is part of the same line because
	clearing a section once is not the same as finishing it when other people
	are playing.

	The clock ticks locally between the server's twice-a-second updates so it
	never visibly stutters.

	This used to be outlined text in the top-left with no panel behind it, and
	the clock was a separate number in the bottom-right corner. A completion
	bar is what this genre is played on — without one a player has no idea how
	close a section is — so it is now the one thing on the screen that is
	deliberately in the way: a panel across the top centre carrying the
	section's name, the clock, the bar, and what finishing it opens.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Loop = require(Shared.Util.Loop)
local RunOnly = require(script.Parent.RunOnly)
local Remotes = require(Shared.Remotes)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Journal = require(script.Parent.Journal)
local Theme = require(script.Parent.Theme)

local RoundBar = {}

local player = Players.LocalPlayer
local hero: Frame
local sectionLabel: TextLabel
local timerLabel: TextLabel
local percentLabel: TextLabel
local footLabel: TextLabel
local gateLabel: TextLabel
local fill: Frame
local jobRows: { { box: Frame, tick: Frame, text: TextLabel, count: TextLabel } } = {}
local jobPanel: Frame

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

local HERO_WIDTH = 566
local HERO_HEIGHT = 128
local JOB_ROWS = 3
--- Wide enough for the longest job line the journal writes. At 280, with a
--- 74-pixel column for a count that never needs more than "100/100", "Sell 5
--- units of clippings" was cut to "Sell 5 units of...".
local JOB_WIDTH = 324
--- Twelve of padding, an eighteen point header, then a row every twenty-nine.
local JOB_HEIGHT = 12 + 18 + JOB_ROWS * 29 + 4

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "MowRound"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	hero = Theme.chunkPanel({
		name = "Hero",
		size = UDim2.fromOffset(HERO_WIDTH, HERO_HEIGHT),
		position = UDim2.new(0.5, 0, 0, 22),
		anchor = Vector2.new(0.5, 0),
		parent = gui,
		radius = 20,
	})
	Theme.pad(hero, 14, 18, 16, 18)
	--- The holder is what carries the position, so it is the holder that has
	--- to be hidden in the lobby and scaled on a phone.
	local holder = hero.Parent :: Frame
	RunOnly.add(holder)
	Theme.chromeScale(holder)

	--- Row one: badge, name, clock.
	local top = Instance.new("Frame")
	top.Name = "Top"
	top.Size = UDim2.new(1, 0, 0, 34)
	top.BackgroundTransparency = 1
	top.Parent = hero

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.fromOffset(34, 34)
	badge.BackgroundColor3 = Color3.fromRGB(255, 224, 138)
	badge.BorderSizePixel = 0
	badge.Parent = top
	Theme.corner(badge, 10)
	local badgeGrade = Instance.new("UIGradient")
	badgeGrade.Color =
		ColorSequence.new(Color3.fromRGB(255, 224, 138), Color3.fromRGB(255, 176, 32))
	badgeGrade.Rotation = 90
	badgeGrade.Parent = badge
	Theme.stroke(badge, 3, Theme.colors.outline, 0)

	--- Roblox has no diamond, and a square turned forty-five degrees is one.
	local mark = Instance.new("Frame")
	mark.Name = "Mark"
	mark.Size = UDim2.fromOffset(13, 13)
	mark.Position = UDim2.fromScale(0.5, 0.5)
	mark.AnchorPoint = Vector2.new(0.5, 0.5)
	mark.Rotation = 45
	mark.BackgroundColor3 = Theme.colors.outline
	mark.BorderSizePixel = 0
	mark.Parent = badge
	Theme.corner(mark, 2)

	sectionLabel = Theme.text({
		name = "Section",
		text = "",
		size = UDim2.new(1, -190, 1, 0),
		position = UDim2.fromOffset(46, 0),
		parent = top,
		textSize = 24,
	})

	local clock = Theme.chip({
		name = "Clock",
		size = UDim2.fromOffset(118, 28),
		position = UDim2.fromScale(1, 0.5),
		anchor = Vector2.new(1, 0.5),
		parent = top,
	})

	local tick = Instance.new("Frame")
	tick.Name = "Tick"
	tick.Size = UDim2.fromOffset(9, 9)
	tick.Position = UDim2.fromOffset(12, 10)
	tick.BackgroundColor3 = Theme.colors.cash
	tick.BorderSizePixel = 0
	tick.Parent = clock
	Theme.corner(tick, 5)

	timerLabel = Theme.text({
		name = "Timer",
		text = "0:00",
		size = UDim2.new(1, -33, 1, 0),
		position = UDim2.fromOffset(27, 0),
		parent = clock,
		color = Theme.colors.progress,
		textSize = 17,
	})

	--- Row two: the bar. The percentage is centred over the whole track
	--- rather than sitting at the end of the fill, so it does not move.
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.new(1, 0, 0, 26)
	track.Position = UDim2.fromOffset(0, 44)
	track.BackgroundColor3 = Theme.colors.outline
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Parent = hero
	Theme.corner(track, 13)

	fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(168, 237, 140)
	fill.BorderSizePixel = 0
	fill.Parent = track
	Theme.corner(fill, 11)
	local fillGrade = Instance.new("UIGradient")
	fillGrade.Color = ColorSequence.new(Color3.fromRGB(168, 237, 140), Color3.fromRGB(95, 194, 70))
	fillGrade.Rotation = 90
	fillGrade.Parent = fill

	local sheen = Instance.new("Frame")
	sheen.Name = "Sheen"
	sheen.Size = UDim2.new(1, -8, 0, 3)
	sheen.Position = UDim2.fromOffset(4, 3)
	sheen.BackgroundColor3 = Color3.new(1, 1, 1)
	sheen.BackgroundTransparency = 0.6
	sheen.BorderSizePixel = 0
	sheen.Parent = fill
	Theme.corner(sheen, 2)

	percentLabel = Theme.text({
		name = "Percent",
		text = "0.0%",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = track,
		align = Enum.TextXAlignment.Center,
		textSize = 15,
	})
	--- Over the fill, which is a sibling at the same level inside the track.
	percentLabel.ZIndex = 2

	--- Row three: where this section sits in the property, and what finishing
	--- it opens — the one line that tells a player why they are doing this.
	footLabel = Theme.text({
		name = "Foot",
		text = "",
		size = UDim2.new(0.55, 0, 0, 18),
		position = UDim2.fromOffset(0, 80),
		parent = hero,
		color = Theme.colors.label,
		textSize = 14,
	})

	gateLabel = Theme.text({
		name = "Gate",
		text = "",
		size = UDim2.new(0.45, 0, 0, 18),
		position = UDim2.new(1, 0, 0, 80),
		anchor = Vector2.new(1, 0),
		parent = hero,
		color = Theme.colors.tips,
		align = Enum.TextXAlignment.Right,
		textSize = 14,
	})

	--[[
		The job panel, top left.

		The objective used to be a line of bare text under the section name,
		which put the two things a player is working on — the section and the
		quest — in the same sentence. They are different jobs on different
		clocks, so the quest gets its own panel with a tick box in front of
		each line, which is what makes an unfinished one look like something
		you are meant to go and tick off.
	]]
	jobPanel = Theme.chunkPanel({
		name = "Job",
		size = UDim2.fromOffset(JOB_WIDTH, JOB_HEIGHT),
		position = UDim2.fromOffset(22, 22),
		parent = gui,
	})
	Theme.pad(jobPanel, 12, 14, 12, 14)
	local jobHolder = jobPanel.Parent :: Frame
	RunOnly.add(jobHolder)
	Theme.chromeScale(jobHolder)

	local jobMark = Instance.new("Frame")
	jobMark.Name = "Mark"
	jobMark.Size = UDim2.fromOffset(8, 8)
	jobMark.Position = UDim2.fromOffset(2, 5)
	jobMark.Rotation = 45
	jobMark.BackgroundColor3 = Theme.colors.accent
	jobMark.BorderSizePixel = 0
	jobMark.Parent = jobPanel
	Theme.corner(jobMark, 2)

	Theme.text({
		name = "Header",
		text = "CURRENT JOB",
		size = UDim2.new(1, -18, 0, 18),
		position = UDim2.fromOffset(18, 0),
		parent = jobPanel,
		color = Theme.colors.tips,
		textSize = 14,
	})

	for index = 1, JOB_ROWS do
		local y = 27 + (index - 1) * 29

		local box = Instance.new("Frame")
		box.Name = `Box{index}`
		box.Size = UDim2.fromOffset(20, 20)
		box.Position = UDim2.fromOffset(0, y)
		box.BackgroundColor3 = Color3.fromRGB(30, 22, 16)
		box.BorderSizePixel = 0
		box.Parent = jobPanel
		Theme.corner(box, 6)
		Theme.stroke(box, 3, Theme.colors.outline, 0)

		local ticked = Instance.new("Frame")
		ticked.Name = "Tick"
		ticked.Size = UDim2.fromOffset(10, 10)
		ticked.Position = UDim2.fromScale(0.5, 0.5)
		ticked.AnchorPoint = Vector2.new(0.5, 0.5)
		ticked.BackgroundColor3 = Theme.colors.cash
		ticked.BorderSizePixel = 0
		ticked.Visible = false
		ticked.Parent = box
		Theme.corner(ticked, 3)

		local text = Theme.text({
			name = `Text{index}`,
			text = "",
			size = UDim2.new(1, -92, 0, 20),
			position = UDim2.fromOffset(30, y),
			parent = jobPanel,
			color = Theme.colors.progress,
			textSize = 15,
		})
		text.TextTruncate = Enum.TextTruncate.AtEnd

		local count = Theme.text({
			name = `Count{index}`,
			text = "",
			size = UDim2.fromOffset(58, 20),
			position = UDim2.new(1, 0, 0, y),
			anchor = Vector2.new(1, 0),
			parent = jobPanel,
			color = Theme.colors.label,
			align = Enum.TextXAlignment.Right,
			textSize = 14,
		})

		table.insert(jobRows, { box = box, tick = ticked, text = text, count = count })
	end
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

--[[
	Where this section sits in the property, and what finishing it opens.

	The world definition is on the client already, so both come out of it:
	the index counts the required sections, because an optional garage is not
	"section three of six" to anybody, and the gate line names whichever
	section says it `requires` this one.
]]
local function place(row: SectionRow): (string, string)
	local world = PlayerState.world()
	if not world then
		return "", ""
	end

	local index, total = 0, 0
	for _, section in world.sections do
		if not section.optional then
			total += 1
			if section.id == row.id then
				index = total
			end
		end
	end

	local foot = if index > 0
		then `SECTION {index} OF {total} · {string.upper(world.name)}`
		else string.upper(world.name)
	if row.waves > 1 then
		foot ..= ` · WAVE {math.min(row.wave + 1, row.waves)} OF {row.waves}`
	end

	--[[
		Whichever section this one opens, preferring one you have to do.

		The House's front yard opens the rooftop and the backyard, and the
		rooftop is listed first — so the line read "CLEAR IT TO OPEN ROOFTOP",
		pointing a new player at the one section on the property that is
		optional. The chain a player is actually on is the required one.
	]]
	local gate, spare = "", ""
	for _, section in world.sections do
		if section.requires == row.id and not PlayerState.isSectionOpen(section.id) then
			local line = `CLEAR IT TO OPEN {string.upper(section.name)}`
			if not section.optional then
				gate = line
				break
			elseif spare == "" then
				spare = line
			end
		end
	end
	return foot, if gate ~= "" then gate else spare
end

local function blank()
	sectionLabel.Text = ""
	percentLabel.Text = ""
	footLabel.Text = ""
	gateLabel.Text = ""
	fill.Size = UDim2.fromScale(0, 1)
end

local function refreshSection()
	local row = currentRow()

	if phase == "won" then
		sectionLabel.Text = "BEATEN!"
	elseif phase == "lost" then
		sectionLabel.Text = "OUT OF TIME"
	elseif phase == "lobby" then
		--[[
			Nothing behind the words in the lobby.

			The rows outlive the run that filled them and `currentRow` falls
			back to the last open section, so walking back into the lobby off
			a finished property left a full gold bar reading 100% — a progress
			bar for a run that is over, in a room where there is nothing to be
			making progress on. The panel is hidden there now by `RunOnly`,
			and this keeps it empty underneath so it never flashes stale.
		]]
		blank()
		return
	else
		sectionLabel.Text = if row then string.upper(row.name) else ""
	end

	if not row then
		percentLabel.Text = ""
		footLabel.Text = ""
		gateLabel.Text = ""
		fill.Size = UDim2.fromScale(0, 1)
		return
	end

	-- A section with nothing in it reads as finished rather than as 0%, which is
	-- what an empty denominator would otherwise give.
	local done = if row.total > 0 then 1 - row.remaining / row.total else 1
	fill.Size = UDim2.fromScale(math.clamp(done, 0, 1), 1)
	percentLabel.Text = Format.percent(done)

	local foot, gate = place(row)
	footLabel.Text = foot
	gateLabel.Text = gate
end

--[[
	The job panel's rows, from whatever the journal is tracking.

	Three at most, unfinished first: a list of ticked and unticked boxes is
	what makes these read as a job, where one line of running text read as a
	caption on the section name.
]]
local function refreshJobs()
	local jobs = Journal.jobs(JOB_ROWS)
	for index, slot in jobRows do
		local job = jobs[index]
		if job then
			slot.box.Visible = true
			slot.text.Visible = true
			slot.count.Visible = true
			slot.tick.Visible = job.done
			slot.text.Text = job.text
			slot.text.TextColor3 = if job.done then Theme.colors.label else Theme.colors.progress
			--[[
				Counted, not printed raw.

				Units sold is a running float, and this was showing it
				exactly: "Sell 1,000 units in total (140.72765566000004/1000)"
				— the one place a quest's own progress reached a player as a
				fourteen-decimal number.
			]]
			slot.count.Text = `{Format.tally(job.progress)}/{Format.tally(job.target)}`
		else
			slot.box.Visible = false
			slot.text.Visible = false
			slot.count.Visible = false
		end
	end
	--[[
		Never empty, and never hidden.

		A panel that comes and goes as quests finish is a hole opening in the
		corner of the screen, and `RunOnly` already owns whether this is on at
		all — two owners of one `Visible` is how the tool button lost that
		argument. With nothing tracked it says the one thing that is always
		true instead, which is what the old single line said.
	]]
	if #jobs == 0 then
		local slot = jobRows[1]
		slot.box.Visible = true
		slot.tick.Visible = false
		slot.text.Visible = true
		slot.text.Text = "Clear the property before the clock runs out"
		slot.text.TextColor3 = Theme.colors.label
		slot.count.Visible = false
	end
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
	Loop.forever("RoundBar.tick", function()
		task.wait(0.35)
		refreshSection()

		refreshJobs()
	end)

	-- Tick locally between updates so the clock reads smoothly.
	RunService.Heartbeat:Connect(function(delta)
		secondsLeft = math.max(secondsLeft - delta, 0)
		timerLabel.Text = Format.clock(secondsLeft)
		timerLabel.TextColor3 = if phase ~= "running"
			then Theme.colors.subtext
			elseif secondsLeft <= 60 then Theme.colors.danger
			else Theme.colors.text
	end)
end

return RoundBar
