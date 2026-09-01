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

local function grass(heightMin: number, heightMax: number): Types.FillEntry
	return { debris = Debris.Grass, weight = 1, heightMin = heightMin, heightMax = heightMax }
end

local function mix(debris: number, weight: number, heightMin: number, heightMax: number): Types.FillEntry
	return { debris = debris, weight = weight, heightMin = heightMin, heightMax = heightMax }
end

local ROOF_ELEVATION = 24
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
	gridWidth = 96,
	gridDepth = 96,
	runSeconds = 5400,
	payoutMultiplier = 1,
	baseGround = Palette.ground.lawn,
	style = "house",
	houseRect = { x = 26, z = 34, w = 44, d = 20 },
	shed = { x = 82, z = 54 },
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
			fill = { grass(1, 2), mix(Debris.Leaves, 1, 1, 2) },
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
			fill = { mix(Debris.Leaves, 1, 2, 3), mix(Debris.Sticks, 0.4, 1, 2) },
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
			fill = { grass(2, 3), mix(Debris.Leaves, 0.8, 2, 3), mix(Debris.Weeds, 0.6, 1, 2) },
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
			cost = 1,
			unlock = "cash",
			requires = "front_yard",
			rect = { x = 2, z = 62, w = 20, d = 32 },
			-- The south edge is the garage's back wall; the way in is from the
			-- backyard, so that is where the door stands.
			gateSide = "east",
			density = 0.88,
			fill = { mix(Debris.Leaves, 2, 2, 3), grass(1, 3), mix(Debris.Sticks, 0.5, 1, 2) },
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
			fill = { grass(3, 3), mix(Debris.Hedge, 1.2, 3, 3), mix(Debris.Leaves, 0.8, 2, 3) },
			kind = "maze",
			hazards = { "wasps" },
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
			fill = { grass(3, 3), mix(Debris.Weeds, 1.4, 2, 3), mix(Debris.Leaves, 0.7, 2, 3) },
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
	requiresWorld = "house",
	gridWidth = 144,
	gridDepth = 144,
	--[[
		A tighter clock than The House, and The Gas Station's is tighter still
		against what it asks for.

		Every property used to give ninety minutes. That made the ladder read
		backwards: this world holds more than twice the work of The House, but
		it also pays better, and the gear that buys bought clearing speed faster
		than the extra ground cost — so a perfect run finished The Mansion in
		37:40 against The House's 41:14. The middle rung was the easiest one.

		Paying less was the wrong lever; the payout is already the minimum that
		reaches the gear this world needs. Time is the honest one, and it is the
		thing a player can feel: more ground, less of the afternoon to do it in.
	]]
	runSeconds = 4050,
	-- Enough to reach the gear this world needs, and no more. Paying several
	-- times the first world turned it into the easiest one.
	payoutMultiplier = 1.6,
	baseGround = Palette.ground.lawn,
	style = "house",
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
			fill = { grass(2, 3), mix(Debris.Leaves, 1, 2, 3) },
			kind = "open",
			trees = 5,
			clutter = 14,
		},
		{
			id = "east_wing",
			name = "East Wing",
			cost = 0,
			unlock = "completion",
			requires = "grand_lawn",
			rect = { x = 112, z = 10, w = 28, d = 70 },
			density = 0.94,
			fill = { grass(2, 3), mix(Debris.Hedge, 1, 3, 3), mix(Debris.Leaves, 1, 2, 3) },
			kind = "open",
			trees = 4,
			clutter = 14,
		},
		{
			id = "orangery",
			name = "Orangery",
			cost = 8,
			unlock = "cash",
			requires = "east_wing",
			rect = { x = 4, z = 52, w = 31, d = 44 },
			density = 0.95,
			fill = { grass(2, 3), mix(Debris.Leaves, 2, 3, 3), mix(Debris.Sticks, 0.8, 2, 3) },
			kind = "room",
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
			fill = { grass(2, 3), mix(Debris.Hedge, 2, 3, 3), mix(Debris.Leaves, 0.8, 3, 3) },
			kind = "maze",
			hazards = { "wasps" },
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
	requiresWorld = "mansion",
	gridWidth = 144,
	gridDepth = 144,
	runSeconds = 4650,
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
			fill = { grass(2, 3), mix(Debris.Weeds, 1.2, 2, 3), mix(Debris.Leaves, 1, 2, 3) },
			kind = "open",
			trees = 4,
			clutter = 16,
		},
		{
			id = "wash_bay",
			name = "Wash Bay",
			cost = 15,
			unlock = "cash",
			requires = "forecourt",
			rect = { x = 4, z = 10, w = 27, d = 46 },
			density = 0.96,
			fill = { grass(2, 3), mix(Debris.Weeds, 2, 2, 3), mix(Debris.Leaves, 1, 3, 3) },
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
			fill = { grass(3, 3), mix(Debris.Weeds, 1.2, 2, 3), mix(Debris.Leaves, 1, 3, 3) },
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
			fill = { grass(2, 3), mix(Debris.Sticks, 1.2, 3, 3), mix(Debris.Leaves, 1, 3, 3) },
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

--- Waves needed to finish a section: one per player unless it says otherwise.
function Worlds.wavesFor(section: Types.ZoneDef, playerCount: number): number
	if section.waves then
		return section.waves
	end
	return math.max(playerCount, 1)
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
	if world.style ~= "house" or not hr then
		return {}
	end
	local tile = GameConfig.TILE_SIZE
	local centreX = (hr.x + hr.w * 0.5) * tile + tile * 0.5
	local frontZ = hr.z * tile + tile * 0.5
	local doorX = centreX - hr.w * tile * 0.18
	local garageX = centreX + hr.w * tile * 0.28
	local kerbZ = 34
	return {
		{ x = doorX - 10, z = kerbZ, w = 20, d = frontZ - 8 - kerbZ, stone = 5 },
		{ x = garageX - 17, z = kerbZ, w = 34, d = frontZ - 1 - kerbZ, stone = 6 },
	}
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
