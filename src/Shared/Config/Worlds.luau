--!strict
--[[
	Worlds — the level chain.

	A world is a sequence of sections you clear in order. You arrive with
	nothing, the first section is open, and finishing one opens the gate to the
	next. Clear the last and the grate opens: you walk out and you have beaten
	it. There is a clock on the whole thing.

	This is not a sandbox with things to buy. Cash and gear live for the length
	of a run and no longer, which is why prices here are in single dollars.
]]

local Debris = require(script.Parent.Debris)
local GameConfig = require(script.Parent.GameConfig)
local Palette = require(script.Parent.Palette)
local Types = require(script.Parent.Parent.Types)

local Worlds = {}

--[[
	Grass, and how much of the lawn is grass.

	The weight used to be a flat 1, which put grass on level terms with every
	kind of litter beside it — and since most sections listed two or three of
	those, the lawn in a lawn-mowing game came out under a third grass. Leaves
	were the biggest job in every world. A lawn is mostly lawn; the litter is
	what is lying on it.
]]
local function grass(heightMin: number, heightMax: number, weight: number?): Types.FillEntry
	return {
		debris = Debris.Grass,
		weight = weight or 4,
		heightMin = heightMin,
		heightMax = heightMax,
	}
end

local function mix(debris: number, weight: number, heightMin: number, heightMax: number): Types.FillEntry
	return { debris = debris, weight = weight, heightMin = heightMin, heightMax = heightMax }
end

--[[
	The height the Rooftop's floor sits at.

	This was 24, matching ROOF_HEIGHT, on the assumption that the top of the
	house is at the height the house is called. It is not: a walkable roof is
	a capped slab built at four plus the wall height plus three, and it is
	2.4 thick, so its top face is at 28.2 — four studs above where the
	Rooftop was putting its floor. The whole section was built inside the
	house's own roof, which is why seven hundred and fifty-seven tiles of
	leaves sat on a roof you could stand on and see nothing on.

	Twenty-nine puts the deck's top face just proud of the cap, so the debris
	rests on the surface the player is actually standing on.
]]
--- Just proud of the cap, so the debris rests on what the player stands on.
local ROOF_ELEVATION = GameConfig.HOUSE_ROOF_TOP + 0.8
local BASEMENT_ELEVATION = -18

--------------------------------------------------------------------
-- The House
--------------------------------------------------------------------

