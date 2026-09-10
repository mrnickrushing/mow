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
local Worlds = require(Shared.Config.Worlds)
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
local heroHolder: Frame
local heroTrack: Frame
local heroClock: Frame
local jobHolder_: Frame
--- True while the panel is wearing its phone shape, so the section title
--- knows whether it is carrying the third row's place line as well.
local phone = false

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
--[[
	The hero bar, on a phone.

	Three hundred and ninety wide and two rows instead of three. The third row
	carries the section's place in the property and what clearing it opens,
	which is fourteen point text — at the sixty-two per cent a phone would
	otherwise shrink the whole panel to, that is eight and a half points and
	nobody reads it. So the place moves up into the title, where it is
	`FRONT YARD · 1 OF 6` and legible, and the gate line waits for a screen
	with room for it.
]]
local PHONE_WIDTH = 390
local PHONE_HEIGHT = 98
--[[
	And once more, a little wider, while the first run is being taught.

	The coaching card is the thing being read on that screen and the bar is
	context for it, so it wears the same two rows a phone gets — at four
	hundred and twenty, which is the width the handoff draws it at.
]]
local COACH_WIDTH = 420
local reduced = false

--- What sits either side of the bar, at full size: the objective panel on
--- the left, the status column on the right, and the margin they keep.
local SIDE_INSET = 22
local JOB_RESERVE = 324
local COLUMN_GAP = 14
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
	heroHolder = holder
	RunOnly.piece("hero", holder)
	RunOnly.add(holder)
	--[[
		The bar is centred and the two columns are not, so on a narrow screen
		it walks into them.

		Measured with everything at its authored size: at 1024 x 768, which is
		an older iPad, the bar runs 229 to 795 while the objective panel ends
		at 346 and the status column starts at 762. A hundred and seventeen
		pixels of it sit under the objectives and thirty-three under the money.
		Even at the 1194 the design is drawn against there are thirty-two
		pixels of overlap on the left — so this was wrong at the target size
		and merely invisible on a wide desktop window.

		Neither neighbour can give up the room. The objective panel went from
		280 wide to 324 deliberately, because at 280 "Sell 5 units of
		clippings" was cut to "Sell 5 units of...". And shrinking a centred bar
		does not help against an obstacle that is only on one side: both edges
		move inward together.

		So it scales, the way every other fixed-size panel in this game does
		when it runs out of room, and `fitToViewport` is the thing that already
		knows how — `reservedX` is a corner widget that scales with the chrome,
		`reservedXInset` the margin that does not. Above about 1286 wide the
		scale clamps at one and nothing changes at all.
	]]
	Theme.fitToViewport(holder, HERO_WIDTH, HERO_HEIGHT, 22, JOB_RESERVE, SIDE_INSET + COLUMN_GAP, true)

	--- Row one: badge, name, clock.
	local top = Instance.new("Frame")
	top.Name = "Top"
	top.Size = UDim2.new(1, 0, 0, 34)
	top.BackgroundTransparency = 1
	top.Parent = hero

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.fromOffset(34, 34)
	badge.BackgroundColor3 = Theme.gradients.coin.top
	badge.BorderSizePixel = 0
	badge.Parent = top
	Theme.corner(badge, 10)
	local badgeGrade = Instance.new("UIGradient")
	badgeGrade.Color =
		ColorSequence.new(Theme.gradients.coin.top, Theme.gradients.coin.bottom)
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
	heroClock = clock

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
	heroTrack = track
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
	fill.BackgroundColor3 = Theme.gradients.fill.top
	fill.BorderSizePixel = 0
	fill.Parent = track
	Theme.corner(fill, 11)
	fillGrade = Instance.new("UIGradient")
	fillGrade.Color = ColorSequence.new(Theme.gradients.fill.top, Theme.gradients.fill.bottom)
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
	jobHolder_ = jobHolder
	RunOnly.piece("job", jobHolder)
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
local function place(row: SectionRow): (string, string, string)
	local world = PlayerState.world()
	if not world then
		return "", "", ""
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
	--- The same fact in four characters, for the phone title: the property's
	--- name is on the world-select card and the wave is on the bar.
	local short = if index > 0 then `{index} OF {total}` else ""

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
	return foot, (if gate ~= "" then gate else spare), short
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
	fillTop = Theme.gradients.fill.top,
	fillBottom = Theme.gradients.fill.bottom,
	percentInk = Theme.colors.text,
}
local NEARLY_FACE = {
	top = Color3.fromRGB(74, 58, 34),
	bottom = Color3.fromRGB(46, 34, 20),
	outline = Theme.colors.tips,
	thickness = 4,
	fillTop = Theme.gradients.coin.top,
	fillBottom = Theme.gradients.coin.bottom,
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

	local foot, gate, short = place(row)
	--[[
		On a phone the title carries the place as well.

		There is no third row to put it on, and "FRONT YARD" alone does not
		say how much of the property is left — which is the one thing the
		third row was there for.
	]]
	if phone and phase ~= "won" and phase ~= "lost" then
		sectionLabel.Text = if short ~= ""
			then `{string.upper(row.name)} · {short}`
			else string.upper(row.name)
	end

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

--[[
	Working by lantern light.

	`THE-CEMETERY.md` asks for it and gives the reason: every warm thing on
	that property is a local light — the lanterns, the chapel windows, the
	jack-o'-lanterns — and those are the landmarks. The HUD is one of them, so
	after dark the bar sits in a small pool of its own candlelight rather than
	floating on a black field.

	Three rings rather than a radial gradient, the same way the tool button's
	spotlight is drawn: Roblox has no radial gradient, and one png for one
	property is an asset to maintain forever.
]]
local glow: Frame? = nil

local function lanternGlow(on: boolean)
	if not on then
		if glow then
			glow:Destroy()
			glow = nil
		end
		return
	end
	if glow or not heroHolder then
		return
	end

	local pool = Instance.new("Frame")
	pool.Name = "Lantern"
	pool.Size = UDim2.fromScale(1, 1)
	pool.Position = UDim2.fromScale(0.5, 0.5)
	pool.AnchorPoint = Vector2.new(0.5, 0.5)
	pool.BackgroundTransparency = 1
	pool.BorderSizePixel = 0
	--- Behind the panel and its drop. See the note in `Theme.bevel` about
	--- this project's `ZIndexBehavior`.
	pool.ZIndex = -1
	pool.Parent = heroHolder

	for index, ring in { { 1.1, 0.86 }, { 1.24, 0.92 }, { 1.4, 0.96 } } do
		local halo = Instance.new("Frame")
		halo.Name = `Ring{index}`
		halo.Size = UDim2.fromScale(ring[1], ring[1])
		halo.Position = UDim2.fromScale(0.5, 0.5)
		halo.AnchorPoint = Vector2.new(0.5, 0.5)
		halo.BackgroundColor3 = Color3.fromRGB(255, 196, 104)
		halo.BackgroundTransparency = ring[2]
		halo.BorderSizePixel = 0
		halo.ZIndex = -1
		halo.Parent = pool
		Theme.corner(halo, 28)
	end

	glow = pool
end

--[[
	The panel's two shapes.

	Not a scaled copy: on a phone the third row goes, the section's place in
	the property moves up into the title beside its name, and the whole panel
	is drawn at its own size rather than at the sixty-two per cent the chrome
	scale would otherwise pick. The objective panel goes with it — a phone has
	no vertical room in the middle and the top-left corner is where the bag
	already is.
]]
local function layoutHero()
	local small = Theme.isPhone() or reduced
	phone = small

	local width = if reduced then COACH_WIDTH elseif small then PHONE_WIDTH else HERO_WIDTH
	local height = if small then PHONE_HEIGHT else HERO_HEIGHT
	heroHolder.Size = UDim2.fromOffset(width, height)
	heroTrack.Position = UDim2.fromOffset(0, if small then 42 else 44)
	heroClock.Size = UDim2.fromOffset(if small then 106 else 118, 28)
	sectionLabel.Size = UDim2.new(1, if small then -164 else -190, 1, 0)
	sectionLabel.TextSize = if small then 17 else 24
	footLabel.Visible = not small
	gateLabel.Visible = not small

	--[[
		Both the chip and the rate line hang off the bar, and the bar is not
		always the height it was authored at: `fitToViewport` scales it down on
		a tablet too narrow to hold it beside the columns. Measuring what was
		rendered is the only number that stays true.
	]]
	local function placeUnderTheBar()
		local drawn = heroHolder.AbsoluteSize.Y
		local bottom = 22 + (if drawn > 1 then drawn else height)
		edgeChip.Position = UDim2.new(0.5, 0, 0, bottom + 8 + 38)
		Hud.setBarBottom(bottom)
	end

	placeUnderTheBar()
	--[[
		And again a frame later.

		`AbsoluteSize` is what was last rendered, and the scale that decides it
		is set by `fitToViewport` on its own handler for the same viewport
		change — so on the pass that matters this can read the size from before
		the resize. Deferring costs one frame of a stale position and is the
		difference between a number that is usually right and one that is.
	]]
	task.defer(placeUnderTheBar)
	--[[
		The objective panel goes with the third row, in both of the shapes
		that lose it.

		On a phone there is no room for it. During the first run the coaching
		card is the objective, and a second panel saying what to do next
		beside it is the thing screen 6 is built to avoid.
	]]
	RunOnly.suppress(jobHolder_, small)

	refreshSection()
end

--- Two rows and four hundred and twenty wide, while the first run is on.
function RoundBar.setReduced(on: boolean)
	if on == reduced then
		return
	end
	reduced = on
	layoutHero()
end

function RoundBar.start()
	build()
	Theme.onScreenChange(layoutHero)

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

		--[[
			The chrome follows the property into the dark.

			The world id is on this wire and the mood is on the world, so this
			is the one place that already knows both. `Theme.setNight` returns
			immediately when nothing has changed, so it costs a comparison per
			broadcast.
		]]
		local world = if type(state.worldId) == "string" then Worlds.get(state.worldId) else nil
		local night = world ~= nil and world.mood == "night"
		Theme.setNight(night)
		lanternGlow(night)

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
