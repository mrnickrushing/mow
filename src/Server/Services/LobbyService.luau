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
local LobbyPad = require(Shared.LobbyPad)
local Palette = require(Shared.Config.Palette)
local Remotes = require(Shared.Remotes)
local Worlds = require(Shared.Config.Worlds)
local Build = require(script.Parent.Parent.Lib.Build)
local Loop = require(Shared.Util.Loop)
local DataService = require(script.Parent.DataService)
local MowEconomyService = require(script.Parent.EconomyService)
local MowRunService = require(script.Parent.RunService)
local MatchmakingService = require(script.Parent.MatchmakingService)

local LobbyService = {}

--- Far enough from every lot that nothing can ever overlap it.
--[[
	Where the yard stands, and why it stands so far out.

	The lobby is its own server — a public one, which never starts a run by
	itself; confirming a pad reserves a server and teleports that team to it.
	But a lobby server still loads a property, because the opening story needs
	something to point a camera at and a player has to have somewhere to
	stand before one is chosen.

	At 600 out, that property was 490 studs from the edge of the yard and the
	fog does not close until 1400, so the lot you had not chosen yet sat on
	the horizon behind the fence: a line of autumn trees over the pads,
	which makes the lobby look like a corner of the map rather than a place of
	its own. Far enough out that the nearest property is past the fog, and the
	lobby is the only thing there is to see.
]]
local CENTRE = Vector3.new(-2600, 0, -2600)
--[[
	A yard, not a field.

	This was two hundred and sixty studs square with the pads sixty-two apart,
	which is a long walk between two things you are trying to compare and a lot
	of empty grass in every direction. Everything a player has to read now sits
	inside about a hundred and sixty, close enough that the four games are one
	glance rather than a tour.
]]
local FLOOR_W, FLOOR_D = 160, 160
--- Games that can be set up side by side in the yard, and the most people
--- any one of them can take.
-- The largest team one pad has to plan for; shared so a change here cannot
-- drift out of step with the level select panel or the journal.
local GAME_SLOTS = GameConfig.MAX_PARTY
--- Seconds between a team being ready and the property loading.
local COUNTDOWN = 6
--- Seconds a set-up game may stand empty before it goes back to being an offer.
local ABANDON_SECONDS = 20

local folder: Folder? = nil
--[[
	A game somebody can join, of which there are `GAME_SLOTS`.

	Each carries its own map, party size and countdown, so two groups in the
	yard are setting up two runs rather than fighting over one.
]]
export type Slot = {
	index: number,
	pad: BasePart,
	padLabel: TextLabel,
	--- The white "0/4" over the green invitation, kept apart so each keeps its
	--- own colour.
	padCount: TextLabel,
	boardLabel: TextLabel,
	worldId: string?,
	cap: number,
	countdown: number?,
	--- Seconds this game has stood empty, so an abandoned one clears itself.
	idle: number,
}

local slots: { Slot } = {}
local statusLabel: TextLabel? = nil
--- The board over the pads that says how many of you are going.
local outcomeLabel: TextLabel? = nil