--[[
	The first world: a suburban property, front to back and then underneath.

	Front Yard opens the Backyard and the Pool together, those open the Maze,
	the Maze opens the Farm, and the Farm opens the Basement. Clear the Basement
	and the grate at the back of it opens.

	The Garage and the Rooftop sit off that path. Neither is required to finish,
	which is the point of them: somewhere to go that nobody made you go.
]]
local house: Types.WorldDef = {
	id = "house",
	name = "The House",
	tagline = "Somebody let it go for a whole autumn.",
	difficulty = "Easy",
	art = "rbxassetid://82239772513005",
	gridWidth = 96,
	gridDepth = 96,
	--[[
		Two hours, up from ninety minutes.

		Ninety was tuned against a perfect solo run finishing in under half
		an hour. A real party of three, sharing the trailer and the shed and
		all starting on bare hands, ran the clock out with the backyard
		barely finished — and that was with the wave cap already in. The
		first property is the one that teaches the game; it should not be
		the one that beats you on time.
	]]
	runSeconds = 7200,
	payoutMultiplier = 1,
	baseGround = Palette.ground.lawn,
	style = "house",
	houseRect = { x = 26, z = 34, w = 44, d = 20 },
	--[[
		By the street, opposite the trailer, not round the back.

		It stood at (82, 54): the far corner of the property, sixty-two tiles
		from where a player lands, behind the house and out of sight of
		everything. Nobody found it, which matters because the shed is where
		the bag and the first tools are sold — the two purchases the early
		game is built around. Worse, that corner is where the basement is cut
		eighteen studs into the ground, so the back of the shed hung over the
		hole and the game propped it up on an eighteen-stud concrete plinth.
		What you actually saw was a hut floating on a grey block.

		Here it is on the verge between the road and the front lawn, forty
		studs from the spawn on the other side of the drive from the trailer,
		on flat ground, clear of the paving and outside every section — so it
		buries none of the lawn it is standing next to.
	]]
	shed = { x = 58, z = 4 },
	-- Parked to one side of the spawn rather than square in front of it: at
	-- two tiles ahead and the same x, the trailer filled the entire first view
	-- of the property. It is still the first thing you walk past.
	trailer = { x = 41, z = 4 },
	spawn = { x = 48, z = 2 },
	exit = { x = 84, z = 91 },

	sections = {
		{
			id = "front_yard",
			name = "Front Yard",
			cost = 0,
			unlock = "start",
			rect = { x = 24, z = 8, w = 48, d = 24 },
			density = 0.94,
			-- Short grass on purpose: this is the teaching lawn, and the first
			-- gate opening is the hook. The deep stuff starts behind it.
			fill = { grass(1, 2), mix(Debris.Leaves, 0.5, 1, 2) },
			kind = "open",
			trees = 3,
			clutter = 8,
		},
		{
			id = "garage",
			name = "Garage",
			cost = 0,
			unlock = "button",
			buttonIn = "front_yard",
			optional = true,
			rect = { x = 2, z = 46, w = 20, d = 14 },
			density = 0.9,
			--[[
				Grass, like the yards either side of it.

				This was leaves and sticks and nothing else, and the leaf tuft
				is drawn in the autumn red of the trees outside. Indoors, on a
				concrete floor, with no tree in sight, a carpet of them read as
				"red plants" that nobody could name — the one section of the
				property whose job was not obvious from looking at it. The
				same fill as the front yard, so what grew in here is what grew
				out there and the same tool clears both.
			]]
			fill = { grass(1, 2), mix(Debris.Leaves, 0.5, 1, 2) },
			kind = "room",
			clutter = 8,
			-- A found room, not a chore: one pass and it is yours.
			waves = 1,
		},
		{
			id = "rooftop",
			name = "Rooftop",
			cost = 0,
			unlock = "completion",
			requires = "front_yard",
			optional = true,
			rect = { x = 26, z = 34, w = 44, d = 20 },
			density = 0.85,
			fill = { mix(Debris.Leaves, 1, 2, 3), mix(Debris.Sticks, 0.3, 1, 2) },
			kind = "roof",
			elevation = ROOF_ELEVATION,
			clutter = 3,
			waves = 1,
		},
		{
			id = "backyard",
			name = "Backyard",
			cost = 0,
			unlock = "completion",
			requires = "front_yard",
			rect = { x = 24, z = 56, w = 48, d = 22 },
			density = 0.92,
			fill = { grass(2, 3), mix(Debris.Leaves, 0.5, 2, 3), mix(Debris.Weeds, 0.4, 1, 2) },
			kind = "open",
			trees = 3,
			clutter = 10,
		},
		{
			id = "pool_deck",
			name = "Pool Deck",
			-- A cash gate rather than a completion one: a door with a small
			-- price on it. The point is the ritual — walking up with money you
			-- swept off the lawn and buying your way deeper — not a wall.
			--[[
				The one door in each world you have to save up for.

				These were a dollar here, eight at The Mansion and fifteen at The
				Gas Station, against worlds holding roughly $1,826, $6,463 and
				$11,837 of clippings — a tenth of a percent of the money in the
				ground, so the gate always opened the moment you walked up to it
				and the mechanic never did anything.

				Priced now against what is actually earnable by the time you can
				reach them: the front yard grosses $130 before any Fortune level
				or section bonus, so thirty is a real decision beside a $10 mower
				and a $30 rake without ever being a wall. The later two sit near a
				seventh of what is open before them.
			]]
			cost = 18,
			unlock = "cash",
			requires = "front_yard",
			rect = { x = 2, z = 62, w = 20, d = 32 },
			-- The south edge is the garage's back wall; the way in is from the
			-- backyard, so that is where the door stands.
			gateSide = "east",
			density = 0.88,
			fill = { grass(1, 3, 2.5), mix(Debris.Leaves, 1.2, 2, 3), mix(Debris.Sticks, 0.4, 1, 2) },
			kind = "pool",
			hazards = { "sprinkler" },
			clutter = 7,
		},
		{
			id = "hedge_maze",
			name = "Hedge Maze",
			cost = 0,
			unlock = "completion",
			requires = "backyard",
			rect = { x = 24, z = 80, w = 48, d = 14 },
			density = 0.94,
			fill = { grass(3, 3), mix(Debris.Hedge, 1, 3, 3), mix(Debris.Leaves, 0.4, 2, 3) },
			kind = "maze",
			clutter = 4,
		},
		{
			id = "farm",
			name = "The Farm",
			cost = 0,
			unlock = "completion",
			requires = "hedge_maze",
			rect = { x = 2, z = 8, w = 20, d = 36 },
			density = 0.95,
			fill = { grass(3, 3), mix(Debris.Weeds, 1, 2, 3), mix(Debris.Leaves, 0.4, 2, 3) },
			kind = "open",
			trees = 2,
			hazards = { "dog" },
			clutter = 9,
		},
		{
			id = "basement",
			name = "Basement",
			cost = 0,
			unlock = "completion",
			requires = "farm",
			rect = { x = 74, z = 56, w = 20, d = 32 },
			density = 0.96,
			fill = { mix(Debris.Sticks, 1, 2, 3), mix(Debris.Leaves, 1.4, 3, 3) },
			kind = "room",
			elevation = BASEMENT_ELEVATION,
			clutter = 12,
		},
	},
}

