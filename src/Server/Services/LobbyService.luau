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
local Trees = require(script.Parent.Parent.Lib.Trees)
local Loop = require(Shared.Util.Loop)
local DataService = require(script.Parent.DataService)
local MowEconomyService = require(script.Parent.EconomyService)
local MowRunService = require(script.Parent.RunService)
local MatchmakingService = require(script.Parent.MatchmakingService)
local LeaderboardService = require(script.Parent.LeaderboardService)

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
	The leaves that fall through the yard.

	Drawn for this rather than borrowed: the first pass used the maple leaf
	from the icon set, which carries the heavy dark outline every icon in that
	set has. At particle size an outline that thick eats the shape, and what
	came down over the lawn was a shower of little orange stars. These are the
	same leaf with no outline and a soft edge, in the three colours the trees
	are, so what falls matches what it fell off.
]]
--- The drawn marquee panel that faces the gate.
local MARQUEE_IMAGE = "rbxassetid://129115569426351"

local LEAF_TEXTURES = {
	"rbxassetid://109856879793416",
	"rbxassetid://72158913177317",
	"rbxassetid://79755062091566",
}
--[[
	A yard, not a field.

	This was two hundred and sixty studs square with the pads sixty-two apart,
	which is a long walk between two things you are trying to compare and a lot
	of empty grass in every direction. Everything a player has to read now sits
	inside about a hundred and sixty, close enough that the four games are one
	glance rather than a tour.
]]
local FLOOR_W, FLOOR_D = 160, 160
--[[
	The yard's own grass, brighter than the palette's lawn.

	The reference's lobby reads at a glance for one big reason: its grass is a
	saturated yellow-green, almost chartreuse, under an amber sky. Ours was the
	palette's lawn green — right for a property mid-game, where cut grass has to
	look like a lawn anyone would want, but in the lobby it sat dull and olive
	under the warm light. A yard nobody is mowing can afford to be the most
	vivid lawn in the game, so this one leans gold.

	Lobby-only on purpose: `Palette.ground.lawn` is the colour of every property
	and the grass renderer's ground, and shifting that would repaint the jobs,
	not the shop window.
]]
local LOBBY_LAWN = Palette.rgb(186, 202, 60)
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
		color = Palette.color(LOBBY_LAWN),
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
		color = Palette.color(LOBBY_LAWN),
		material = Enum.Material.Grass,
		castShadow = false,
		parent = root,
	})

	Build.part({
		name = "Lawn",
		size = Vector3.new(FLOOR_W, 2, FLOOR_D),
		cframe = CFrame.new(CENTRE - Vector3.new(0, 1, 0)),
		color = Palette.color(LOBBY_LAWN),
		material = Enum.Material.Grass,
		parent = root,
	})

	--[[
		A picket fence on all four sides, closed.

		The near side used to stop either side of a thirty-six stud opening,
		on the argument that a yard you cannot see out of is a room. But there
		was never anything in the opening — no gate, no arch, no path through
		it — and nothing beyond it but the surround running out to the fog. A
		hole that size in a picket fence with nothing standing in it does not
		read as a way in; it reads as a missing panel. And you can see out over
		a nine-stud picket fence anyway, which was the whole argument.
	]]
	local halfW, halfD = FLOOR_W * 0.5, FLOOR_D * 0.5
	local fences = Build.folder("Fences", root)
	local corners = {
		{ CENTRE + Vector3.new(-halfW, 0, -halfD), CENTRE + Vector3.new(halfW, 0, -halfD) },
		{ CENTRE + Vector3.new(-halfW, 0, -halfD), CENTRE + Vector3.new(-halfW, 0, halfD) },
		{ CENTRE + Vector3.new(halfW, 0, -halfD), CENTRE + Vector3.new(halfW, 0, halfD) },
		{ CENTRE + Vector3.new(-halfW, 0, halfD), CENTRE + Vector3.new(halfW, 0, halfD) },
	}
	for _, run in corners do
		Build.picketFence(fences, run[1], run[2], 9, false)
	end

	--[[
		No path.

		A hundred and eight studs of flagstone ran up the middle of the room
		to tell you where to walk. The reference has bare grass and four lit
		rectangles, and the lit rectangles are the instruction — a path
		leading to them is a second instruction saying the same thing, laid
		over the thing it is describing.
	]]

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
		--[[
			Built as a sign, not drawn as one.

			This was two slabs and two sticks: a wooden rectangle with a
			slightly smaller plastic rectangle laid on it, on a pair of plain
			posts. Nothing about it was wrong and all of it read as fake,
			because a real yard sign is made of separate pieces of timber and
			you can see the joins — the posts run past the board top and
			bottom, the panel is held between rails, and there is a dark edge
			where the panel sits proud of its backing.

			So there are seven pieces here instead of three, and each is a
			thing a joiner would have cut: two posts, a backing board, the
			white face inset on it, a rail across the top and the bottom, and
			a brace under each post where it meets the ground.
		]]
		local WOOD = Palette.color(Palette.house.roof)
		local RAIL = Palette.color(Palette.fence.rail)

		-- Posts, running well past the board so it hangs between them.
		for _, side in { -1, 1 } do
			Build.part({
				name = "BoardLeg",
				size = Vector3.new(2.2, 21, 2.2),
				cframe = CFrame.new(CENTRE + Vector3.new(x + side * 13.4, 10.5, -9.6)),
				color = WOOD,
				material = Enum.Material.WoodPlanks,
				parent = root,
			})
			-- A short angled brace at the foot, which is what stops a sign
			-- on two posts looking like it was pushed into the lawn.
			Build.part({
				name = "BoardBrace",
				size = Vector3.new(1.4, 5.2, 1.4),
				cframe = CFrame.new(CENTRE + Vector3.new(x + side * 13.4, 2.4, -8.1))
					* CFrame.Angles(math.rad(34), 0, 0),
				color = WOOD,
				material = Enum.Material.WoodPlanks,
				parent = root,
			})
		end

		-- The dark backing the panel sits on, which gives the face its edge.
		Build.part({
			name = `GameBoardFrame{index}`,
			size = Vector3.new(29.2, 11.4, 0.9),
			cframe = facing(CENTRE + Vector3.new(x, 12, -9.9)),
			color = Color3.fromRGB(74, 52, 34),
			material = Enum.Material.WoodPlanks,
			parent = root,
		})

		local board = Build.part({
			name = `GameBoard{index}`,
			size = Vector3.new(27.4, 9.4, 0.55),
			--[[
				High enough to clear the count floating over its own pad.

				Both were at head height and they sat straight on top of each
				other from the near side of the yard: "2/4 Starting in 4"
				printed across "The House EASY" and neither could be read.
			]]
			cframe = facing(CENTRE + Vector3.new(x, 12, -9.35)),
			color = Color3.fromRGB(248, 244, 233),
			material = Enum.Material.SmoothPlastic,
			parent = root,
		})

		-- Rails across the face, top and bottom. The reference's boards have
		-- these and they are most of why they read as carpentry.
		for _, rail in { { 5.1, 1.5 }, { -5.1, 1.5 } } do
			Build.part({
				name = "BoardRail",
				size = Vector3.new(29.6, rail[2], 1.1),
				cframe = facing(CENTRE + Vector3.new(x, 12 + rail[1], -9.9))
					* CFrame.new(0, 0, -0.5),
				color = RAIL,
				material = Enum.Material.WoodPlanks,
				parent = root,
			})
		end

		slots[index] = {
			index = index,
			pad = padPart,
			padLabel = padLabel,
			padCount = padCount,
			boardLabel = (function(): TextLabel
				--[[
					Dark writing on a pale board.

					`surface` paints white, which is right for the teal
					marquee it was written for and wrong on cream: the four
					map boards had white text on an almost-white panel and
					read as blank planks with a smudge on them from any
					distance at all. The reference's are near-black on white,
					which is why you can read them across the yard.
				]]
				local label = surface(board, Enum.NormalId.Front, 0.8)
				label.TextColor3 = Color3.fromRGB(48, 40, 34)
				local stroke = label:FindFirstChildOfClass("UIStroke")
				if stroke then
					stroke:Destroy()
				end
				return label
			end)(),
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
	--[[
		The yard is grass, and that is the whole of it.

		This held a gate you walked under with the game's name on it, a shed
		with a counter and stock, a trailer, two riding mowers, a dog, crates,
		barrels, a sack, a toolbox, eight lamp posts and two flagstone yards.
		All of it in the middle of the room, between a player and the four
		boards they came here to read.

		The reference's lobby has none of it. Its floor is empty grass from
		where you spawn to where the boards stand, and everything with a job —
		the boards, the leaderboards, the shop stand — is pushed out to the
		fence line. That is why it reads at a glance and this did not: not
		because our props were worse, but because there were props at all.

		What was here was carefully made and none of it is missed. A lobby is
		signposting, and signposting works by having nothing else in the way.
	]]

	--[[
		The all-time boards, along the back fence.

		The reference stands two of these at the boundary behind its map
		signs, and they are most of why its yard feels like a place other
		people play in. Ours stand one in each back corner, angled in toward
		the middle of the yard, either side of the status board.

		Not side by side, though that was the first idea. The status board
		sits twenty-six studs in front of the fence line and spans the middle
		forty of it, so a second board next to the first lands directly behind
		it and is hidden from anywhere a player stands. And the left-hand
		corner has thirty-four studs of clear fence, which is one board, not
		two. The corners are the only two places along the back
		where a board this size is both inside the yard and in view.
	]]
	LeaderboardService.build(root, {
		CFrame.lookAt(CENTRE + Vector3.new(-46, 21, -62), CENTRE + Vector3.new(-40, 17, 20)),
		CFrame.lookAt(CENTRE + Vector3.new(46, 21, -62), CENTRE + Vector3.new(40, 17, 20)),
	})

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

		--[[
			The house claims its plot before anything is scattered near it.

			The tree belt is planted after this and knows nothing about the
			street unless it is told; without this, trunks came up through
			three of the six houses, one of them five studs inside the wall.
			Generous on purpose — a canopy overhanging a roof is fine, a
			trunk in the porch is not, and the margin is what separates them.
		]]
		reserve(base, math.max(plot.width, plot.depth) + 9, math.max(plot.width, plot.depth) + 9)

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
		color = Color3.fromRGB(247, 236, 208),
		material = Enum.Material.SmoothPlastic,
		parent = root,
	})

	--[[
		A painted sign, not a coloured slab.

		This was a flat teal rectangle with two lines of white type laid over
		it — the largest single object in the room and the least made thing
		in it. The board carries a drawn panel now: planks with a grain, a
		routed border in wood and gold, the title cut into it with a shadow
		and a highlight, a push mower at one end and fallen leaves at the
		other. The line that changes still prints on top, in the clear band
		the drawing leaves for it.
	]]
	local marquee = Instance.new("SurfaceGui")
	marquee.Name = "Painted"
	marquee.Face = Enum.NormalId.Front
	marquee.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	marquee.PixelsPerStud = 24
	marquee.LightInfluence = 0
	marquee.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	marquee.Parent = statusPost

	local painted = Instance.new("ImageLabel")
	painted.Name = "Panel"
	painted.Size = UDim2.fromScale(1, 1)
	painted.BackgroundTransparency = 1
	painted.Image = MARQUEE_IMAGE
	painted.ScaleType = Enum.ScaleType.Stretch
	painted.ZIndex = 0
	painted.Parent = marquee

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
	--[[
		Both lines live in the painted panel's clear band.

		The title is painted on now, so the outcome line no longer doubles as
		the masthead — it says nothing until there is something to say, and
		the panel carries the name in the meantime. Dark ink, because the
		board is cream: `surface` paints white for the teal it used to be.
	]]
	outcomeLabel = surface(statusPost, Enum.NormalId.Front, 0.22)
	local outcome = outcomeLabel :: TextLabel
	outcome.Position = UDim2.fromScale(0.04, 0.545)
	outcome.TextColor3 = Color3.fromRGB(150, 92, 30)
	outcome.ZIndex = 2
	outcome.Text = ""

	statusLabel = surface(statusPost, Enum.NormalId.Front, 0.20)
	local status = statusLabel :: TextLabel
	status.Position = UDim2.fromScale(0.04, 0.755)
	status.TextColor3 = Color3.fromRGB(70, 56, 40)
	status.ZIndex = 2
	status.Text = "Stand on a pad and pick a property"

	--------------------------------------------------------------------
	-- Dressing
	--------------------------------------------------------------------

	--[[
		A handful of real trees, not a belt of bush-clusters.

		There were a hundred of them, on four rings all the way round the
		fence, each one three tinted `Bush` meshes stacked on a column. From
		the yard that read as exactly what it was — a row of orange blobs at
		regular spacing — and the note on it was blunt: fewer, and real.

		These are two real tree meshes from the Creator Store, picked by
		standing fourteen candidates in a row and photographing them: a sugar
		maple and a big red maple, both of them autumn already.
		That last part is not taste, it is the constraint. A green tree cannot
		be made autumn — every realistic one is a texture or a PBR surface, and
		a colour multiplied into a green texture is mud, which was tried and
		photographed before this was accepted.

		Nor can `Build.mesh` draw them: it hangs a `SpecialMesh` on a part, and
		these are real `MeshPart`s. `Lib.Trees` builds them and hands them out;
		the note on that file says why they are fetched at runtime, and why a
		caller asks for a height rather than a scale. Both matter here — the
		first version of this list carried a multiplier, and the red maple is
		sixty studs tall before it is multiplied by anything.
	]]
	--[[
		A tree built out of bushes, because the tree mesh is a starburst.

		The `Tree` prop is a spiky orange burst — from any distance it reads
		as a firework, not foliage, and it is the single thing that has kept
		this yard from looking like the reference's. Roblox's mesh generator
		refused four times running with an upload error, and asset search only
		reaches this account's own inventory because the experience is not
		group-owned, so there was nothing to swap it for.

		But there already is a dense, round, billowing cluster in the
		catalogue we ship: the `Bush`. Three of them at different sizes,
		overlapping on a trunk and tinted autumn, make exactly the fat cloudy
		canopy the reference's trees have. It is the same trick a set builder
		would use — the shape was on the shelf, under another name.
	]]
	local treeBelt = Build.folder("Trees", root)
	-- Weighted to orange rather than gold: at this size a yellow canopy
	-- behind a cream board reads as more board.
	local CANOPY = {
		Color3.fromRGB(228, 116, 38),
		Color3.fromRGB(212, 92, 40),
		Color3.fromRGB(236, 148, 44),
		Color3.fromRGB(198, 76, 42),
		Color3.fromRGB(224, 130, 40),
	}

	local function plantTree(at: Vector3, height: number, tint: Color3)
		local trunkHeight = height * 0.42
		Build.mesh({
			prop = "Column",
			name = "Trunk",
			size = Vector3.new(height * 0.115, trunkHeight, height * 0.115),
			cframe = CFrame.new(at + Vector3.new(0, trunkHeight * 0.5 - 1, 0)),
			color = Palette.color(Palette.tree.trunk),
			untextured = true,
			canCollide = false,
			castShadow = false,
			parent = treeBelt,
		})
		-- Three clusters, offset and different sizes, so the canopy is one
		-- lumpy mass rather than three balls in a stack.
		type Blob = { at: Vector3, scale: number }
		local blobs: { Blob } = {
			{ at = Vector3.new(0, trunkHeight + height * 0.20, 0), scale = 0.62 },
			{ at = Vector3.new(height * 0.13, trunkHeight + height * 0.10, height * 0.08), scale = 0.48 },
			{ at = Vector3.new(-height * 0.12, trunkHeight + height * 0.12, -height * 0.09), scale = 0.50 },
		}
		for index, blob in blobs do
			local span = height * blob.scale
			Build.mesh({
				prop = "Bush",
				name = "Canopy",
				size = Vector3.new(span, span * 0.86, span),
				cframe = CFrame.new(at + blob.at)
					* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
				color = if index == 1 then tint else tint:Lerp(Color3.new(1, 1, 1), 0.12),
				untextured = true,
				canCollide = false,
				castShadow = false,
				parent = treeBelt,
			})
		end
	end

	--[[
		Where each one stands, in yard coordinates.

		Behind the back row of houses, outside the two on the flanks, and a
		couple over the south fence so the sky has trees in it whichever way
		you face. None of them in a row: the spacing, the species, the size and
		the turn all vary, because a row of identical trees is the thing being
		replaced. Placed by hand and then checked with an overlap query against
		the roofs, because a crown through a roof was the first complaint.
	]]
	local STANDS = {
		{ x = -82, z = -152, species = "RedMaple", height = 26, turn = 20 },
		{ x = -14, z = -160, species = "SugarMaple", height = 29, turn = 200 },
		{ x = 52, z = -150, species = "RedMaple", height = 27, turn = 95 },
		{ x = 124, z = -148, species = "RedMaple", height = 24, turn = 310 },
		{ x = -158, z = -62, species = "SugarMaple", height = 26, turn = 140 },
		{ x = -154, z = 44, species = "SugarMaple", height = 28, turn = 55 },
		{ x = 156, z = -78, species = "SugarMaple", height = 29, turn = 260 },
		{ x = 152, z = 34, species = "SugarMaple", height = 25, turn = 15 },
		{ x = -46, z = 130, species = "RedMaple", height = 25, turn = 170 },
		{ x = 58, z = 124, species = "SugarMaple", height = 26, turn = 330 },
	}

	task.spawn(function()
		Trees.warm()
		for _, stand in STANDS do
			-- Half a stud down, so the roots are in the ground rather than on it.
			local at = CENTRE + Vector3.new(stand.x, -0.5, stand.z)
			local turn = math.rad(stand.turn)
			if not Trees.plant(stand.species, at, stand.height, turn, treeBelt) then
				plantTree(at, stand.height, CANOPY[rng:NextInteger(1, #CANOPY)])
			end
		end
	end)

	--[[
		No hedge.

		There was one the whole way round, tight behind the pickets — first
		green and waist-high, then gold and twelve studs tall to match the
		reference's. It is built from the same `Bush` mesh the old tree belt
		was, and a hundred of them shoulder to shoulder along a fence read as
		exactly that: a row of identical gold trees, lined up, which is the one
		thing this yard is not supposed to have. The fence is the boundary and
		the real trees behind the houses are the trees.
	]]
	--[[
		Leaves on the grass, at the edges, where leaves collect.

		Fourteen seven-stud bushes were scattered across the middle of the
		yard. The reference's floor has no bushes on it at all — what it has
		is autumn litter, drifted up against the fence and thin in the middle,
		which is where leaves actually end up and which leaves the walked
		part of the room clear.

		Laid in a ring inside the fence, thickest at the boundary and fading
		inward, so the yard has a season rather than an obstacle course.
	]]
	local litter = Build.folder("Litter", root)
	local LITTER_TINTS = {
		Color3.fromRGB(226, 132, 46),
		Color3.fromRGB(238, 168, 58),
		Color3.fromRGB(196, 104, 44),
		Color3.fromRGB(180, 138, 66),
	}
	for _ = 1, 340 do
		-- Biased hard to the rim: the walked middle of the yard stays clear.
		local t = math.sqrt(rng:NextNumber(0.55, 1))
		local edge = (halfW - 8) * t
		local along = rng:NextNumber(-edge, edge)
		local x, z
		if rng:NextNumber() < 0.5 then
			x, z = along, edge * (if rng:NextNumber() < 0.5 then -1 else 1)
		else
			x, z = edge * (if rng:NextNumber() < 0.5 then -1 else 1), along
		end
		local at = CENTRE + Vector3.new(x, 0.12, z)
		if clearAt(at, 2) then
			--[[
				Small, warm and untextured.

				At three studs across in the mesh's own colour these came out
				as bright red blobs sitting on open grass — closer to spilled
				paint than to fallen leaves. Autumn litter is small, it is
				orange and tan rather than red, and there is a lot of it: the
				count went up and the size came down, which is the only way a
				scatter reads as litter instead of as objects.

				Bumped a little larger and a little thicker since, because the
				reference's litter is chunky enough to read as single leaves from
				across the yard while ours had thinned into a sprinkle of confetti.
				Still litter-scale; the middle stays bare.
			]]
			local size = rng:NextNumber(1.3, 2.2)
			local leaf = Build.mesh({
				prop = if rng:NextNumber() < 0.5 then "LeafMaple" else "LeafOak",
				name = "Leaf",
				untextured = true,
				color = LITTER_TINTS[rng:NextInteger(1, #LITTER_TINTS)],
				size = Vector3.new(size, 0.2, size * rng:NextNumber(0.85, 1.15)),
				cframe = CFrame.new(at) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
				canCollide = false,
				castShadow = false,
				parent = litter,
			})
			leaf.Anchored = true
		end
	end

	--[[
		And leaves still coming down.

		The reference has them drifting across the whole frame the entire
		time you stand there, and it is most of why its lobby feels like a
		place in a season rather than a room with orange trees around it.
		Kept sparse on purpose. The first pass ran three emitters at nine a
		second with a two-and-a-half stud sprite and the sky filled with
		them — you could not see the boards for the weather. Nine a second at a
		little over a stud is a leaf drifting past every few heartbeats, which is
		what the reference actually has.
	]]
	local sky = Build.part({
		name = "LeafFall",
		size = Vector3.new(halfW * 2, 1, halfD * 2),
		cframe = CFrame.new(CENTRE + Vector3.new(0, 62, 0)),
		color = Color3.fromRGB(255, 255, 255),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = root,
	})
	sky.Transparency = 1
	sky.CastShadow = false

	for _, texture in LEAF_TEXTURES do
	local fall = Instance.new("ParticleEmitter")
	fall.Texture = texture
	fall.Rate = 3
	fall.Lifetime = NumberRange.new(8, 13)
	fall.Speed = NumberRange.new(1, 3)
	fall.SpreadAngle = Vector2.new(28, 28)
	fall.Rotation = NumberRange.new(0, 360)
	fall.RotSpeed = NumberRange.new(-45, 45)
	fall.Size = NumberSequence.new(1.25)
	fall.Acceleration = Vector3.new(2.5, -5.5, 1.5)
	fall.EmissionDirection = Enum.NormalId.Bottom
	fall.LightEmission = 0.25
	fall.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.12, 0),
		NumberSequenceKeypoint.new(0.85, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	fall.Parent = sky
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
						else ""
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