--[[
	The party size the pads were set to, from the settings panel.

	The room could only ever count how many people were standing on pads. It
	had no way to say how many you were *waiting* for, which is why a lone
	player had nothing telling them one was a valid answer. Defaults to the
	full four, so the behaviour without the panel is what it always was.
]]
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
	A pad you stand on, drawn as a glowing outline rather than a slab.

	The reference marks its game pads with a bright rectangle burnt into the
	grass — the lawn shows through the middle and only the edge glows. A solid
	grey slab reads as a bit of pavement somebody left out; an outline reads as
	somewhere to stand, which is the whole job of the thing.

	The part that does the standing-on is invisible: it is there to be measured
	against and to hang the floating count on, and the four neon edges are what
	you actually see.
]]
local function glowPad(name: string, at: Vector3, span: number, parent: Instance): BasePart
	local plate = Build.part({
		name = name,
		size = Vector3.new(span, 0.4, span),
		cframe = CFrame.new(at),
		color = Palette.color(Palette.ground.lawn),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = parent,
	})
	plate.Transparency = 1

	local half = span * 0.5
	for _, edge in {
		{ Vector3.new(span, 0.35, 1.6), Vector3.new(0, 0, half) },
		{ Vector3.new(span, 0.35, 1.6), Vector3.new(0, 0, -half) },
		{ Vector3.new(1.6, 0.35, span), Vector3.new(half, 0, 0) },
		{ Vector3.new(1.6, 0.35, span), Vector3.new(-half, 0, 0) },
	} do
		local strip = Build.part({
			name = "PadEdge",
			size = edge[1],
			cframe = CFrame.new(at + edge[2]),
			color = Color3.fromRGB(255, 255, 255),
			material = Enum.Material.Neon,
			canCollide = false,
			parent = parent,
		})
		strip.CastShadow = false
	end
	return plate
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

	--[[
		Where the dressing may not stand.

		Lamp posts, trees and bushes are laid out to a pattern — a row down
		each flank, a scatter across the grass — and a pattern does not know
		what is already there. A lamp post came out standing inside the shed
		and a tree grew up through the trailer, because both rows ran straight
		through the yard's furniture at exactly the wrong offset, and two
		bushes landed two studs apart and merged into one lumpy blob.

		Every solid piece registers its footprint here, and anything
		decorative asks before it stands anywhere. Move the shed tomorrow and
		the lamp beside it steps aside on its own.
	]]
	local reserved: { { min: Vector2, max: Vector2 } } = {}
	local function reserve(at: Vector3, width: number, depth: number)
		local half = Vector2.new(width, depth) * 0.5
		local centre = Vector2.new(at.X, at.Z)
		table.insert(reserved, { min = centre - half, max = centre + half })
	end

	--[[
		Whether a piece `radius` studs across can stand at `at`.

		Two studs of daylight either side, so nothing merely grazes a wall —
		touching reads as badly as overlapping from a few paces away.
	]]
	local function clearAt(at: Vector3, radius: number): boolean
		local reach = radius + 2
		for _, area in reserved do
			if
				at.X + reach > area.min.X
				and at.X - reach < area.max.X
				and at.Z + reach > area.min.Y
				and at.Z - reach < area.max.Y
			then
				return false
			end
		end
		return true
	end

	--[[
		The nearest clear spot to `at` along the row, searched outward.

		A row with a gap in it looks like a mistake; a row that bends around
		the shed looks like somebody put it there. Returns nil only if there
		is no room within a couple of spacings, and then the caller does leave
		the gap, because at that point the spot really is taken.
	]]
	local function nudgeAlongZ(at: Vector3, radius: number): Vector3?
		for step = 0, 21, 3 do
			for _, direction in { 1, -1 } do
				local try = at + Vector3.new(0, 0, step * direction)
				if clearAt(try, radius) then
					return try
				end
				if step == 0 then
					break
				end
			end
		end
		return nil
	end

	--[[
		Ground that reaches past the fence.

		The yard is a hundred and sixty square and everything that makes it
		feel like somewhere is not: the six neighbour houses stand a hundred
		and sixteen out, their roofs further, and the hedge along the back
		beyond that. All of it was standing on nothing. From inside the yard,
		at eye level, you could see the grass simply stop and the sky carry
		on underneath — a lawn floating in the air with a street floating
		beside it.

		So the lawn is the yard, and this is the ground the yard sits in. It
		runs out past the fog, which is the only edge a player should ever
		find: not a cliff, just distance.
	]]
	Build.part({
		name = "Surround",
		size = Vector3.new(3000, 2, 3000),
		cframe = CFrame.new(CENTRE - Vector3.new(0, 1.1, 0)),
		color = Palette.color(Palette.ground.lawn),
		material = Enum.Material.Grass,
		castShadow = false,
		parent = root,
	})

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
		CENTRE + Vector3.new(0, 1.15, 16),
		Vector2.new(14, 108),
		5,
		rng
	)

	--------------------------------------------------------------------
	-- The games on offer
	--------------------------------------------------------------------

	--[[
		One pad, one game.

		The room used to have a single property choice shared by everybody in
		it: three plaques you stood on, four pads you stood on afterwards, and
		one choice between the lot. With one group in the yard that works. With
		two it is a fight — whoever last touched a plaque decides where the
		other four are about to be sent — and on a fifty-player server it is
		chaos.

		A pad is a game now. It carries its own map, its own party size and its
		own countdown, so four groups can be setting up four different runs
		side by side without touching each other. Standing on one opens the
		settings for that game; the board behind it says what it is.
	]]
	for index = 1, GAME_SLOTS do
		local x = (index - (GAME_SLOTS + 1) * 0.5) * LobbyPad.SPACING
		local at = CENTRE + Vector3.new(x, 1.5, 8)
		local padPart = glowPad(
			`{GameConfig.LOBBY_PAD_PREFIX}{index}`,
			at - Vector3.new(0, 1.3, 0),
			LobbyPad.SPAN,
			root
		)

		--[[
			The count floats over the pad rather than being painted on it.

			Text on a Top face is read at whatever angle you happen to be
			standing at, which for somebody walking up to a pad is almost edge
			on — the words smear into the grass and you cannot tell a "0/4"
			from a "2/4". A billboard faces you wherever you are, which is what
			the reference game does with exactly this label, and it is the one
			piece of information a player crossing the yard is actually
			looking for.
		]]
		--[[
			Two lines, the way the reference stacks them: the count in white
			above the call to action in green.

			One label carrying both meant one colour for both, and the count
			is a fact while "Create a game!" is an invitation — the reference
			paints them differently for that reason and it is most of why its
			pads read at a glance.
		]]
		--[[
			Small, and sitting close over its own pad.

			Seventeen studs wide by eight tall, lifted four, meant the label
			occupied everything from the grass to well above head height and
			was drawn at that size whatever you were doing. Standing beside
			one it filled the screen; crossing the yard, four of them hung in
			the air over the trees and the trailer with their words cut in
			half by whatever they happened to pass behind. The reference
			keeps this tight to the pad, and it is a label on a thing rather
			than a sign in the sky.
		]]
		local floating = Build.billboard(padPart, UDim2.fromScale(11, 4.6), 2.8, 260)
		local padCount = Build.label(floating, "", UDim2.fromScale(1, 0.42), UDim2.fromScale(0, 0), 1.7)
		local padLabel = Build.label(floating, "", UDim2.fromScale(1, 0.58), UDim2.fromScale(0, 0.42), 2.2)
		padLabel.TextColor3 = Color3.fromRGB(126, 232, 106)

		-- The board behind it, at head height and low enough that four of them
		-- in a row do not wall the yard off from its own marquee.
		--[[
			A timber board, leaned back the way a sign in a yard leans.

			Flat teal panels standing dead vertical read as menu furniture. The
			reference frames every one of these in brown wood on wooden posts
			and tilts it towards whoever is walking up, which is what makes its
			lobby look like a place rather than a screen.
		]]
		--[[
			Turned to face the gate, then leaned back.

			A part's `Front` face is its own -Z, so a board left at the
			identity orientation shows its blank back to anybody walking up and
			paints its writing on the fence behind it. `lookAt` turns it round
			first; the lean goes on after, and its sign flips with the turn.
		]]
		local function facing(at: Vector3): CFrame
			return CFrame.lookAt(at, at + Vector3.new(0, 0, 1)) * CFrame.Angles(math.rad(12), 0, 0)
		end
		Build.part({
			name = `GameBoardFrame{index}`,
			size = Vector3.new(30, 11, 1.3),
			cframe = facing(CENTRE + Vector3.new(x, 12, -10)),
			color = Palette.color(Palette.fence.rail),
			material = Enum.Material.WoodPlanks,
			parent = root,
		})
		local board = Build.part({
			name = `GameBoard{index}`,
			size = Vector3.new(27.5, 8.5, 1),
			--[[
				High enough to clear the count floating over its own pad.

				Both were at head height and they sat straight on top of each
				other from the near side of the yard: "2/4 Starting in 4"
				printed across "The House EASY" and neither could be read.
			]]
			cframe = facing(CENTRE + Vector3.new(x, 12, -9.2)),
			color = Palette.color(Palette.house.siding),
			material = Enum.Material.SmoothPlastic,
			parent = root,
		})
		for _, side in { -1, 1 } do
			Build.part({
				name = "BoardLeg",
				size = Vector3.new(1.6, 13, 1.6),
				cframe = CFrame.new(CENTRE + Vector3.new(x + side * 13, 6.5, -9.5)),
				color = Palette.color(Palette.house.roof),
				material = Enum.Material.WoodPlanks,
				parent = root,
			})
		end

		slots[index] = {
			index = index,
			pad = padPart,
			padLabel = padLabel,
			padCount = padCount,
			boardLabel = surface(board, Enum.NormalId.Front, 0.8),
			worldId = nil,
			cap = GAME_SLOTS,
			countdown = nil,
			idle = 0,
		}
	end

	--[[
		No writing on the grass.

		A strip of text laid flat is read at whatever angle you happen to be
		standing at, which walking towards it means almost edge on: it smeared
		across the middle of the yard and said nothing legible. The boards and
		the pads already carry the instruction — "Select a map!" over a game
		nobody has set up, "Create a game!" on the pad under it — so the strip
		was a third voice saying the same thing worse.
	]]

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
			cframe = CFrame.new(CENTRE + Vector3.new(side * 15, 9, 58)),
			parent = yard,
		})
	end
	local archBoard = Build.part({
		name = "ArchSign",
		size = Vector3.new(36, 7, 1.3),
		cframe = CFrame.lookAt(
			CENTRE + Vector3.new(0, 20, 58),
			CENTRE + Vector3.new(0, 20, 59)
		),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		parent = yard,
	})
	surface(archBoard, Enum.NormalId.Front, 0.72).Text = GameConfig.GAME_NAME

	--[[
		The two big pieces are sited before anything is laid out around them.

		They are built further down, where the rest of their dressing is; what
		happens here is only that the yard learns their footprints, in time
		for the lamp row below to route around them.
	]]
	local shedAt = CENTRE + Vector3.new(-56, 0, 34)
	local parkAt = CENTRE + Vector3.new(56, 0, 34)
	reserve(shedAt, 24, 24)
	-- The trailer is parked across the drive, so it is wide, not deep.
	reserve(parkAt + Vector3.new(4, 0, -20), 15, 8)
	for index, z in { 6, 20 } do
		reserve(parkAt + Vector3.new(index * 2 - 3, 0, z), 10, 6)
	end

	--[[
		Lamps down both sides of the path.

		Placed off the walked line rather than on it: the path is the one part
		of this room every player crosses, and a lamp post in the middle of it
		is a thing to get stuck on. Off the line is not the same as clear of
		everything, though — the left-hand row ran through the shed — so each
		one takes the nearest spot to its slot that is actually free.
	]]
	for _, z in { 50, 24, -2, -28 } do
		for _, side in { -1, 1 } do
			local at = nudgeAlongZ(CENTRE + Vector3.new(side * 62, 0, z), 1)
			if at then
				Build.part({
					name = "LampPost",
					size = Vector3.new(0.9, 11, 0.9),
					cframe = CFrame.new(at + Vector3.new(0, 5.5, 0)),
					color = Palette.color(Palette.fence.rail),
					material = Enum.Material.SmoothPlastic,
					parent = yard,
				})
				local lamp = Build.mesh({
					prop = "Lantern",
					name = "Lantern",
					size = Vector3.new(2.6, 3.9, 2.4),
					cframe = CFrame.new(at + Vector3.new(0, 12.6, 0)),
					canCollide = false,
					parent = yard,
				})
				local glow = Instance.new("PointLight")
				glow.Color = Color3.fromRGB(255, 226, 158)
				glow.Range = 34
				glow.Brightness = 1.1
				glow.Parent = lamp
				reserve(at, 3, 3)
			end
		end
	end

	-- The shed the whole business runs out of, off the left of the path.
	Build.mesh({
		prop = "Shed",
		name = "Shed",
		size = Vector3.new(24, 27, 24),
		cframe = CFrame.new(shedAt + Vector3.new(0, 13.5, 0)) * CFrame.Angles(0, math.rad(90), 0),
		collisionSize = Vector3.new(22, 25, 22),
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
		-- The stock outside the shed is furniture too: a bush landed on the
		-- barrel before these were on the map the scatter checks against.
		reserve(shedAt + spec.at, spec.size.X + 3, spec.size.Z + 3)
		local _ = index
	end

	-- The kit, parked on the right where you can see what you are working for.
	-- (sited above, with the shed.)
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

	--[[
		The depot used to get its own short hedge either side, at the same 46
		studs out that the flanks were wrongly using — so it was planted in the
		first and last pad along with them. The flank line now runs the full
		depth of the lawn outside the pads, which already frames the yard; a
		second row on the same line would only be fourteen more parts in the
		same place.
	]]

	--------------------------------------------------------------------
	-- The street it stands on
	--------------------------------------------------------------------

	--[[
		Neighbours over the fence.

		The yard had an empty horizon in every direction, which is what made it
		read as a menu with a lawn in it rather than as somewhere. The
		reference has a row of suburban houses standing over its back fence,
		close enough to see the porches and the pitched roofs, and it does most
		of the work of making the room feel like a place.

		Built out of the same siding and gable the properties are built from,
		so the street the lobby stands on is the same street the jobs are on.
		They sit well outside the fence and nothing walks over there, so they
		are scenery rather than geometry: no collision, no detail beyond a
		silhouette with windows and a door in it.
	]]
	local street = Build.folder("Street", root)
	local roofs = { Palette.house.roof, Palette.house.roofDark, Palette.house.brick }
	local sidings = { Palette.house.siding, Palette.house.sidingShade, Palette.house.garage }

	local plots = {
		{ at = Vector3.new(-104, 0, -96), width = 40, depth = 30, turn = 0 },
		{ at = Vector3.new(-36, 0, -108), width = 46, depth = 32, turn = 0 },
		{ at = Vector3.new(36, 0, -104), width = 42, depth = 30, turn = 0 },
		{ at = Vector3.new(106, 0, -92), width = 40, depth = 34, turn = 22 },
		{ at = Vector3.new(-116, 0, -8), width = 36, depth = 44, turn = 90 },
		{ at = Vector3.new(116, 0, -18), width = 36, depth = 44, turn = -90 },
	}

	for index, plot in plots do
		local body = Build.folder(`House{index}`, street)
		local siding = Palette.color(sidings[(index - 1) % #sidings + 1])
		local roof = Palette.color(roofs[(index - 1) % #roofs + 1])
		local wallHeight = 20 + (index % 3) * 3
		local base = CENTRE + plot.at
		local turn = CFrame.Angles(0, math.rad(plot.turn), 0)

		local shell = Build.part({
			name = "Shell",
			size = Vector3.new(plot.width, wallHeight, plot.depth),
			cframe = CFrame.new(base + Vector3.new(0, wallHeight * 0.5, 0)) * turn,
			color = siding,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = body,
		})
		shell.CastShadow = true

		Build.gableRoof(
			body,
			base + Vector3.new(0, 0, 0),
			plot.width,
			plot.depth,
			wallHeight,
			8,
			2.5,
			roof,
			Palette.color(Palette.house.trim),
			siding
		)

		-- A door and a couple of windows, because a blank box is a box.
		local frontZ = plot.depth * 0.5 + 0.4
		Build.part({
			name = "Door",
			size = Vector3.new(6, 10, 0.6),
			cframe = CFrame.new(base) * turn * CFrame.new(0, 5, frontZ),
			color = Palette.color(Palette.house.door),
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = body,
		})
		for _, side in { -1, 1 } do
			Build.part({
				name = "Window",
				size = Vector3.new(7, 7, 0.6),
				cframe = CFrame.new(base) * turn * CFrame.new(side * plot.width * 0.28, 11, frontZ),
				color = Palette.color(Palette.house.window),
				material = Enum.Material.SmoothPlastic,
				canCollide = false,
				parent = body,
			})
		end
	end

	--[[
		A hedge line along the back, so the houses sit behind something rather
		than floating on the same grass the pads are on.

		It stops where the flank hedges are rather than running past them. At
		seventy-eight it overran both by eight studs and the two runs crossed,
		which from inside the yard is a bush growing sideways out of a hedge.
		Ending it just short of the flank's own thickness turns the crossing
		into the corner it was always meant to be.
	]]
	local backX = LobbyPad.flankX(GAME_SLOTS) - 4
	Build.hedge(
		street,
		CENTRE + Vector3.new(-backX, 0, -74),
		CENTRE + Vector3.new(backX, 0, -74),
		7,
		5
	)

	--------------------------------------------------------------------
	-- The board at the far end
	--------------------------------------------------------------------

	local statusPost = Build.part({
		name = "StatusBoard",
		size = Vector3.new(78, 18, 1.4),
		--[[
			Raised, so the lawn signs at the near end cannot stand in front of
			it. A six-stud board thirty studs from the gate subtends more of
			the view than a thirty-stud board two hundred studs away, which is
			how the old arrangement managed to hide its own marquee.
		]]
		cframe = CFrame.lookAt(
			CENTRE + Vector3.new(0, 27, -34),
			CENTRE + Vector3.new(0, 27, -33)
		),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		parent = root,
	})
	for _, side in { -1, 1 } do
		Build.part({
			name = "BoardPost",
			size = Vector3.new(2.4, 36, 2.4),
			cframe = CFrame.new(CENTRE + Vector3.new(side * 37, 18, -34)),
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

	--[[
		Trees down both flanks, well clear of anything anybody has to read.

		Clearance is measured on the trunk, not the canopy. A branch reaching
		over a shed roof is what a tree beside a shed looks like; a trunk
		coming up through the trailer is not, and that is exactly what the
		right-hand row used to do at the second slot down.
	]]
	for _, side in { -1, 1 } do
		for _, z in { 56, 20, -18, -50 } do
			local at = nudgeAlongZ(CENTRE + Vector3.new(side * (halfW - 20), 0, z), 2)
			if at then
				Build.mesh({
					prop = "Tree",
					name = "Tree",
					size = Vector3.new(24, 34, 24),
					collisionSize = Vector3.new(4, 30, 4),
					cframe = CFrame.new(at + Vector3.new(0, 17, 0))
						* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
					parent = root,
				})
				reserve(at, 6, 6)
			end
		end
	end

	-- Hedges along the inside of the flanks, and a few bushes about.
	local flankX = LobbyPad.flankX(GAME_SLOTS)
	for _, side in { -1, 1 } do
		Build.hedge(
			root,
			CENTRE + Vector3.new(side * flankX, 1, -100),
			CENTRE + Vector3.new(side * flankX, 1, 100),
			8,
			7
		)
	end
	--[[
		A scatter is only a scatter if the pieces are apart.

		Fourteen throws at the grass with nothing checking where the last one
		landed put two seven-stud bushes two studs apart, which from any angle
		is one lumpy bush with a seam down it. Each throw now has a few
		attempts to find somewhere free — of the other bushes, of the trees,
		and of the yard's furniture — and gives up quietly rather than piling
		on top of something.
	]]
	for _ = 1, 14 do
		for _ = 1, 8 do
			local x = rng:NextNumber(-halfW + 30, halfW - 30)
			local z = rng:NextNumber(-halfD + 24, halfD - 24)
			local at = CENTRE + Vector3.new(x, 0, z)
			if math.abs(x) > 34 and clearAt(at, 3.5) then
				Build.mesh({
					prop = "Bush",
					name = "Bush",
					size = Vector3.new(7, 7, 7),
					cframe = CFrame.new(at + Vector3.new(0, 3.5, 0))
						* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
					canCollide = false,
					parent = root,
				})
				reserve(at, 7, 7)
				break
			end
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
	return LobbyPad.partCovers(part, position)
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
	local at = CENTRE + Vector3.new(0, 5, 62)
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
	The game a player is standing on, if any.

	Settings are confirmed against a pad rather than against the room, which
	is the whole point of there being four of them: two groups setting up at
	once are setting up two games, not overwriting one.
]]
local function slotUnder(player: Player): Slot?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	for _, slot in slots do
		if standingOn(slot.pad, root.Position) then
			return slot
		end
	end
	return nil
end

--[[
	The plaques say what a property asks of you.

	A board in the world is seen by everyone at once, so it cannot show one
	player their own progress — it names the requirement instead, and whether
	the person standing on it has met that is settled when they stand on it.
]]

--[[
	One tick of the lobby.

	Occupancy is measured rather than touched: a `Touched` event fires on a
	brushed elbow and never fires again while you stand still, which is the
	opposite of what a pad wants to know.
]]
--[[
	Whether the group about to leave this pad may play what it is set to.

	The settings panel already checks the record of whoever pressed Confirm,
	but the group that departs is not necessarily the one that set the game up:
	somebody can walk off after choosing, and somebody else can walk on. So it
	is checked again at the moment of leaving.

	One of them having earned it is enough, which leaves a friend able to bring
	somebody along — four pads exist so that four people can go together, and a
	team going where one of them has been is the point of that. The case it
	refuses is the empty one, where nobody leaving has the property open at all.
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

--[[
	One tick of the lobby: every game on offer, considered on its own.

	Occupancy is measured rather than touched: a `Touched` event fires on a
	brushed elbow and never fires again while you stand still, which is the
	opposite of what a pad wants to know.
]]
local function step(delta: number)
	if MowRunService.phase() ~= "lobby" then
		return
	end
	local where = positions()
	local anyReady = false

	for _, slot in slots do
		--[[
			Who is standing on this pad, in a stable order.

			`positions()` is a map keyed by player, and iterating one of those
			gives no order at all — so without sorting, the party that gets cut
			at the cap would be a different four every tick.
		]]
		local here: { Player } = {}
		for player, position in where do
			if standingOn(slot.pad, position) then
				table.insert(here, player)
			end
		end
		table.sort(here, function(a, b)
			return a.UserId < b.UserId
		end)

		local team: { Player } = {}
		local waiting = false
		local turnedAway = 0
		for _, player in here do
			if DataService.get(player) == nil then
				--[[
					Stood on the pad, but their save has not landed yet.

					A run built before the profile arrives is a run without the
					tools they paid Robux for, so the pad waits rather than
					sending them into one.
				]]
				waiting = true
			elseif #team < slot.cap then
				table.insert(team, player)
			else
				--[[
					One too many for the size this game was set to.

					Standing on a full pad did nothing whatsoever — no message,
					no mark on the pad, just quietly not being in the game
					everybody else on it was about to leave for. That is the
					same silence that made standing on a pad feel broken in the
					first place, so the pad says it.
				]]
				turnedAway += 1
			end
		end

		if #here > 0 then
			slot.idle = 0
		end

		local world = if slot.worldId then Worlds.get(slot.worldId) else nil
		local ready = #team > 0
			and world ~= nil
			and teamAllows(team, slot.worldId :: string)

		if ready then
			anyReady = true
			slot.countdown = (slot.countdown or COUNTDOWN) - delta
			local left = math.max(math.ceil(slot.countdown or 0), 0)
			slot.padCount.Text = if turnedAway > 0 then `{#team}/{slot.cap} — FULL` else `{#team}/{slot.cap}`
			slot.padLabel.Text = `Starting in {left}`
			slot.pad.Color = Palette.color(Palette.ground.lawn)

			if (slot.countdown or 0) <= 0 then
				local id = slot.worldId :: string
				slot.countdown = nil
				slot.worldId = nil
				slot.cap = GAME_SLOTS
				slot.idle = 0
				--[[
					This game leaves; the yard does not.

					Only the players on this pad are sent, so the three games
					beside it carry on being set up rather than being dragged
					into somebody else's lawn.
				]]
				MatchmakingService.send(team, id, #team)
			end
		else
			slot.countdown = nil
			if waiting then
				slot.padCount.Text = ""
				slot.padLabel.Text = "…"
				slot.pad.Color = Palette.color(Palette.ground.stoneDark)
			elseif world and #team > 0 then
				-- Somebody is on it with a map set that none of them has earned.
				slot.padCount.Text = `{#team}/{slot.cap}`
				slot.padLabel.Text = `Needs {Worlds.expect((world :: any).requiresWorld).name}`
				slot.pad.Color = Palette.color(Palette.ground.stoneDark)
			elseif world then
				--[[
					Set up, but nobody on it — so it is counting itself out.

					A game keeps its map after whoever chose it walks off,
					which is right for the second or two it takes somebody to
					step aside and let a friend on. Kept forever it is litter:
					a pad reading "The Mansion" that a new player cannot use
					and has to work out how to reset, on a property they have
					not unlocked. Empty for long enough and it goes back to
					being an offer.
				]]
				slot.idle += delta
				if slot.idle >= ABANDON_SECONDS then
					slot.worldId = nil
					slot.cap = GAME_SLOTS
					slot.idle = 0
					slot.padCount.Text = `0/{slot.cap}`
					slot.padLabel.Text = "Create a game!"
				else
					slot.padCount.Text = `0/{slot.cap}`
					slot.padLabel.Text = "Stand here"
				end
				slot.pad.Color = Palette.color(Palette.ground.stone)
			else
				slot.padCount.Text = `0/{slot.cap}`
				slot.padLabel.Text = "Create a game!"
				slot.pad.Color = Palette.color(Palette.ground.stone)
			end
		end

		--[[
			"???" over the instruction while no map is set.

			The reference writes the unchosen map as three question marks
			above "Select a map!", so the board has the same two lines whether
			or not it has been set: the name, then what it is. Without the
			question marks an unset board is one line and a set one is two,
			and the row of four jumps about as people choose.
		]]
		slot.boardLabel.Text = if world
			then `{(world :: any).name}\n{string.upper((world :: any).difficulty)}`
			else "???\nSelect a map!"
	end

	local status = statusLabel
	if status then
		status.Text = if anyReady
			then "Off you go — good luck out there"
			else "Stand on a pad to set a game up"
	end
end

--[[
	The settings panel, confirmed.

	Sets the property and the party size in one go, from the player who pressed
	the button — checked against their own record, the same way the plaques
	are, so confirming a map you have not unlocked is refused here as well as
	there.
]]
local function onConfirm(player: Player, payload: any)
	if MowRunService.phase() ~= "lobby" or type(payload) ~= "table" then
		return
	end
	local worldId = (payload :: any).worldId
	local wanted = tonumber((payload :: any).maxPlayers)
	if type(worldId) ~= "string" or not Worlds.get(worldId) or not wanted then
		return
	end

	local world = Worlds.expect(worldId)
	local profile = DataService.get(player)
	local beaten = if profile then profile.worldsBeaten else nil
	local allowed = not world.requiresWorld
		or (beaten ~= nil and beaten[world.requiresWorld] == true)
	if not allowed then
		MowEconomyService.notify(
			player,
			"denied",
			`{world.name} needs {Worlds.expect(world.requiresWorld :: string).name} first`,
			nil
		)
		return
	end

	local slot = slotUnder(player)
	if not slot then
		MowEconomyService.notify(player, "denied", "Stand on a pad to set a game up", nil)
		return
	end
	if slot.countdown then
		--[[
			Already counting down, so the settings are settled — and saying so
			matters more than the refusal does. Pressing a green Confirm and
			getting nothing back is the same silence that made standing on a
			pad feel broken; the button is real, the game is just already on
			its way.
		]]
		MowEconomyService.notify(
			player,
			"denied",
			"That game is already starting — take another pad to change one",
			nil
		)
		return
	end

	slot.worldId = worldId
	slot.cap = math.clamp(math.floor(wanted), 1, GAME_SLOTS)
	MowEconomyService.notify(
		player,
		"quest",
		`{world.name} — up to {slot.cap} player{if slot.cap == 1 then "" else "s"}`,
		nil
	)
end

function LobbyService.start()
	build()

	Remotes.event(Remotes.LOBBY_CONFIRM).OnServerEvent:Connect(onConfirm)

	--[[
		The lobby is entered by watching the phase rather than by being told.

		`RunService` owns the phase and has no signal for it, and giving it one
		so the lobby could subscribe would have the run reaching into the menu.
		A poll costs a table walk a few times a second and keeps the arrow
		pointing one way.
	]]
		local last = os.clock()
	Loop.forever("Lobby.tick", function()
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
				for _, slot in slots do
					slot.worldId = nil
					slot.cap = GAME_SLOTS
					slot.countdown = nil
					slot.idle = 0
				end
				placeEveryone()
			end
			lastPhase = phase
		end

		local ok = pcall(step, delta)
		if not ok then
			warn("[Lobby] a tick failed; the yard keeps running")
		end
		task.wait(0.25)
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