--------------------------------------------------------------------
-- Later worlds
--------------------------------------------------------------------

--- Bigger in every direction, and the chain runs one section longer.
local mansion: Types.WorldDef = {
	id = "mansion",
	name = "The Mansion",
	tagline = "Six acres and not one rake in sight.",
	difficulty = "Medium",
	art = "rbxassetid://91582237671513",
	requiresWorld = "house",
	gridWidth = 144,
	gridDepth = 144,
	--[[
		Two and a half hours, up from sixty-seven minutes.

		The reasoning that set it at sixty-seven was about the *ratio* — a
		later world has to give less clock per unit of work than the one
		before it, or it is not the harder world — and that is still the
		invariant the tests hold. What it lost sight of is that a ratio has
		two ends. Sixty-seven minutes against The House's hundred and twenty
		did make the ratio fall, and it did it by handing the player a bigger
		property and *half an hour less of the day* to clear it in, which is
		not a harder world so much as an impossible one.

		This property now asks for about twice The House's work — sixty-six
		thousand units against thirty-three — with a court, a terrace and a
		glasshouse that are all new ground to learn. Two and a half hours is
		more clock than The House gives and still a third less time per unit,
		so the rung is harder in the way the ladder means and not in the way
		that just runs it out.
	]]
	runSeconds = 9000,
	-- Enough to reach the gear this world needs, and no more. Paying several
	-- times the first world turned it into the easiest one.
	payoutMultiplier = 1.6,
	baseGround = Palette.ground.lawn,
	style = "estate",
	houseRect = { x = 42, z = 50, w = 66, d = 30 },
	shed = { x = 124, z = 82 },
	trailer = { x = 67, z = 5 },
	spawn = { x = 74, z = 2 },
	exit = { x = 124, z = 130 },

	sections = {
		{
			id = "grand_lawn",
			name = "Grand Lawn",
			cost = 0,
			unlock = "start",
			rect = { x = 40, z = 10, w = 70, d = 38 },
			density = 0.95,
			fill = { grass(2, 3), mix(Debris.Leaves, 0.5, 2, 3) },
			kind = "open",
			trees = 5,
			clutter = 14,
		},
		--[[
			The tennis court, which is the first hard surface anybody mows.

			Every section in the game until now has been a lawn, a room or a
			roof. This is tarmac inside a twenty-stud mesh fence, with painted
			lines and a net across the middle, and the leaves blown into it
			over a winter are what you are there for. It is off the critical
			path on purpose — like the garage and the rooftop on the first
			property, somewhere to go that nobody made you go.
		]]
		{
			id = "tennis_court",
			name = "Tennis Court",
			cost = 0,
			unlock = "completion",
			requires = "grand_lawn",
			optional = true,
			rect = { x = 6, z = 10, w = 26, d = 34 },
			density = 0.92,
			-- No grass: nothing grows through tarmac. What collects on a court
			-- is what the wind put there.
			fill = { mix(Debris.Leaves, 1, 2, 3), mix(Debris.Sticks, 0.4, 1, 2) },
			kind = "court",
			clutter = 5,
			waves = 1,
		},
		--[[
			A raised stone terrace along the east front, with a balustrade.

			The east wing used to be another `open` — a second lawn, in the
			same green, at the same height as the first. A terrace stands six
			studs above the ground with steps up to it, so it is somewhere you
			climb to and look out from, and the debris on it is at eye level
			from the lawn below.
		]]
		{
			id = "east_terrace",
			name = "East Terrace",
			cost = 0,
			unlock = "completion",
			requires = "grand_lawn",
			rect = { x = 112, z = 12, w = 26, d = 66 },
			density = 0.94,
			-- Mostly what the trees dropped on it. Grass only in the joints
			-- between the flags, because a terrace is a floor.
			fill = { grass(1, 2, 1.5), mix(Debris.Leaves, 1.6, 2, 3), mix(Debris.Sticks, 0.6, 2, 3) },
			kind = "terrace",
			elevation = 6,
			clutter = 12,
		},
		--[[
			The orangery, which is glass rather than stone.

			This was a `room`: the same four opaque walls and flat ceiling the
			garage and the cellars are built from. An orangery is the one
			building on an estate you can see into, and the point of the
			section is that you can stand on the lawn and watch how much of it
			is still full of leaves.

			The one door on this property you save up for, priced against what
			is open before it.
		]]
		{
			id = "orangery",
			name = "Orangery",
			cost = 140,
			unlock = "cash",
			requires = "east_terrace",
			rect = { x = 4, z = 52, w = 31, d = 44 },
			density = 0.95,
			fill = { grass(2, 3, 3), mix(Debris.Leaves, 1, 3, 3), mix(Debris.Sticks, 0.5, 2, 3) },
			kind = "glasshouse",
			clutter = 16,
		},
		{
			id = "long_maze",
			name = "The Long Maze",
			cost = 0,
			unlock = "completion",
			requires = "orangery",
			rect = { x = 40, z = 84, w = 70, d = 30 },
			density = 0.96,
			fill = { grass(2, 3), mix(Debris.Hedge, 1.5, 3, 3), mix(Debris.Leaves, 0.4, 3, 3) },
			kind = "maze",
			clutter = 8,
		},
		{
			id = "cellars",
			name = "The Cellars",
			cost = 0,
			unlock = "completion",
			requires = "long_maze",
			rect = { x = 112, z = 84, w = 28, d = 42 },
			density = 0.97,
			fill = { mix(Debris.Sticks, 1.4, 3, 3), mix(Debris.Leaves, 1, 3, 3) },
			kind = "room",
			elevation = BASEMENT_ELEVATION,
			clutter = 18,
		},
	},
}

