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
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Loop = require(Shared.Util.Loop)
local RunOnly = require(script.Parent.RunOnly)
local Remotes = require(Shared.Remotes)
local MissedSpotController = require(script.Parent.Parent.Controllers.MissedSpotController)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Hud = require(script.Parent.Hud)
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
local heroPanel: Frame
local heroStroke: UIStroke
local heroGrade: UIGradient
local fillGrade: UIGradient
local edgeChip: Frame
local edgeText: TextLabel
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
	heroPanel = hero
	heroStroke = hero:FindFirstChildOfClass("UIStroke") :: UIStroke
	heroGrade = hero:FindFirstChildOfClass("UIGradient") :: UIGradient
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
	fillGrade = Instance.new("UIGradient")
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
		The stragglers you cannot see.

		The markers stand over every tile that is left, which is no help at all
		for the one behind you — and at the end of a section that is usually
		where it is, because you have just walked past everything else. The
		chip counts what is off screen and says which way.
	]]
	edgeChip = Theme.chip({
		name = "OffScreen",
		size = UDim2.fromOffset(268, 34),
		--- Under the rate, which is already under the bar: the HUD stacks
		--- downward from the panel and the rate is thirty-four tall.
		position = UDim2.new(0.5, 0, 0, 22 + HERO_HEIGHT + 8 + 38),
		anchor = Vector2.new(0.5, 0),
		parent = gui,
		radius = Theme.PILL,
		transparency = 0.14,
	})
	edgeChip.Visible = false
	Theme.stroke(edgeChip, 3, Theme.colors.tips, 0)
	RunOnly.add(edgeChip)
	Theme.chromeScale(edgeChip)

	local edgeMark = Instance.new("Frame")
	edgeMark.Name = "Mark"
	edgeMark.Size = UDim2.fromOffset(14, 14)
	edgeMark.Position = UDim2.new(0, 18, 0.5, 0)
	edgeMark.AnchorPoint = Vector2.new(0, 0.5)
	edgeMark.Rotation = 45
	edgeMark.BackgroundColor3 = Theme.colors.tips
	edgeMark.BorderSizePixel = 0
	edgeMark.Parent = edgeChip
	Theme.corner(edgeMark, 3)

	edgeText = Theme.text({
		name = "Text",
		text = "",
		size = UDim2.new(1, -52, 1, 0),
		position = UDim2.fromOffset(42, 0),
		parent = edgeChip,
		color = Theme.colors.progress,
		textSize = 18,
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

--[[
	Past ninety-five per cent the bar stops being a percentage.

	"You missed a spot" is the reference game's most-repeated complaint, and
	the honest answer to it is not a bigger number — three tiles left reads as
	99.8% whichever way you round it. So at the end of a section the whole
	panel changes state: it warms, the fill goes gold, and the figure in the
	middle of the track becomes a count of what is actually left. The true
	percentage stays on the bottom row for anyone who wants it.

	Both faces are written out here rather than tweaked in place, because a
	state that only ever sets half its properties leaves the other half
	wherever the last state left them.
]]
local NORMAL_FACE = {
	top = Theme.colors.panelLight,
	bottom = Theme.colors.panel,
	outline = Theme.colors.outline,
	thickness = 4,
	fillTop = Color3.fromRGB(168, 237, 140),
	fillBottom = Color3.fromRGB(95, 194, 70),
	percentInk = Theme.colors.text,
}
local NEARLY_FACE = {
	top = Color3.fromRGB(74, 58, 34),
	bottom = Color3.fromRGB(46, 34, 20),
	outline = Theme.colors.tips,
	thickness = 4,
	fillTop = Color3.fromRGB(255, 224, 138),
	fillBottom = Color3.fromRGB(255, 176, 32),
	--- Dark ink on gold, so this is the one label in the game that wants no
	--- outline behind it.
	percentInk = Theme.colors.outline,
}

local wearingNearly = false

local function wear(face: typeof(NORMAL_FACE))
	heroPanel.BackgroundColor3 = face.top
	heroGrade.Color = ColorSequence.new(face.top, face.bottom)
	heroStroke.Color = face.outline
	heroStroke.Thickness = face.thickness
	fill.BackgroundColor3 = face.fillTop
	fillGrade.Color = ColorSequence.new(face.fillTop, face.fillBottom)
	percentLabel.TextColor3 = face.percentInk

	local outline = percentLabel:FindFirstChildOfClass("UIStroke")
	if outline then
		outline.Enabled = face.percentInk ~= Theme.colors.outline
	end
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

	local foot, gate = place(row)

	--[[
		The last few tiles, counted rather than rounded.

		`MissedSpotController` is already walking the tile buffer to put a mark
		over every straggler; the number it found is the number to print, and
		it is a tile count rather than a unit count — "3 spots left" means
		three places to stand, which is what the markers are showing.
	]]
	local straggle = MissedSpotController.sectionState(row.id)
	local nearly = straggle ~= nil and straggle.past
	if nearly ~= wearingNearly then
		wearingNearly = nearly
		wear(if nearly then NEARLY_FACE else NORMAL_FACE)
		--[[
			Said once, on the way in, and said kindly.

			At ninety-seven per cent the player is not doing anything wrong,
			which is the whole difference between this game and the one whose
			complaint it answers: the message is that they are nearly there,
			not that they missed something.
		]]
		if nearly and straggle then
			local spots = straggle.remaining
			Hud.toast(
				"round",
				if spots == 1
					then "Nearly there — one spot and the gate opens"
					else `Nearly there — {spots} spots and the gate opens`
			)
		end
	end

	if nearly and straggle then
		local spots = straggle.remaining
		percentLabel.Text = if spots == 1 then "1 SPOT LEFT" else `{spots} SPOTS LEFT`
		footLabel.Text = "FOLLOW THE MARKERS"
		footLabel.TextColor3 = Theme.colors.tips
		gateLabel.Text = `{Format.percent(straggle.cleared)} · {Format.tally(spots)} TILES`
		gateLabel.TextColor3 = Theme.colors.label
	else
		percentLabel.Text = Format.percent(done)
		footLabel.Text = foot
		footLabel.TextColor3 = Theme.colors.label
		gateLabel.Text = gate
		gateLabel.TextColor3 = Theme.colors.tips
	end
end

--[[
	How many marks are off screen, and whether they are behind you.

	A point is "on screen" by the camera's own reckoning — `WorldToViewportPoint`
	returns that as its second value — so this counts what the player cannot
	see rather than what is merely far away. Behind is the common case at the
	end of a section, and it is worth saying which, because "three more" with
	no direction is a search and "three more behind you" is a turn.
]]
local function refreshEdgeChip()
	if not edgeChip then
		return
	end
	if not wearingNearly or phase ~= "running" then
		edgeChip.Visible = false
		return
	end

	local camera = Workspace.CurrentCamera
	local spots = MissedSpotController.spots()
	if not camera or #spots == 0 then
		edgeChip.Visible = false
		return
	end

	local hidden, behind = 0, 0
	for _, spot in spots do
		local _, onScreen = camera:WorldToViewportPoint(spot)
		if not onScreen then
			hidden += 1
			if camera.CFrame.LookVector:Dot((spot - camera.CFrame.Position).Unit) < 0 then
				behind += 1
			end
		end
	end

	if hidden == 0 then
		edgeChip.Visible = false
		return
	end

	local where = if behind >= hidden then "behind you" else "off screen"
	edgeText.Text = if hidden == 1 then `1 more {where}` else `{hidden} more {where}`
	edgeChip.Visible = true
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

		--- The blades are shared the same way, and arrive on the same wire.
		if type(state.blades) == "table" then
			PlayerState.setFoundBlades(state.blades :: { string })
		end

		refreshSection()
	end)

	-- The objective under the bar is the current quest, which is what actually
	-- tells a new player what to do next.
	Loop.forever("RoundBar.tick", function()
		task.wait(0.35)
		refreshSection()
		refreshEdgeChip()

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
