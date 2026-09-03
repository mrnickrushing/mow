--!strict
--[[
	LobbyService — the yard you stand in between runs.

	Choosing a property used to be a panel that covered the screen: you finished
	a run, a dark card appeared over the world, you clicked a row. It worked, and
	it read as a menu bolted to a game rather than a place in it.

	This is the same choice made with your feet. Four pads set the size of the
	team, because the work scales with how many hands are on it and a team of
	three should be able to say so. Three plaques pick the property, locked ones
	saying what has to be beaten first. Stand on a pad, pick a property, and the
	countdown takes everyone in.

	The lobby is built once, a long way from any lot, and never torn down: a run
	loads and unloads a property under `MowWorld`, and the lobby sits outside it
	so that arriving back is a move rather than a rebuild.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Palette = require(Shared.Config.Palette)
local Worlds = require(Shared.Config.Worlds)
local Build = require(script.Parent.Parent.Lib.Build)
local DataService = require(script.Parent.DataService)
local MowRunService = require(script.Parent.RunService)
local MatchmakingService = require(script.Parent.MatchmakingService)

local LobbyService = {}

--- Far enough from every lot that nothing can ever overlap it.
local CENTRE = Vector3.new(-600, 0, -600)
local FLOOR_W, FLOOR_D = 260, 260
local TEAM_PADS = 4
--- Seconds between a team being ready and the property loading.
local COUNTDOWN = 6

local folder: Folder? = nil
local teamPads: { BasePart } = {}
local teamLabels: { TextLabel } = {}
local levelPads: { [string]: BasePart } = {}
local levelLabels: { [string]: TextLabel } = {}
local statusLabel: TextLabel? = nil
--- The board over the pads that says how many of you are going.
local teamCountLabel: TextLabel? = nil
local outcomeLabel: TextLabel? = nil

local chosenWorld: string? = nil
local countdownLeft: number? = nil
--- What the last run did, so the lobby can say so rather than a panel.
local lastOutcome: string? = nil
local lastWorldName: string? = nil
local lastPhase = "lobby"

--------------------------------------------------------------------
-- Building
--------------------------------------------------------------------

--[[
	Text in this room lives on surfaces, not on billboards.

	A BillboardGui is drawn at a fixed pixel size however far away it is, so a
	sign fifty studs behind another sign lands on top of it: the first build of
	this lobby was four legible words and a pile of overlapping ones. A board is
	a board — it shrinks with distance, it sits where it was put, and two of
	them never occupy the same piece of screen.
]]
local function surface(part: BasePart, face: Enum.NormalId, scale: number): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.LightInfluence = 0
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(0.92, scale)
	label.Position = UDim2.fromScale(0.04, (1 - scale) * 0.5)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Text = ""
	label.Parent = gui
	return label
end

--[[
	A heading painted on the floor rather than stood up on a post.

	The first pass put both headings on boards at head height, which put a wall
	across the room: from the door you read "YOUR TEAM" and saw nothing else,
	because the sign was between you and the pads it was naming. Words on the
	floor label the thing you are walking towards without standing in front of
	it.
]]
local function floorHeading(name: string, width: number, at: Vector3, parent: Instance): TextLabel
	--[[
		Turned a quarter, because a Top face reads across the part's Z.

		Laid out the obvious way — long along X — the words came out running
		up the strip instead of along it, and turned the other way they came
		out mirrored. The strip is built long along Z and turned to face, so
		the footprint is the same and the sentence reads left to right.
	]]
	local strip = Build.part({
		name = name,
		size = Vector3.new(7, 0.3, width),
		cframe = CFrame.new(at + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, math.rad(-90), 0),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = parent,
	})
	return surface(strip, Enum.NormalId.Top, 0.8)
end

local function pad(name: string, at: Vector3, colour: Color3, parent: Instance, span: number?): (BasePart, TextLabel)
	local size = span or 14
	local part = Build.part({
		name = name,
		size = Vector3.new(size, 1, size),
		cframe = CFrame.new(at + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, math.rad(-90), 0),
		color = colour,
		material = Enum.Material.SmoothPlastic,
		parent = parent,
	})
	part.TopSurface = Enum.SurfaceType.Smooth
	return part, surface(part, Enum.NormalId.Top, 0.55)
end

--[[
	The yard itself.

	It is a lawn with a fence round it, because that is what this game is about
	and because a grey slab in the void is a menu with walls. Big enough to walk
	about in while you decide, a path down the middle so the route to the pads
	is obvious, and everything that has to be read either painted on the ground
	or stood behind the thing it names.
]]
local function build()
	if folder then
		return
	end
	local root = Build.folder("MowLobby", workspace)
	folder = root
	local rng = Random.new(20260902)

	Build.part({
		name = "Lawn",
		size = Vector3.new(FLOOR_W, 2, FLOOR_D),
		cframe = CFrame.new(CENTRE - Vector3.new(0, 1, 0)),
		color = Palette.color(Palette.ground.lawn),
		material = Enum.Material.Grass,
		parent = root,
	})

	--[[
		A picket fence on all four sides, open where you arrive.

		The gap matters more than the fence: a yard you cannot see out of is a
		room, and the point of standing here is that it feels like the front of
		somebody's house.
	]]
	local halfW, halfD = FLOOR_W * 0.5, FLOOR_D * 0.5
	local fences = Build.folder("Fences", root)
	local corners = {
		{ CENTRE + Vector3.new(-halfW, 0, -halfD), CENTRE + Vector3.new(halfW, 0, -halfD) },
		{ CENTRE + Vector3.new(-halfW, 0, -halfD), CENTRE + Vector3.new(-halfW, 0, halfD) },
		{ CENTRE + Vector3.new(halfW, 0, -halfD), CENTRE + Vector3.new(halfW, 0, halfD) },
		-- The near side, in two runs with the gate between them.
		{ CENTRE + Vector3.new(-halfW, 0, halfD), CENTRE + Vector3.new(-18, 0, halfD) },
		{ CENTRE + Vector3.new(18, 0, halfD), CENTRE + Vector3.new(halfW, 0, halfD) },
	}
	for _, run in corners do
		Build.picketFence(fences, run[1], run[2], 9, false)
	end

	-- A path from the gate to the plaques, so the way in is a way somewhere.
	Build.flagstone(
		root,
		CENTRE + Vector3.new(0, 1.15, 20),
		Vector2.new(16, 190),
		5,
		rng
	)

	--------------------------------------------------------------------
	-- One: the property plaques
	--------------------------------------------------------------------

	--[[
		The room is walked in the order it works in.

		Players are placed at the south end facing north, and the two halves
		used to be the other way round: you crossed the team pads first, stood
		on one, and were told to pick a property while already standing on a
		pad. The plaques were another ninety studs on, and since the choice is
		sticky you then had to walk all the way back to the pad you had already
		used. Nothing about that said "this is how you get in".

		Plaques first, pads second. Pick a property, keep walking, stand on a
		pad, and it counts you down.
	]]
	local pickHeading = floorHeading("PickSign", 78, CENTRE + Vector3.new(0, 1.9, 74), root)
	pickHeading.Text = "1. PICK A PROPERTY — STAND ON ONE"

	local list = Worlds.list
	for index, world in list do
		local x = (index - (#list + 1) * 0.5) * 74
		local at = CENTRE + Vector3.new(x, 1.5, 46)
		local part, padLabel = pad(`LevelPad_{world.id}`, at, Palette.color(Palette.ground.stoneDark), root, 26)
		padLabel.Text = world.difficulty

		--[[
			A lawn sign, not a billboard.

			These used to be eighteen studs of board on twelve-stud posts. Down
			at this end of the yard that is tall enough to stand squarely in
			front of the status board at the far end — the one thing in the
			room that says what is happening — so the sign that tells you the
			property would have hidden the sign that tells you the game. Low
			and wide, staked in the grass like the board outside a house that
			is up for sale, which is also the right thing for a lawn business
			to have in its yard.
		]]
		for _, side in { -1, 1 } do
			Build.part({
				name = "SignStake",
				size = Vector3.new(0.7, 6, 0.7),
				cframe = CFrame.new(CENTRE + Vector3.new(x + side * 9, 3, 30)),
				color = Palette.color(Palette.fence.rail),
				material = Enum.Material.SmoothPlastic,
				parent = root,
			})
		end
		local board = Build.part({
			name = `LevelSign_{world.id}`,
			size = Vector3.new(24, 6, 0.8),
			cframe = CFrame.lookAt(
				CENTRE + Vector3.new(x, 8, 30),
				CENTRE + Vector3.new(x, 8, 31)
			),
			color = Palette.color(Palette.house.trim),
			material = Enum.Material.SmoothPlastic,
			parent = root,
		})
		levelPads[world.id] = part
		levelLabels[world.id] = surface(board, Enum.NormalId.Front, 0.86)
		levelLabels[world.id].Text = world.name

		-- A planter either side, because a sign in bare grass is a placeholder.
		for _, side in { -1, 1 } do
			Build.mesh({
				prop = "Planter",
				name = "Planter",
				size = Vector3.new(5, 7.6, 5),
				cframe = CFrame.new(CENTRE + Vector3.new(x + side * 17, 3.8, 30)),
				parent = root,
			})
		end
	end

	--------------------------------------------------------------------
	-- Two: the team pads, and how many of you there are
	--------------------------------------------------------------------

	local teamHeading = floorHeading("TeamSign", 72, CENTRE + Vector3.new(0, 1.9, -2), root)
	teamHeading.Text = "2. STAND ON A PAD — ONE EACH"

	for index = 1, TEAM_PADS do
		local at = CENTRE + Vector3.new((index - (TEAM_PADS + 1) * 0.5) * 26, 1.5, -46)
		local part, label = pad(`TeamPad{index}`, at, Palette.color(Palette.ground.stone), root, 18)
		label.Text = `{index}`
		teamPads[index] = part
		teamLabels[index] = label
	end

	--[[
		How many of you are going, said out loud.

		Four pads and a name written on whichever ones are occupied is a team
		size, but it is not a *number*, and the first thing anybody asked was
		where the box is that picks how many players. This is the box: it
		counts the pads that are stood on, over the pads themselves, at the
		height you are already looking.
	]]
	local counterPost = Build.part({
		name = "TeamCounter",
		size = Vector3.new(46, 11, 1.2),
		cframe = CFrame.lookAt(
			CENTRE + Vector3.new(0, 15, -64),
			CENTRE + Vector3.new(0, 15, -63)
		),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		parent = root,
	})
	for _, side in { -1, 1 } do
		Build.part({
			name = "CounterPost",
			size = Vector3.new(1.4, 15, 1.4),
			cframe = CFrame.new(CENTRE + Vector3.new(side * 21, 7.5, -64)),
			color = Palette.color(Palette.fence.rail),
			material = Enum.Material.SmoothPlastic,
			parent = root,
		})
	end
	teamCountLabel = surface(counterPost, Enum.NormalId.Front, 0.7)
	;(teamCountLabel :: TextLabel).Text = `TEAM 0 / {TEAM_PADS}`

	--------------------------------------------------------------------
	-- The yard it is all standing in
	--------------------------------------------------------------------

	--[[
		A lawn-care depot, not a lawn with signs on it.

		The room had a floor, a fence, some trees and its lettering, and that
		was the whole of it — which is exactly what it looked like. The game
		ships seventy-three props and the lobby used two of them.

		Everything below is built from those: the shed the tools are kept in,
		the trailer and the mowers parked beside it, the lamps down the path,
		crates and barrels and a dog. Nothing is imported for it. A free model
		off the marketplace is the usual way a published Roblox game acquires
		a backdoor, and there is nothing here that needs one.
	]]
	local yard = Build.folder("Yard", root)

	-- The way in: a gate you walk under, with the name over it.
	for _, side in { -1, 1 } do
		Build.mesh({
			prop = "Column",
			name = "ArchColumn",
			size = Vector3.new(4, 20, 4),
			cframe = CFrame.new(CENTRE + Vector3.new(side * 20, 10, 96)),
			parent = yard,
		})
	end
	local archBoard = Build.part({
		name = "ArchSign",
		size = Vector3.new(48, 8, 1.4),
		cframe = CFrame.lookAt(
			CENTRE + Vector3.new(0, 22, 96),
			CENTRE + Vector3.new(0, 22, 97)
		),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		parent = yard,
	})
	surface(archBoard, Enum.NormalId.Front, 0.72).Text = GameConfig.GAME_NAME

	--[[
		Lamps down both sides of the path.

		Placed off the walked line rather than on it: the path is the one part
		of this room every player crosses, and a lamp post in the middle of it
		is a thing to get stuck on.
	]]
	for _, z in { 86, 58, 14, -22, -70 } do
		for _, side in { -1, 1 } do
			Build.part({
				name = "LampPost",
				size = Vector3.new(0.9, 11, 0.9),
				cframe = CFrame.new(CENTRE + Vector3.new(side * 26, 5.5, z)),
				color = Palette.color(Palette.fence.rail),
				material = Enum.Material.SmoothPlastic,
				parent = yard,
			})
			local lamp = Build.mesh({
				prop = "Lantern",
				name = "Lantern",
				size = Vector3.new(2.6, 3.9, 2.4),
				cframe = CFrame.new(CENTRE + Vector3.new(side * 26, 12.6, z)),
				canCollide = false,
				parent = yard,
			})
			local glow = Instance.new("PointLight")
			glow.Color = Color3.fromRGB(255, 226, 158)
			glow.Range = 34
			glow.Brightness = 1.1
			glow.Parent = lamp
		end
	end

	-- The shed the whole business runs out of, off the left of the path.
	local shedAt = CENTRE + Vector3.new(-92, 0, 8)
	Build.mesh({
		prop = "Shed",
		name = "Shed",
		size = Vector3.new(32, 36, 32),
		cframe = CFrame.new(shedAt + Vector3.new(0, 18, 0)) * CFrame.Angles(0, math.rad(90), 0),
		collisionSize = Vector3.new(30, 34, 30),
		parent = yard,
	})
	Build.flagstone(yard, shedAt + Vector3.new(20, 1.15, 0), Vector2.new(26, 34), 5, rng)
	for index, spec in {
		{ prop = "Crate", size = Vector3.new(5, 3, 4), at = Vector3.new(22, 1.5, 18) },
		{ prop = "Crate", size = Vector3.new(5, 3, 4), at = Vector3.new(27, 1.5, 15) },
		{ prop = "Barrel", size = Vector3.new(4, 4.2, 4), at = Vector3.new(21, 2.1, -14) },
		{ prop = "Sack", size = Vector3.new(3, 4, 3.3), at = Vector3.new(26, 2, -18) },
		{ prop = "Toolbox", size = Vector3.new(3, 2.4, 1.8), at = Vector3.new(18, 1.2, -6) },
	} do
		Build.mesh({
			prop = spec.prop,
			name = spec.prop,
			size = spec.size,
			cframe = CFrame.new(shedAt + spec.at) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
			canCollide = false,
			parent = yard,
		})
		local _ = index
	end

	-- The kit, parked on the right where you can see what you are working for.
	local parkAt = CENTRE + Vector3.new(92, 0, 8)
	Build.flagstone(yard, parkAt, Vector2.new(46, 60), 6, rng)
	Build.mesh({
		prop = "Trailer",
		name = "Trailer",
		size = Vector3.new(10, 6.1, 15),
		cframe = CFrame.new(parkAt + Vector3.new(4, 3, -20)) * CFrame.Angles(0, math.rad(90), 0),
		collisionSize = Vector3.new(7, 4, 14),
		parent = yard,
	})
	for index, z in { 6, 20 } do
		Build.mesh({
			prop = "RidingMower",
			name = "RidingMower",
			size = Vector3.new(6.6, 7.2, 11.2),
			cframe = CFrame.new(parkAt + Vector3.new(index * 2 - 3, 3.6, z))
				* CFrame.Angles(0, math.rad(if index == 1 then 96 else 84), 0),
			collisionSize = Vector3.new(5, 5, 9),
			parent = yard,
		})
	end
	Build.mesh({
		prop = "Dog",
		name = "Dog",
		size = Vector3.new(2.4, 5.6, 4.6),
		cframe = CFrame.new(parkAt + Vector3.new(-16, 2.8, -6)) * CFrame.Angles(0, math.rad(-40), 0),
		canCollide = false,
		parent = yard,
	})

	-- Hedges framing the depot, so the middle of the yard reads as a place
	-- rather than as the gap between two piles of props.
	for _, side in { -1, 1 } do
		Build.hedge(
			yard,
			CENTRE + Vector3.new(side * 58, 0, 40),
			CENTRE + Vector3.new(side * 58, 0, -28),
			5,
			4
		)
	end

	--------------------------------------------------------------------
	-- The board at the far end
	--------------------------------------------------------------------

	local statusPost = Build.part({
		name = "StatusBoard",
		size = Vector3.new(120, 30, 1.5),
		--[[
			Raised, so the lawn signs at the near end cannot stand in front of
			it. A six-stud board thirty studs from the gate subtends more of
			the view than a thirty-stud board two hundred studs away, which is
			how the old arrangement managed to hide its own marquee.
		]]
		cframe = CFrame.lookAt(
			CENTRE + Vector3.new(0, 40, -112),
			CENTRE + Vector3.new(0, 40, -111)
		),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		parent = root,
	})
	for _, side in { -1, 1 } do
		Build.part({
			name = "BoardPost",
			size = Vector3.new(3, 55, 3),
			cframe = CFrame.new(CENTRE + Vector3.new(side * 56, 27.5, -112)),
			color = Palette.color(Palette.fence.rail),
			material = Enum.Material.SmoothPlastic,
			parent = root,
		})
	end
	--[[
		The board's top line, and what it says when there is no news.

		It only ever carried the result of the run you just came back from,
		which meant that on the one view every player is guaranteed to see —
		the first time they arrive, before they have played anything — the
		largest object in the game was a hundred and twenty studs of blank
		board with one line of instruction pushed into its bottom half. It
		reads as the game's masthead until there is an outcome to report.
	]]
	outcomeLabel = surface(statusPost, Enum.NormalId.Front, 0.32)
	local outcome = outcomeLabel :: TextLabel
	outcome.Position = UDim2.fromScale(0.04, 0.08)
	outcome.Text = GameConfig.GAME_NAME
	statusLabel = surface(statusPost, Enum.NormalId.Front, 0.38)
	local status = statusLabel :: TextLabel
	status.Position = UDim2.fromScale(0.04, 0.52)
	status.Text = "Stand on a pad and pick a property"

	--------------------------------------------------------------------
	-- Dressing
	--------------------------------------------------------------------

	-- Trees down both flanks, well clear of anything anybody has to read.
	for _, side in { -1, 1 } do
		for _, z in { 96, 58, 16, -30, -76 } do
			Build.mesh({
				prop = "Tree",
				name = "Tree",
				size = Vector3.new(24, 34, 24),
				collisionSize = Vector3.new(4, 30, 4),
				cframe = CFrame.new(CENTRE + Vector3.new(side * (halfW - 20), 17, z))
					* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
				parent = root,
			})
		end
	end

	-- Hedges along the inside of the flanks, and a few bushes about.
	for _, side in { -1, 1 } do
		Build.hedge(
			root,
			CENTRE + Vector3.new(side * (halfW - 34), 1, -100),
			CENTRE + Vector3.new(side * (halfW - 34), 1, 100),
			8,
			7
		)
	end
	for _ = 1, 14 do
		local x = rng:NextNumber(-halfW + 30, halfW - 30)
		local z = rng:NextNumber(-halfD + 24, halfD - 24)
		if math.abs(x) > 34 then
			Build.mesh({
				prop = "Bush",
				name = "Bush",
				size = Vector3.new(7, 7, 7),
				cframe = CFrame.new(CENTRE + Vector3.new(x, 3.5, z))
					* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
				canCollide = false,
				parent = root,
			})
		end
	end
end

--[[
	Standing on a pad means standing on the pad.

	This used to be a fixed seven-stud radius, which was smaller than the
	plaques it was testing: you could be stood squarely on The Gas Station with
	both feet on the stone and have the lobby decide you were on the grass. The
	pad's own footprint is the answer, with a stud of forgiveness at the edge.
]]
local function standingOn(part: BasePart, position: Vector3): boolean
	local offset = position - part.Position
	local reach = part.Size.X * 0.5 + 1
	return math.abs(offset.X) <= reach and math.abs(offset.Z) <= reach and math.abs(offset.Y) < 12
end

--- Everyone in the lobby right now, and where they are standing.
local function positions(): { [Player]: Vector3 }
	local out: { [Player]: Vector3 } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			out[player] = root.Position
		end
	end
	return out
end

--- Puts a player in the lobby, facing the property plaques.
function LobbyService.place(player: Player)
	build()
	local character = player.Character
	if not character or not character.PrimaryPart then
		return
	end
	local at = CENTRE + Vector3.new(0, 5, 104)
	character:PivotTo(CFrame.lookAt(at, at - Vector3.new(0, 0, 20)))
end

local function placeEveryone()
	for _, player in Players:GetPlayers() do
		LobbyService.place(player)
	end
end

--------------------------------------------------------------------
-- The loop
--------------------------------------------------------------------

--[[
	Whether the destination is settled.

	Anybody stood on a plaque used to be able to change where the team was
	going, right up to the last tick of the countdown — including somebody who
	was not on a pad and was not going. Once the count starts, the choice
	holds; stepping off the pads clears it and the room is open again.
]]
local function locked(): boolean
	return countdownLeft ~= nil
end

--[[
	The plaques say what a property asks of you.

	A board in the world is seen by everyone at once, so it cannot show one
	player their own progress — it names the requirement instead, and whether
	the person standing on it has met that is settled when they stand on it.
]]
local function refreshLevelLabels()
	for _, world in Worlds.list do
		local label = levelLabels[world.id]
		if label then
			local mark = if chosenWorld == world.id then "▶ " else ""
			label.Text = if world.requiresWorld
				then `{mark}{world.name}\nNeeds {Worlds.expect(world.requiresWorld).name}`
				else `{mark}{world.name}\n{world.difficulty}`
			label.TextColor3 = if chosenWorld == world.id
				then Color3.fromRGB(255, 244, 180)
				else Color3.fromRGB(255, 255, 255)
		end
	end
end

--[[
	One tick of the lobby.

	Occupancy is measured rather than touched: a `Touched` event fires on a
	brushed elbow and never fires again while you stand still, which is the
	opposite of what a pad wants to know.
]]
--[[
	Whether the team that is about to leave may play this property.

	`chosenWorld` is sticky on purpose: you step on a plaque to pick, then walk
	the ninety studs back to a team pad, and the choice has to survive the
	walk. What it also survived was the chooser. The plaque checks the record
	of the player standing on it — "It is the stepper's own record that decides
	now" — and then nothing ever looked again, so the team that actually
	departed was never the team that was tested. A player who has beaten The
	House could tap The Mansion, wander off, and the next first-timer to stand
	on a team pad was sent there alone.

	At least one of the departing players has to have earned it, which leaves
	a friend able to bring somebody along — the pads are a team, and a team of
	four going where one of them has been is the point of the room — while the
	empty case, where nobody leaving has the world open at all, is refused.
]]
local function teamAllows(team: { Player }, worldId: string): boolean
	local world = Worlds.expect(worldId)
	local required = world.requiresWorld
	if not required then
		return true
	end
	for _, player in team do
		local profile = DataService.get(player)
		if profile and profile.worldsBeaten[required] == true then
			return true
		end
	end
	return false
end

local function step(delta: number)
	if MowRunService.phase() ~= "lobby" then
		return
	end
	local where = positions()

	-- Who is on a team pad.
	local party = 0
	local team: { Player } = {}
	for index = 1, TEAM_PADS do
		local part = teamPads[index]
		local label = teamLabels[index]
		if part and label then
			local occupant: Player? = nil
			for player, position in where do
				if standingOn(part, position) then
					occupant = player
					break
				end
			end
			if occupant and DataService.get(occupant) == nil then
				--[[
					Stood on the pad, but their save has not landed yet.

					A run built before the profile arrives is a run without the
					tools they paid Robux for, so the pad waits rather than
					sending them into one.
				]]
				label.Text = "…"
				part.Color = Palette.color(Palette.ground.stoneDark)
			elseif occupant then
				party += 1
				table.insert(team, occupant)
				label.Text = occupant.DisplayName
				part.Color = Palette.color(Palette.ground.lawn)
			else
				label.Text = `{index}`
				part.Color = Palette.color(Palette.ground.stone)
			end
		end
	end

	if teamCountLabel then
		teamCountLabel.Text = `TEAM {party} / {TEAM_PADS}`
	end

	--[[
		A property is unlocked by the player standing on it, and nobody else.

		The unlocks used to be pooled: every profile in the lobby was rolled
		into one set and the plaque was tested against that. So a first-time
		player could stand on The Gas Station and take it, provided somebody
		who had beaten The Mansion happened to be in the room — progression
		you could walk past rather than earn. It is the stepper's own record
		that decides now.
	]]
	for id, part in levelPads do
		for player, position in where do
			if standingOn(part, position) and not locked() then
				local world = Worlds.expect(id)
				local profile = DataService.get(player)
				local beaten = if profile then profile.worldsBeaten else nil
				local allowed = not world.requiresWorld
					or (beaten ~= nil and beaten[world.requiresWorld] == true)
				if allowed then
					chosenWorld = id
				end
			end
		end
	end

	refreshLevelLabels()

	-- Ready when somebody is on a pad, a property is picked, and somebody
	-- leaving has actually earned it.
	local status = statusLabel
	local allowed = chosenWorld ~= nil and teamAllows(team, chosenWorld :: string)
	if party > 0 and chosenWorld and allowed then
		countdownLeft = (countdownLeft or COUNTDOWN) - delta
		local left = math.max(math.ceil(countdownLeft or 0), 0)
		if status then
			status.Text = `{Worlds.expect(chosenWorld).name} — team of {party} — starting in {left}`
		end
		if (countdownLeft or 0) <= 0 then
			local id = chosenWorld
			countdownLeft = nil
			chosenWorld = nil
			if status then
				--[[
					The team leaves; the lobby does not.

					Only the players on the pads are sent, so anybody still
					choosing keeps a working room around them rather than
					being dragged into somebody else's lawn.
				]]
				status.Text = "Finding you a lawn…"
			end
			MatchmakingService.send(team, id, party)
		end
	else
		countdownLeft = nil
		if status then
			--[[
				What to say to somebody who is already standing on a pad.

				Players are placed at the south end and walk north, which takes
				them over the team pads before the property plaques — so the
				first thing a new player does is stand on a pad and get told
				"Stand on a pad and pick a property", while standing on a pad.
				`chosenWorld` is sticky and survives the walk, so the room does
				work in that order; it just never said which half was missing.

				The plaques cannot simply be moved in front of the pads: their
				boards are eighteen studs tall and would sit close enough to the
				entrance to hide the status board behind them, which is the one
				thing in the room that explains what is happening.
			]]
			status.Text = if chosenWorld and party > 0 and not allowed
				then `{Worlds.expect(chosenWorld).name} — somebody on the pads has to have cleared `
					.. Worlds.expect((Worlds.expect(chosenWorld).requiresWorld :: any)).name
				elseif chosenWorld
					then `{Worlds.expect(chosenWorld).name} — stand on a team pad to start`
				elseif party > 0
					then "Now pick a property — the plaques are further in"
				else "Stand on a team pad, and pick a property on the plaques"
		end
	end
end

function LobbyService.start()
	build()

	--[[
		The lobby is entered by watching the phase rather than by being told.

		`RunService` owns the phase and has no signal for it, and giving it one
		so the lobby could subscribe would have the run reaching into the menu.
		A poll costs a table walk a few times a second and keeps the arrow
		pointing one way.
	]]
	task.spawn(function()
		local last = os.clock()
		while true do
			local now = os.clock()
			local delta = now - last
			last = now

			local phase = MowRunService.phase()
			if phase ~= lastPhase then
				if phase == "won" or phase == "lost" then
					lastOutcome = phase
					lastWorldName = Worlds.expect(MowRunService.worldId()).name
				elseif phase == "lobby" then
					-- Back from a run: gather everyone in and say how it went.
					local label = outcomeLabel
					if label then
						label.Text = if lastOutcome == "won" and lastWorldName
							then `You cleared {lastWorldName}!`
							elseif lastOutcome == "lost" and lastWorldName
								then `The clock beat you on {lastWorldName}.`
							else GameConfig.GAME_NAME
					end
					chosenWorld = nil
					countdownLeft = nil
					placeEveryone()
				end
				lastPhase = phase
			end

			local ok = pcall(step, delta)
			if not ok then
				warn("[Lobby] a tick failed; the yard keeps running")
			end
			task.wait(0.25)
		end
	end)

	-- Somebody arriving between runs belongs in the lobby, not on the last lot.
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			task.wait(0.3)
			if MowRunService.phase() == "lobby" then
				LobbyService.place(player)
			end
		end)
	end)
end

return LobbyService