--- The longest chain and the most ground. Pays best, but earns it.
local gasStation: Types.WorldDef = {
	id = "gas_station",
	name = "The Gas Station",
	tagline = "Closed for the season. Nobody told the trees.",
	difficulty = "Hard",
	art = "rbxassetid://81920116342553",
	requiresWorld = "mansion",
	gridWidth = 144,
	gridDepth = 144,
	--[[
		Three hours, up from seventy-seven minutes.

		Raised with The Mansion's, and for the same reason. The rule the tests
		hold is that each rung gives less clock per unit of work than the one
		before it, and seventy-seven minutes satisfied it by a mile — a
		hundred and eight thousand units, half again as much as The Mansion,
		in half the time. That is not the hardest property, it is the one
		nobody finishes.

		Three hours keeps the decline honest (a tenth of a second per unit
		against The Mansion's 0.113) while giving the last and largest
		property more of the day than either of the two before it, which is
		what "hard" should mean here: more ground, tighter margins, and still
		an afternoon to do it in.
	]]
	runSeconds = 10800,
	payoutMultiplier = 2.1,
	baseGround = Palette.ground.stone,
	style = "lot",
	shed = { x = 124, z = 20 },
	trailer = { x = 65, z = 5 },
	spawn = { x = 72, z = 2 },
	exit = { x = 124, z = 130 },

	sections = {
		{
			id = "forecourt",
			name = "Forecourt",
			cost = 0,
			unlock = "start",
			rect = { x = 36, z = 10, w = 72, d = 36 },
			density = 0.95,
			fill = { grass(2, 3), mix(Debris.Weeds, 1, 2, 3), mix(Debris.Leaves, 0.4, 2, 3) },
			kind = "open",
			trees = 4,
			clutter = 16,
		},
		{
			id = "wash_bay",
			name = "Wash Bay",
			cost = 75,
			unlock = "cash",
			requires = "forecourt",
			rect = { x = 4, z = 10, w = 27, d = 46 },
			density = 0.96,
			fill = { grass(2, 3, 3), mix(Debris.Weeds, 1.5, 2, 3), mix(Debris.Leaves, 0.5, 3, 3) },
			kind = "room",
			hazards = { "sprinkler" },
			clutter = 14,
		},
		{
			id = "back_lot",
			name = "Back Lot",
			cost = 0,
			unlock = "completion",
			requires = "wash_bay",
			rect = { x = 36, z = 50, w = 72, d = 46 },
			density = 0.96,
			fill = { grass(3, 3), mix(Debris.Weeds, 1, 2, 3), mix(Debris.Leaves, 0.4, 3, 3) },
			kind = "open",
			trees = 6,
			clutter = 18,
		},
		{
			id = "storage_yard",
			name = "Storage Yard",
			cost = 0,
			unlock = "completion",
			requires = "back_lot",
			rect = { x = 112, z = 50, w = 28, d = 66 },
			density = 0.97,
			fill = { grass(2, 3, 3.5), mix(Debris.Sticks, 1, 3, 3), mix(Debris.Leaves, 0.4, 3, 3) },
			kind = "open",
			trees = 3,
			hazards = { "dog" },
			clutter = 20,
		},
		{
			id = "workshop",
			name = "Workshop",
			cost = 0,
			unlock = "completion",
			requires = "storage_yard",
			rect = { x = 36, z = 100, w = 72, d = 34 },
			density = 0.97,
			fill = { mix(Debris.Sticks, 1.6, 3, 3), mix(Debris.Leaves, 1.4, 3, 3) },
			kind = "room",
			elevation = BASEMENT_ELEVATION,
			clutter = 22,
		},
	},
}

local list: { Types.WorldDef } = { house, mansion, gasStation }

Worlds.list = list
Worlds.STARTER_ID = "house"

local byId: { [string]: Types.WorldDef } = {}
for _, world in list do
	byId[world.id] = world
end
Worlds.byId = byId

function Worlds.get(id: string): Types.WorldDef?
	return byId[id]
end

function Worlds.expect(id: string): Types.WorldDef
	local world = byId[id]
	assert(world, `unknown world id {id}`)
	return world
end

--------------------------------------------------------------------
-- Sections
--------------------------------------------------------------------

--- A section of a world by id.
function Worlds.section(world: Types.WorldDef, sectionId: string): Types.ZoneDef?
	for _, section in world.sections do
		if section.id == sectionId then
			return section
		end
	end
	return nil
end

--- The section whose rect contains a tile, or nil for ground between them.
function Worlds.sectionAt(world: Types.WorldDef, tx: number, tz: number): Types.ZoneDef?
	for _, section in world.sections do
		local r = section.rect
		if tx >= r.x and tz >= r.z and tx < r.x + r.w and tz < r.z + r.d then
			return section
		end
	end
	return nil
end

--- Floor height of the section containing a tile, or 0 for open ground.
function Worlds.elevationAt(world: Types.WorldDef, tx: number, tz: number): number
	local section = Worlds.sectionAt(world, tx, tz)
	if not section then
		return 0
	end
	return section.elevation or 0
end

function Worlds.unlockKind(section: Types.ZoneDef): Types.ZoneUnlock
	return section.unlock or "completion"
end

--[[
	The most waves a section asks of any headcount.

	One wave per player kept the work per person constant, which was the
	point — and it was also unwinnable. A party of three on The House owed
	three waves of every section against the same ninety-minute clock, and
	the run ended with the backyard barely finished. Three people do not
	really cut three times as fast: they share the gates, the trailer trips
	and the shed queue, and they spend the first stretch on the same bare
	hands. Two waves keeps a full server from finishing in a fraction of a
	solo run's time without asking a team for more than the clock holds.
]]
Worlds.MAX_WAVES = 2

--- Waves needed to finish a section: one per player, capped at MAX_WAVES,
--- unless the section pins its own count.
function Worlds.wavesFor(section: Types.ZoneDef, playerCount: number): number
	if section.waves then
		return section.waves
	end
	return math.clamp(playerCount, 1, Worlds.MAX_WAVES)
end

--- The section the run begins in.
function Worlds.startSection(world: Types.WorldDef): Types.ZoneDef
	for _, section in world.sections do
		if Worlds.unlockKind(section) == "start" then
			return section
		end
	end
	return world.sections[1]
end

--- The last section on the critical path. Clearing it opens the exit.
function Worlds.finalSection(world: Types.WorldDef): Types.ZoneDef
	local last = world.sections[1]
	for _, section in world.sections do
		if not section.optional then
			last = section
		end
	end
	return last
end

--- Sections that must be cleared to finish the world.
function Worlds.requiredSections(world: Types.WorldDef): { Types.ZoneDef }
	local out = {}
	for _, section in world.sections do
		if not section.optional then
			table.insert(out, section)
		end
	end
	return out
end

--- A slab of flagstones, in world studs, with the stone size it is laid at.
export type Paving = { x: number, z: number, w: number, d: number, stone: number }

--[[
	The flagstone slabs a "house"-style lot lays: a path from the kerb to
	the porch, and a driveway from the kerb to the garage doors.

	This is the one place that geometry lives. The builder that lays the
	stones, the scatter that plants trees and the scatter that drops crates
	all read the same rectangles — because when each of them measured for
	itself, the driveway was measured on The House and The Mansion grew two
	trees through its paving.

	The 0.18 and 0.28 offsets are the ones buildHouse hangs the porch and
	the garage bays at; the kerb line is where the front sections begin.
]]
function Worlds.pavingRects(world: Types.WorldDef): { Paving }
	local hr = world.houseRect
	if not hr then
		return {}
	end
	local tile = GameConfig.TILE_SIZE
	local centreX = (hr.x + hr.w * 0.5) * tile + tile * 0.5
	local frontZ = hr.z * tile + tile * 0.5
	local kerbZ = 34

	--[[
		An estate is approached up a drive, not along a garden path.

		Two rectangles again, because everything that keeps off the hard
		surfaces reads these: one straight run from the gates, and a broad
		square around the fountain that the drive sweeps round. A circle
		described by two rectangles is close enough — what matters is that
		nothing is planted through it.
	]]
	if world.style == "estate" then
		local circleZ = frontZ - 46
		return {
			{ x = centreX - 13, z = kerbZ, w = 26, d = circleZ - 22 - kerbZ, stone = 6 },
			{ x = centreX - 44, z = circleZ - 24, w = 88, d = (frontZ - 6) - (circleZ - 24), stone = 6 },
		}
	end

	if world.style ~= "house" then
		return {}
	end
	local doorX = centreX - hr.w * tile * 0.18
	local garageX = centreX + hr.w * tile * 0.28
	return {
		{ x = doorX - 10, z = kerbZ, w = 20, d = frontZ - 8 - kerbZ, stone = 5 },
		{ x = garageX - 17, z = kerbZ, w = 34, d = frontZ - 1 - kerbZ, stone = 6 },
	}
end

--[[
	The ground the shed stands on, in studs.

	The shed is a solid floor with three walls, so whatever is under it is
	under a building: debris seeded there is invisible and still counts, which
	leaves a section stuck a few percent short with nothing on it to cut. The
	builder and the seeder both read this rectangle so neither can drift from
	the other.
]]
function Worlds.shedRect(world: Types.WorldDef): Paving
	local tile = GameConfig.TILE_SIZE
	local centreX = world.shed.x * tile + tile * 0.5
	local centreZ = world.shed.z * tile + tile * 0.5
	-- The shed is thirty by twenty-six; the extra two studs cover the
	-- collision walls that stand just outside it.
	local w, d = 32, 28
	return { x = centreX - w * 0.5, z = centreZ - d * 0.5, w = w, d = d, stone = 0 }
end

--- Whether a world position (in studs) is under the shed.
function Worlds.underShed(world: Types.WorldDef, wx: number, wz: number): boolean
	local r = Worlds.shedRect(world)
	return wx >= r.x and wx <= r.x + r.w and wz >= r.z and wz <= r.z + r.d
end

--- Whether a world position (in studs) lands on any paving slab.
function Worlds.onPaving(world: Types.WorldDef, wx: number, wz: number, margin: number): boolean
	for _, slab in Worlds.pavingRects(world) do
		if
			wx >= slab.x - margin
			and wx <= slab.x + slab.w + margin
			and wz >= slab.z - margin
			and wz <= slab.z + slab.d + margin
		then
			return true
		end
	end
	return false
end

--- Worlds the player may pick, given the ones they have already beaten.
function Worlds.availableTo(beaten: { [string]: boolean }): { Types.WorldDef }
	local out = {}
	for _, world in list do
		if not world.requiresWorld or beaten[world.requiresWorld] then
			table.insert(out, world)
		end
	end
	return out
end

return Worlds
