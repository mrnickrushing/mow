--!strict
--[[
	WorldService — generates a world and owns its authoritative tile state.

	The tile state is a `buffer`, one byte per tile, and no grass Instance is
	ever created on the server. Everything else — ground, house, shed, trailer,
	fences, section signs — is built once per round from the tables in Worlds,
	so there is no hand-built map to keep in step with the config.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkCodec = require(Shared.ChunkCodec)
local Cutting = require(Shared.Cutting)
local GameConfig = require(Shared.Config.GameConfig)
local Grid = require(Shared.Grid)
local Palette = require(Shared.Config.Palette)
local Upgrades = require(Shared.Config.Upgrades)
local Worlds = require(Shared.Config.Worlds)
local Types = require(Shared.Types)
local Build = require(script.Parent.Parent.Lib.Build)
local Trees = require(script.Parent.Parent.Lib.Trees)
local ReplicationService = require(script.Parent.ReplicationService)
local Structures = require(script.Parent.Parent.Lib.Structures)

local WorldService = {}

local TILE = GameConfig.TILE_SIZE
--- Wall height of a house, which is what the rooftop section sits on.
local ROOF_HEIGHT = GameConfig.HOUSE_ROOF_HEIGHT

export type SectionState = {
	def: Types.ZoneDef,
	--- Tile indices belonging to this section that started with debris.
	totalUnits: number,
	remainingUnits: number,
	--- World-space centre of the section, for signs and camera hints.
	centre: Vector3,
}

WorldService.grid = nil :: Grid.Grid?
WorldService.tiles = nil :: buffer?
WorldService.world = nil :: Types.WorldDef?
--- Zone id per tile index, or "" for ground that belongs to no section.
WorldService.tileSection = nil :: { string }?
--[[
	Tiles the world was built on top of, by tile index.

	`clearBuriedTiles` runs once, after the structures are up, and empties the
	tiles the porch deck and the steps and the walls ended up standing on. A
	wave refill re-seeds a section's whole rect, so without a record of them it
	sowed every one of those tiles again — see `refillSection`.
]]
--[[
	The number this property is built from, for the services that add to it.

	Trees, hazards and collectibles are planted after the world by their own
	services, from their own generators — so seeding this one alone left the
	property still different on every server. Trees matter most of the three:
	`clearTileAt` takes the tile a trunk stands on out of the section's
	demand, so where the trees land changes how much work the property is.
]]
WorldService.seed = 0

WorldService.buriedTiles = {} :: { [number]: boolean }
WorldService.sections = {} :: { [string]: SectionState }
WorldService.totalUnits = 0
--- Where a player should be standing in the world now loaded. See
--- `WorldService.spawnPoint`.
WorldService.spawnAt = nil :: CFrame?
WorldService.remainingUnits = 0

local builtSignal = Instance.new("BindableEvent")
--[[
	Fires once the property's fixed geometry is standing, before the passes
	that ask what is standing where.

	Trees used to be planted on `Loaded`, which fires after `clearBuriedTiles`
	— so a trunk landed on a sown tile the pass had already declared clear,
	and the tuft was drawn up through the bark. Measured after the overlap
	fix, that was every one of the 26 tiles still hidden across the three
	worlds. Anything that adds cover to the ground belongs here.
]]
WorldService.Built = builtSignal.Event

local loadedSignal = Instance.new("BindableEvent")
--- Fires with the world definition once a new world is ready.
WorldService.Loaded = loadedSignal.Event

local exitSignal = Instance.new("BindableEvent")
--- Fires with the player who used the way out. The world builds the grate and
--- knows when it is touched; deciding what leaving *means* belongs to the run,
--- so it listens rather than the world calling into it.
WorldService.ExitReached = exitSignal.Event

local gateSignal = Instance.new("BindableEvent")
--- Fires with (player, sectionId) when someone tries to pay a cash gate. The
--- world owns the door and the prompt; whether the money is there and what
--- opening means belongs to the run, so it listens.
WorldService.GateTried = gateSignal.Event

local stationSignal = Instance.new("BindableEvent")
--- Fires with (player, upgradeId) when someone uses an upgrade station.
WorldService.StationTried = stationSignal.Event

--- The section whose switch raises the garage door.
local GARAGE_SECTION = "garage"
--- Courses in one bay, so the tween can stagger by height rather than by index.
local GARAGE_COURSES_PER_BAY = 6
type GarageSlat = { part: Part, shut: CFrame, rolled: CFrame }
local garageSlats: { GarageSlat } = {}
local garageOpen = false

local switchSignal = Instance.new("BindableEvent")
--- Fires with (player, sectionId) when someone flips a hidden switch. The
--- world hides the switch; whether flipping it opens anything is the run's.
WorldService.SwitchTried = switchSignal.Event

--- Sections whose gate is open for this run. Open-ness is a property of the
--- run, but it is asked about on the hot cutting path once per tile, so it
--- lives beside the tiles rather than a service call away.
local openSections: { [string]: boolean } = {}

local container: Folder? = nil
--[[
	Reseeded per property at load, not left to chance.

	This was `Random.new()` with no seed, and it draws the tile seeding, the
	clutter scatter, the maze carve and everything else a property is built
	from — so the same property was a different property on every server.
	Measured by building the Cemetery three times in a row from identical
	code: 132,443 units, then 133,313, then 133,596. Nearly a percent of
	spread in how much work the ladder's hardest rung asks for.

	That matters because there is a time-record board. Two players racing The
	House are racing over different amounts of grass, and the one whose server
	rolled lighter wins. It is also what the graves builder already says it
	wants when it seeds its own generator so "a churchyard built twice is the
	same churchyard".

	So the seed comes from the property itself: same everywhere, different
	between properties, and stable across restarts.
]]
local rng = Random.new()

local function seedOf(world: Types.WorldDef): number
	local seed = world.gridWidth * 7919 + world.gridDepth * 104729
	for index = 1, #world.id do
		seed = (seed * 31 + string.byte(world.id, index)) % 2147483647
	end
	return seed
end

--------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------

local function toColor(rgb: Types.Color3Like): Color3
	return Color3.new(rgb[1], rgb[2], rgb[3])
end

--- Floor height at a tile, which is the rooftop's or basement's if it has one.
function WorldService.elevationAt(tx: number, tz: number): number
	local world = WorldService.world
	if not world then
		return 0
	end
	return Worlds.elevationAt(world, tx, tz)
end

--- World position of a tile centre, on that tile's own floor.
function WorldService.tileCentre(index: number): Vector3
	local grid = assert(WorldService.grid, "world not loaded")
	local tx, tz = Grid.fromIndex(grid, index)
	local x, z = Grid.tileToWorld(grid, tx, tz)
	return Vector3.new(x, GameConfig.GROUND_Y + WorldService.elevationAt(tx, tz), z)
end

--- World position of a tile-space point, on that tile's own floor.
function WorldService.tilePointToWorld(tx: number, tz: number): Vector3
	local grid = assert(WorldService.grid, "world not loaded")
	local x, z = Grid.tileToWorld(grid, tx, tz)
	return Vector3.new(x, GameConfig.GROUND_Y + WorldService.elevationAt(tx, tz), z)
end

--- Ground-plane position, ignoring any section elevation. Used when placing the
--- structures that create those elevations in the first place.
function WorldService.tilePointFlat(tx: number, tz: number): Vector3
	local grid = assert(WorldService.grid, "world not loaded")
	local x, z = Grid.tileToWorld(grid, tx, tz)
	return Vector3.new(x, GameConfig.GROUND_Y, z)
end

function WorldService.sectionIdAt(index: number): string
	local tileSection = WorldService.tileSection
	if not tileSection then
		return ""
	end
	return tileSection[index] or ""
end

--------------------------------------------------------------------
-- Generation
--------------------------------------------------------------------

--- Picks a debris entry from a section's weighted fill list.
local function pickFill(section: Types.ZoneDef): Types.FillEntry?
	local total = 0
	for _, entry in section.fill do
		total += entry.weight
	end
	if total <= 0 then
		return nil
	end

	local roll = rng:NextNumber() * total
	for _, entry in section.fill do
		roll -= entry.weight
		if roll <= 0 then
			return entry
		end
	end
	return section.fill[#section.fill]
end

local function seedTiles(world: Types.WorldDef, grid: Grid.Grid, tiles: buffer)
	local tileSection = table.create(Grid.tileCount(grid), "")
	WorldService.sections = {}
	WorldService.totalUnits = 0

	for _, section in world.sections do
		local r = section.rect
		local state: SectionState = {
			def = section,
			totalUnits = 0,
			remainingUnits = 0,
			centre = WorldService.tilePointToWorld(r.x + r.w * 0.5, r.z + r.d * 0.5),
		}

		-- The water is part of the section but not part of the lawn: debris
		-- sown here would float on the surface and have to be mown off it.
		local water = if (section.kind or "open") == "pool" then Structures.poolRect(section) else nil

		for tz = r.z, math.min(r.z + r.d - 1, grid.depth - 1) do
			for tx = r.x, math.min(r.x + r.w - 1, grid.width - 1) do
				local index = Grid.toIndex(grid, tx, tz)
				tileSection[index] = section.id

				-- Nothing is sown under the shed: it is a building with a floor,
				-- so anything seeded there is invisible and still counts, which
				-- leaves a section stuck short with nothing on it to cut.
				local wx, wz = Grid.tileToWorld(grid, tx, tz)
				local underShed = Worlds.underShed(world, wx, wz)
				local onWater = water ~= nil
					and tx >= water.x
					and tx < water.x + water.w
					and tz >= water.z
					and tz < water.z + water.d

				if not onWater and not underShed and rng:NextNumber() <= section.density then
					local entry = pickFill(section)
					if entry then
						local height = rng:NextInteger(entry.heightMin, entry.heightMax)
						height = math.clamp(height, 0, GameConfig.MAX_HEIGHT)
						local byte = ChunkCodec.pack(entry.debris, height, false)
						buffer.writeu8(tiles, index - 1, byte)
						state.totalUnits += Cutting.unitsOnTile(byte)
					end
				end
			end
		end

		state.remainingUnits = state.totalUnits
		WorldService.sections[section.id] = state
		WorldService.totalUnits += state.totalUnits
	end

	WorldService.tileSection = tileSection
	WorldService.remainingUnits = WorldService.totalUnits
end

local function buildGround(world: Types.WorldDef, grid: Grid.Grid, parent: Folder)
	local width = grid.width * TILE
	local depth = grid.depth * TILE

	-- Anything below ground needs the lawn opened over it, or the room is buried
	-- and the player walks across its ceiling without ever finding the way in.
	local holes: { Types.Rect } = {}
	for _, section in world.sections do
		if (section.elevation or 0) < 0 then
			table.insert(holes, section.rect)
		end
		-- A pool needs the same treatment as a cellar. Without it the lawn
		-- slab ran straight over the top of the water: the basin and its
		-- surface sat entirely below y=0, so the pool was invisible, and the
		-- only clue it existed at all was the deck around a piece of grass.
		if (section.kind or "open") == "pool" then
			table.insert(holes, Structures.poolRect(section))
		end
	end

	--[[
		The lawn under everything, as a plain surface rather than a model.

		This was a turf panel — a seven stud square whose texture is a weave of
		light and dark blades — stretched across the whole lot. A texture does
		not repeat when a mesh is scaled, it stretches, so that seven stud weave
		came out as light and dark bands forty studs wide running the length of
		the property: from the porch the front lawn read as a ploughed field.

		Roblox's own grass material is the right tool for a surface this size.
		It is fine noise at any scale, it has no pattern to magnify, and it
		leaves the clumps the renderer scatters on top to do the describing.
	]]
	--[[
		Not every lot is a lawn.

		The Gas Station is a stone forecourt — its own `baseGround` is paving
		tan — and it was being surfaced with Roblox's grass material like the
		other two, which put fine blade-shaped noise over the whole yard. The
		apron around it stays grass whichever world it is, because the land
		beyond the property line is fields in all three.
	]]
	local groundMaterial = if world.style == "lot" then Enum.Material.Concrete else Enum.Material.Grass

	local slabs = Structures.subtractAll({ x = 0, z = 0, w = grid.width, d = grid.depth }, holes)
	for index, slab in slabs do
		Build.part({
			name = `Ground{index}`,
			size = Vector3.new(slab.w * TILE, 4, slab.d * TILE),
			cframe = CFrame.new(
				(slab.x + slab.w * 0.5) * TILE,
				GameConfig.GROUND_Y - 2,
				(slab.z + slab.d * 0.5) * TILE
			),
			color = toColor(world.baseGround),
			material = groundMaterial,
			parent = parent,
		})
	end

	-- A ring of apron around the lot so it does not float in the void. Built as
	-- four strips rather than one slab, so it never re-covers a sunken room.
	local apron = 130
	local strips: { { centre: Vector2, size: Vector2 } } = {
		{ centre = Vector2.new(width * 0.5, -apron * 0.5), size = Vector2.new(width + apron * 2, apron) },
		{ centre = Vector2.new(width * 0.5, depth + apron * 0.5), size = Vector2.new(width + apron * 2, apron) },
		{ centre = Vector2.new(-apron * 0.5, depth * 0.5), size = Vector2.new(apron, depth) },
		{ centre = Vector2.new(width + apron * 0.5, depth * 0.5), size = Vector2.new(apron, depth) },
	}
	for _, strip in strips do
		Build.part({
			name = "Surrounds",
			size = Vector3.new(strip.size.X, 3, strip.size.Y),
			cframe = CFrame.new(strip.centre.X, GameConfig.GROUND_Y - 2.2, strip.centre.Y),
			color = Palette.color(Palette.ground.lawnDark),
			material = Enum.Material.Grass,
			castShadow = false,
			parent = parent,
		})
	end

	--[[
		A belt of trees around the outside of the lot.

		Every property was an open field with a visible edge: the lawn simply
		stopped and the haze took over, and from the spawn you could see the
		end of the world over the top of the house. These stand on the apron,
		outside the grid entirely, so they are scenery and nothing else — no
		prompt, nothing to chop, nothing counted toward clearing. What they do
		is close the horizon, which is most of why a cartoon suburb reads as a
		place rather than as a plane with a building on it.

		They are real trees now. This was a hundred and twenty-three copies of
		the `Tree` prop, which the catalogue itself describes as a starburst
		that reads as a firework, and the note on the lobby's version of the
		same belt was "fake looking trees lined up all the way across the
		fence". The three species in `ServerStorage.Trees` — the ones the lobby
		uses — are planted instead, at wider spacing, weighted toward the two
		smaller maples, each at its own size and turn. The prop stays as the
		fallback for a missing template so a property is never bare.

		Kept clear of the road along the south edge and of the spawn, so the
		first thing anybody sees is still the property.
	]]
	local belt = Build.folder("TreeBelt", parent)
	local beltRng = Random.new(grid.width * 7919 + grid.depth)
	local spawnAt = WorldService.tilePointFlat(world.spawn.x, world.spawn.z)
	-- Two sugars to one red.
	local BELT_SPECIES = { "SugarMaple" }

	--[[
		Where a trunk already stands.

		The belt is four rows of two, each laid out without reference to the
		others, and at the corners the north row's far end and the west row's
		far end are describing the same patch of ground. Two of them came out
		close enough to share a trunk — one tree with two crowns, from any
		angle a mistake.

		Canopies are supposed to overlap; that is what makes it a belt rather
		than an avenue. Trunks are not, so the test is on the trunk and a
		tree with no room simply is not planted.
	]]
	-- Idempotent, and boot has almost certainly done it already; this is the
	-- first world on a fresh run server paying for it once.
	Trees.warm()

	local planted: { Vector2 } = {}
	local TRUNK_APART = 24

	local function plant(x: number, z: number)
		if (Vector2.new(x, z) - Vector2.new(spawnAt.X, spawnAt.Z)).Magnitude < 80 then
			return
		end
		local at = Vector2.new(x, z)
		for _, other in planted do
			if (at - other).Magnitude < TRUNK_APART then
				return
			end
		end
		table.insert(planted, at)
		local spin = beltRng:NextNumber(0, math.pi * 2)
		local name = BELT_SPECIES[beltRng:NextInteger(1, #BELT_SPECIES)]
		--[[
			A height, not a multiplier.

			The two meshes are sixty and twenty-three studs tall out of the
			box, so one multiplier across both is one sensible tree and one
			that fills the sky. These are background, so a touch taller than
			the ones standing in the yard.
		]]
		local want = beltRng:NextNumber(28, 40)
		-- The apron's top is a little below ground level; a stud down puts the
		-- roots in it rather than on it.
		--[[
			The belt is the one build loop that never came up for air.

			`Build.part` and `Build.mesh` breathe on the caller's behalf, so
			everything else in a world load yields on its own; a planted tree
			is a model clone that goes nowhere near either of them, and four
			sides of two rows is around a hundred of them back to back. It
			timed out mid-belt on a slow load here, and a build that throws
			half way through leaves the property with no road, no street and
			no shed — the same silent hole the boot script had.
		]]
		Build.breathe()
		local real = Trees.plant(name, Vector3.new(x, GameConfig.GROUND_Y - 1, z), want, spin, belt)
		if real then
			real.Name = "Scenery"
			return
		end
		local turn = CFrame.Angles(0, spin, 0)
		local height = beltRng:NextNumber(24, 38)
		Build.mesh({
			prop = "Tree",
			name = "Scenery",
			-- The source mesh's own proportions, so a taller tree is not a
			-- fatter one.
			size = Vector3.new(height * 0.666, height, height * 0.703),
			collisionSize = Vector3.new(3.4, height, 3.4),
			cframe = CFrame.new(x, GameConfig.GROUND_Y + height * 0.5 - 1, z) * turn,
			castShadow = false,
			parent = belt,
		})
	end

	-- Two staggered rows a side. The south rows start beyond the road.
	-- Wider than the firework belt was: a real crown is twenty to fifty
	-- studs across, and at thirty-four they merged into one long hedge.
	local SPACING = 56
	for _, side in { "north", "south", "west", "east" } do
		local alongX = side == "north" or side == "south"
		local length = if alongX then width else depth
		local steps = math.max(math.floor((length + 160) / SPACING), 2)
		-- Annotated, because an `if` between two array literals infers as a
		-- union that the generic `for` will not accept as iterable.
		-- The fenced sides start further out than the firework belt did. A real
		-- tree's limbs reach twenty studs from its trunk at full size, and at
		-- twenty out the inner row's trunks stood thirteen studs from the
		-- pickets with their limbs across the fence. The south has no fence,
		-- only the road, and keeps its rows.
		local rows: { number } = if side == "south" then { 42, 74 } else { 30, 64 }
		for _, out in rows do
			for step = 0, steps do
				local at = -80 + (length + 160) * (step / steps) + beltRng:NextNumber(-9, 9)
				local away = out + beltRng:NextNumber(-7, 7)
				if side == "north" then
					plant(at, depth + away)
				elseif side == "south" then
					plant(at, -away)
				elseif side == "west" then
					plant(-away, at)
				else
					plant(width + away, at)
				end
			end
		end
	end

	--[[
		The street: a kerb, a pavement, a carriageway and a centre line.

		This was one flat strip of asphalt twenty-six studs wide, laid a
		twentieth of a stud above the lawn — so the boundary between the
		property and the road was a colour change on a single continuous
		plane, and the road had no edge, no height and nothing on it. It is
		the first thing anybody sees, because it is where they arrive and what
		they are standing on when the property is first put in front of them,
		and it read as a grey rectangle painted onto the grass.

		Four parts instead of one, at the heights these things actually sit
		at: the pavement a step up from the road, a kerb standing proud of it,
		the carriageway sunk between them, and a dashed line down the middle
		so the street has a direction. All of it still plain materials for the
		reason the lawn is plain — a concrete panel's texture stretched over
		six hundred studs is a smear, not concrete.
	]]
	local roadLength = width + 240
	local roadX = width * 0.5
	local ground = GameConfig.GROUND_Y
	local street = Build.folder("Street", parent)

	--- The pavement between the lawn and the kerb, a step above the road.
	Build.part({
		name = "Pavement",
		size = Vector3.new(roadLength, 0.9, 12),
		cframe = CFrame.new(roadX, ground + 0.35, -4),
		color = Palette.color(Palette.ground.path),
		material = Enum.Material.Concrete,
		castShadow = false,
		parent = street,
	})
	--- The kerb, which is the only reason a road has an edge at all.
	Build.part({
		name = "Kerb",
		size = Vector3.new(roadLength, 1.4, 1.6),
		cframe = CFrame.new(roadX, ground + 0.3, -9.2),
		color = Palette.color(Palette.ground.stone),
		material = Enum.Material.Concrete,
		castShadow = false,
		parent = street,
	})
	Build.part({
		name = "Road",
		size = Vector3.new(roadLength, 0.6, 26),
		cframe = CFrame.new(roadX, ground - 0.1, -23),
		color = Palette.color(Palette.ground.road),
		material = Enum.Material.Asphalt,
		castShadow = false,
		parent = street,
	})
	--- The far kerb, so the street has two sides rather than running off into
	--- the neighbours' grass.
	Build.part({
		name = "Kerb",
		size = Vector3.new(roadLength, 1.4, 1.6),
		cframe = CFrame.new(roadX, ground + 0.3, -36.8),
		color = Palette.color(Palette.ground.stone),
		material = Enum.Material.Concrete,
		castShadow = false,
		parent = street,
	})

	--- A dashed centre line. Broken rather than solid, because a solid line
	--- painted the length of the world reads as a stripe and not as a road.
	local DASH, GAP = 14, 12
	local dashes = math.floor(roadLength / (DASH + GAP))
	for index = 0, dashes - 1 do
		Build.part({
			name = "RoadLine",
			size = Vector3.new(DASH, 0.2, 0.9),
			cframe = CFrame.new(
				roadX - roadLength * 0.5 + (DASH + GAP) * (index + 0.5),
				ground + 0.15,
				-23
			),
			color = Palette.color(Palette.sky.cloud),
			material = Enum.Material.SmoothPlastic,
			castShadow = false,
			canCollide = false,
			parent = street,
		})
	end

	--[[
		A dropped kerb where the drive meets the street.

		Every property has a hard surface running down to the road; without a
		break in the kerb it ran into a six inch wall, which is the one detail
		that gives away a street built out of rectangles.
	]]
	for _, slab in Worlds.pavingRects(world) do
		if slab.z <= 36 then
			Build.part({
				name = "DroppedKerb",
				size = Vector3.new(slab.w + 4, 1.4, 1.8),
				cframe = CFrame.new(slab.x + slab.w * 0.5, ground - 0.25, -9.2),
				color = Palette.color(Palette.ground.stone),
				material = Enum.Material.Concrete,
				castShadow = false,
				parent = street,
			})
			Build.part({
				name = "Apron",
				size = Vector3.new(slab.w + 4, 0.9, 14),
				cframe = CFrame.new(slab.x + slab.w * 0.5, ground + 0.3, -3),
				color = Palette.color(Palette.ground.path),
				material = Enum.Material.Concrete,
				castShadow = false,
				parent = street,
			})
		end
	end
end

--[[
	The house: cream lap siding, teal roof trim, a brick foundation, a covered
	porch with square columns and a rail, and an attached sectional garage door.

	Built from the reference's silhouette rather than as a box, because the porch
	and the teal trim are what make it read as that kind of suburban house at a
	glance.
]]
--[[
	Whether somebody stands on this house's roof.

	A world can put a section on top of its own house — The House's Rooftop is
	one of its zones — and a roof you clear has to be flat and walkable. Every
	other house gets a pitched one.
]]
local function walkableRoof(world: Types.WorldDef, rect: Types.Rect): boolean
	for _, section in world.sections do
		if (section.kind or "open") ~= "roof" then
			continue
		end
		local r = section.rect
		if r.x < rect.x + rect.w and rect.x < r.x + r.w and r.z < rect.z + rect.d and rect.z < r.z + r.d then
			return true
		end
	end
	return false
end

--[[
	The Mansion, which is a stone house and not a big wooden one.

	`buildHouse` raises the property every world used to be built from: a
	timber frame in cream lap siding, a teal band under the eaves, a brown
	shingle roof, a wooden porch on two square posts and a row of garage
	doors. Handed The Mansion's rect it made exactly that, two hundred and
	sixty-four studs wide — which is why the second property arrived looking
	like the first one at twice the size.

	An estate is not a larger house, it is a different building, so this is a
	different builder rather than a switch inside that one:

	  ashlar walls in pale limestone, with dressed quoins at every corner
	  a projecting wing at each end, so the frontage has a shape to it
	  a portico of six round columns carrying a pediment, over the full
	    width of the entrance rather than a corner of it
	  a mansard in grey slate, with dormers standing out of the lower pitch
	  a stone balustrade along the roofline
	  four chimney stacks, placed in pairs, because a symmetrical house has
	    symmetrical stacks

	Nothing here is shared with the suburban builder except the window model,
	and that is set in a stone surround.
]]
--[[
	A window, with something behind the glass.

	The `Window` prop is a frame and its glazing bars, and its panes are
	empty: whatever stands behind it shows straight through. On the manor
	that is the ashlar the window is hung on — reported as "you can see the
	wall behind it" — so every opening on a hundred-and-eighty-stud frontage
	read as a frame drawn on the stone rather than as a hole cut in it. The
	suburban house, the French doors, the fanlight and both rows of dormers
	had it too, because all seven of them are the same model.

	So a pane goes in. Centred in the frame's own depth rather than behind
	it, which is where the glass in a sash actually sits and which also
	means it is right whichever way round a caller has turned the model —
	the bars end up half in front of it and half behind, as they should.

	Darker than the wall, because a window seen from outside in daylight
	always is, whatever colour the glass is; and reflective, because
	catching the sky is the one thing that says glass from across a lawn.
]]
local function glazed(options: {
	name: string,
	size: Vector3,
	cframe: CFrame,
	glass: Types.Color3Like,
	parent: Instance,
})
	Build.mesh({
		prop = "Window",
		name = options.name,
		size = options.size,
		collisionSize = Vector3.new(options.size.X, options.size.Y, 0.6),
		cframe = options.cframe,
		canCollide = false,
		parent = options.parent,
	})
	local tint = Palette.color(options.glass)
	local pane = Build.part({
		name = "WindowPane",
		size = Vector3.new(options.size.X - 0.9, options.size.Y - 0.9, 0.32),
		cframe = options.cframe,
		color = Color3.new(tint.R * 0.26, tint.G * 0.3, tint.B * 0.34),
		material = Enum.Material.SmoothPlastic,
		castShadow = false,
		canCollide = false,
		parent = options.parent,
	})
	--[[
		Most of what you see in it is the sky.

		A pane only a little darker than the wall, at a third of a
		reflectance, came out as a flat panel of pale blue paint: the wall no
		longer showed through it, which was the fault, but nothing showed in
		it either. Dark glass reflecting half of what is in front of it is a
		window — near black where it faces a hedge, the colour of the
		afternoon where it faces the sky, and different on two elevations of
		the same building, which is what glass does and paint does not.
	]]
	pane.Reflectance = 0.5
end

local function buildManor(world: Types.WorldDef, parent: Folder)
	local rect = world.houseRect
	if not rect then
		return
	end

	local manor = Build.folder("House", parent)
	local centre = WorldService.tilePointFlat(rect.x + rect.w * 0.5, rect.z + rect.d * 0.5)
	local width, depth = rect.w * TILE, rect.d * TILE
	local halfWidth, halfDepth = width * 0.5, depth * 0.5
	local frontZ = centre.Z - halfDepth

	local PLINTH = 3.0
	local WALL = 30
	local wallTop = PLINTH + WALL

	local stone = Palette.color(Palette.estate.stone)
	local stoneShade = Palette.color(Palette.estate.stoneShade)
	local quoin = Palette.color(Palette.estate.quoin)
	local roofColour = Palette.color(Palette.estate.roof)
	local lead = Palette.color(Palette.estate.lead)

	--- The step of dressed stone the whole building stands on.
	Build.part({
		name = "Plinth",
		size = Vector3.new(width + 4, PLINTH, depth + 4),
		cframe = CFrame.new(centre + Vector3.new(0, PLINTH * 0.5, 0)),
		color = stoneShade,
		material = Enum.Material.Sandstone,
		parent = manor,
	})

	--[[
		The block itself, one mass of ashlar.

		A plain part rather than courses of blocks, for the reason the first
		house's walls are plain: a stone model stretched two hundred and sixty
		studs is one smeared stone. Roblox's sandstone tiles, so it is masonry
		at any length of wall.
	]]
	Build.part({
		name = "Ashlar",
		size = Vector3.new(width, WALL, depth),
		cframe = CFrame.new(centre + Vector3.new(0, PLINTH + WALL * 0.5, 0)),
		color = stone,
		material = Enum.Material.Sandstone,
		parent = manor,
	})

	--[[
		A wing at each end, standing a little proud of the middle.

		Without them the frontage is one unbroken run of wall as long as the
		lawn is wide, which reads as a wall rather than as a house. Two
		projecting ends and a recessed centre is the shape every building like
		this has, and it is what gives the portico something to stand in front
		of.
	]]
	local wingWidth = width * 0.22
	local wingOut = 12
	--- The projecting centre of the garden front, at the back.
	local bayWidth = width * 0.26
	for _, side in { -1, 1 } do
		local x = centre.X + side * (halfWidth - wingWidth * 0.5)
		Build.part({
			name = "Wing",
			size = Vector3.new(wingWidth, WALL, depth + wingOut),
			cframe = CFrame.new(x, PLINTH + WALL * 0.5, centre.Z - wingOut * 0.5),
			color = stone,
			material = Enum.Material.Sandstone,
			parent = manor,
		})
		Build.part({
			name = "WingPlinth",
			size = Vector3.new(wingWidth + 4, PLINTH, depth + wingOut + 4),
			cframe = CFrame.new(x, PLINTH * 0.5, centre.Z - wingOut * 0.5),
			color = stoneShade,
			material = Enum.Material.Sandstone,
			parent = manor,
		})
	end

	--[[
		Quoins: the dressed stones that run up every outside corner.

		They are the single detail that says "cut stone" rather than "grey
		box" from across a lawn, and they cost eight thin columns.
	]]
	local quoinCorners = {
		Vector3.new(-halfWidth, 0, -halfDepth - wingOut),
		Vector3.new(halfWidth, 0, -halfDepth - wingOut),
		Vector3.new(-halfWidth, 0, halfDepth),
		Vector3.new(halfWidth, 0, halfDepth),
		Vector3.new(-halfWidth + wingWidth, 0, -halfDepth - wingOut),
		Vector3.new(halfWidth - wingWidth, 0, -halfDepth - wingOut),
	}
	for _, corner in quoinCorners do
		Build.part({
			name = "Quoin",
			size = Vector3.new(4.5, WALL, 4.5),
			cframe = CFrame.new(centre + corner + Vector3.new(0, PLINTH + WALL * 0.5, 0)),
			color = quoin,
			material = Enum.Material.Sandstone,
			parent = manor,
		})
	end

	--[[
		A string course between the storeys.

		Thirty studs of unbroken wall two hundred and sixty long is a slab,
		whatever it is painted: there is nothing in it for the light to catch,
		so it flattens out at any distance and the windows read as holes
		punched in a screen. A band at the floor line of the first storey is
		the thing every building of this kind has there, and it gives the
		elevation a horizontal to sit the two rows of windows either side of.

		It follows the wings as well as the block, because a course that
		stopped at the corners would look like a shelf rather than a course.
	]]
	local COURSE_Y = PLINTH + 17.5

	--[[
		A rusticated ground storey: the lower half in a darker course,
		standing a little proud of the wall above it.

		Ashlar is one flat plane however long the elevation is, and at two
		hundred and sixty studs a single plane has nothing in it for a low
		sun to catch — the string course gave the wall a horizontal, and this
		gives it a front and a back. Heavier stone below and finer above is
		how every building of this kind is put together, and the half stud of
		relief is what draws the line between them without needing a line
		drawn.
	]]
	local RUSTIC = 0.6
	Build.part({
		name = "Rustication",
		size = Vector3.new(width + RUSTIC * 2, COURSE_Y - PLINTH, depth + RUSTIC * 2),
		cframe = CFrame.new(centre.X, (COURSE_Y + PLINTH) * 0.5, centre.Z),
		color = stoneShade,
		material = Enum.Material.Sandstone,
		parent = manor,
	})
	for _, side in { -1, 1 } do
		Build.part({
			name = "Rustication",
			size = Vector3.new(
				wingWidth + RUSTIC * 2,
				COURSE_Y - PLINTH,
				depth + wingOut + RUSTIC * 2
			),
			cframe = CFrame.new(
				centre.X + side * (halfWidth - wingWidth * 0.5),
				(COURSE_Y + PLINTH) * 0.5,
				centre.Z - wingOut * 0.5
			),
			color = stoneShade,
			material = Enum.Material.Sandstone,
			parent = manor,
		})
	end

	Build.part({
		name = "StringCourse",
		size = Vector3.new(width + 1.6, 1.8, depth + 1.6),
		cframe = CFrame.new(centre.X, COURSE_Y, centre.Z),
		color = quoin,
		material = Enum.Material.Sandstone,
		parent = manor,
	})
	for _, side in { -1, 1 } do
		Build.part({
			name = "StringCourse",
			size = Vector3.new(wingWidth + 1.6, 1.8, depth + wingOut + 1.6),
			cframe = CFrame.new(
				centre.X + side * (halfWidth - wingWidth * 0.5),
				COURSE_Y,
				centre.Z - wingOut * 0.5
			),
			color = quoin,
			material = Enum.Material.Sandstone,
			parent = manor,
		})
	end

	--- The lead cornice the roof sits behind.
	Build.part({
		name = "Cornice",
		size = Vector3.new(width + 7, 2.6, depth + wingOut + 7),
		cframe = CFrame.new(centre.X, wallTop + 1.3, centre.Z - wingOut * 0.5),
		color = lead,
		material = Enum.Material.Metal,
		parent = manor,
	})

	--[[
		A mansard, which is two pitches: a steep lower slope you see, and a
		shallow cap you do not.

		The first house has one gable in brown shingle. This is grey slate,
		much steeper, and the dormers standing out of it are what make a roof
		read as an attic storey rather than as a lid.
	]]
	local MANSARD = 13
	local mansardY = wallTop + 2.6
	Build.part({
		name = "Mansard",
		size = Vector3.new(width + 3, MANSARD, depth + wingOut + 3),
		cframe = CFrame.new(centre.X, mansardY + MANSARD * 0.5, centre.Z - wingOut * 0.5),
		color = roofColour,
		material = Enum.Material.Slate,
		parent = manor,
	})
	Build.part({
		name = "RoofCap",
		size = Vector3.new(width - 14, 3, depth + wingOut - 14),
		cframe = CFrame.new(centre.X, mansardY + MANSARD + 1.5, centre.Z - wingOut * 0.5),
		color = Palette.color(Palette.estate.roofDark),
		material = Enum.Material.Slate,
		parent = manor,
	})

	--- Dormers out of the front slope, evenly spaced and skipping the middle
	--- where the pediment stands.
	local dormerCount = math.max(math.floor(width / 34), 3)
	for index = 0, dormerCount - 1 do
		local t = (index + 0.5) / dormerCount
		local x = centre.X - halfWidth + width * t
		if math.abs(x - centre.X) > width * 0.16 then
			local z = frontZ - wingOut + 1
			Build.part({
				name = "Dormer",
				size = Vector3.new(9, 9, 5),
				cframe = CFrame.new(x, mansardY + 5.5, z),
				color = quoin,
				material = Enum.Material.Sandstone,
				parent = manor,
			})
			Build.part({
				name = "DormerRoof",
				size = Vector3.new(10.5, 1.6, 6),
				cframe = CFrame.new(x, mansardY + 10.8, z),
				color = lead,
				material = Enum.Material.Metal,
				parent = manor,
			})
			glazed({
				name = "Window",
				size = Vector3.new(5, 6, 0.9),
				cframe = CFrame.new(x, mansardY + 5.5, z - 2.7),
				glass = Palette.estate.window,
				parent = manor,
			})
		end
	end

	--[[
		A balustrade along the roofline, which is the estate's answer to the
		first house's teal band: the thing you recognise it by at a distance.
	]]
	local baluster = math.max(math.floor(width / 11), 6)
	for index = 0, baluster - 1 do
		local x = centre.X - halfWidth + width * ((index + 0.5) / baluster)
		Build.part({
			name = "Baluster",
			size = Vector3.new(1.6, 4.5, 1.6),
			cframe = CFrame.new(x, wallTop + 4.9, centre.Z + halfDepth + 2),
			color = quoin,
			material = Enum.Material.Sandstone,
			parent = manor,
		})
	end

	--- Four stacks in pairs, because a symmetrical house has symmetrical ones.
	for _, sx in { -0.62, 0.62 } do
		for _, sz in { -0.4, 0.4 } do
			Build.part({
				name = "Chimney",
				size = Vector3.new(7, 17, 9),
				cframe = CFrame.new(
					centre.X + halfWidth * sx,
					mansardY + MANSARD * 0.5 + 8.5,
					centre.Z + halfDepth * sz - wingOut * 0.5
				),
				color = stoneShade,
				material = Enum.Material.Sandstone,
				parent = manor,
			})
		end
	end

	--------------------------------------------------------------------
	-- Windows, in stone surrounds
	--------------------------------------------------------------------

	-- Close enough together to read as a frontage rather than as a wall
	-- with a few holes in it: this elevation is two hundred and sixty studs
	-- across, and at a twenty-one stud pitch it had six windows on it.
	local WINDOW_PITCH = 16
	local storeys = { 12, 25 }

	--- `outward` is the way the wall faces, so the glass can stand proud of
	--- its own surround rather than inside it.
	local function windowsAlong(
		origin: Vector3,
		along: Vector3,
		span: number,
		yaw: number,
		outward: Vector3,
		clear: number?
	)
		local usable = span - 20
		if usable <= 0 then
			return
		end
		local count = math.max(math.floor(usable / WINDOW_PITCH), 1)
		local step = usable / count
		for index = 0, count do
			local offset = -usable * 0.5 + step * index
			if not clear or math.abs(offset) > clear then
				for _, height in storeys do
					local at = origin + along * offset
					-- The surround first, then the glass in front of it: a
					-- window in a stone house is a hole with dressed edges.
					Build.part({
						name = "Surround",
						size = Vector3.new(if math.abs(yaw) < 0.1 or math.abs(yaw - math.pi) < 0.1 then 11 else 1.4, 12, if math.abs(yaw) < 0.1 or math.abs(yaw - math.pi) < 0.1 then 1.4 else 11),
						cframe = CFrame.new(at.X, height, at.Z),
						color = quoin,
						material = Enum.Material.Sandstone,
						parent = manor,
					})
					--[[
						The glass in front of the stone, not inside it.

						The surround is a stud and two fifths deep and the
						window not quite one, and both were built on the same
						plane — so every pane on the building was sitting
						inside its own dressing, which is opaque. The manor
						had two rows of blank stone panels where its windows
						should have been, and it had them from the day the
						surrounds were added.
					]]
					local glass = at + outward * 0.55
					glazed({
						name = "Window",
						size = Vector3.new(8, 9.5, 0.9),
						cframe = CFrame.new(Vector3.new(glass.X, height, glass.Z)) * CFrame.Angles(0, yaw, 0),
						glass = Palette.estate.window,
						parent = manor,
					})
					--[[
						A sill under it and a head over it.

						A window in a stone house is not a pane laid on a
						wall, it is an opening with a cut stone shelf beneath
						and a lintel above, and those two edges are what
						catch the afternoon light and give the elevation its
						texture. Sized off the surround so they read as part
						of the same piece of masonry.
					]]
					--[[
						The lower storey stands six tenths proud, so anything
						hung on the wall at the old depth is now inside it.
						Both the glass and its dressing move out with it.
					]]
					local flat = math.abs(yaw) < 0.1 or math.abs(yaw - math.pi) < 0.1
					for _, trim in { { -6.4, 12.5, 1.1 }, { 6.6, 11.5, 0.9 } } do
						Build.part({
							name = "WindowTrim",
							size = if flat
								then Vector3.new(trim[2], trim[3], 2.2)
								else Vector3.new(2.2, trim[3], trim[2]),
							cframe = CFrame.new(at.X, height + trim[1], at.Z),
							color = quoin,
							material = Enum.Material.Sandstone,
							canCollide = false,
							parent = manor,
						})
					end
				end
			end
		end
	end

	local sideways = Vector3.new(1, 0, 0)
	local frontways = Vector3.new(0, 0, 1)
	--[[
		Set out from the wall far enough to clear the rusticated storey.

		The lower half of the building now stands six tenths of a stud proud
		of the upper, so a window hung at the old depth sits inside the stone
		on the ground floor and on the face of it upstairs. Both rows are set
		to the outer plane instead, which is where a window in a stone wall
		is anyway: in the face of the dressing, not behind it.
	]]
	local FACE = 1.2 + RUSTIC
	windowsAlong(Vector3.new(centre.X, 0, frontZ - wingOut - FACE), sideways, width, 0, -frontways, width * 0.19)
	windowsAlong(
		centre + frontways * (halfDepth + FACE),
		sideways,
		width,
		math.pi,
		frontways,
		bayWidth * 0.5 + 6
	)
	windowsAlong(Vector3.new(centre.X - halfWidth - FACE, 0, centre.Z - wingOut * 0.5), frontways, depth, math.rad(-90), -sideways, nil)
	windowsAlong(Vector3.new(centre.X + halfWidth + FACE, 0, centre.Z - wingOut * 0.5), frontways, depth, math.rad(90), sideways, nil)

	--------------------------------------------------------------------
	-- The portico
	--------------------------------------------------------------------

	--[[
		Six columns and a pediment across the middle of the frontage.

		The first house has a porch: a corner of decking on two square posts,
		off to one side of the front door. This is the other thing entirely —
		centred, the full height of the building, and the reason you can tell
		which way round the house is from anywhere on the lawn.
	]]
	local portico = Build.folder("Portico", manor)
	local porticoWidth = width * 0.30
	local porticoDepth = 22
	local porticoZ = frontZ - wingOut - porticoDepth * 0.5
	local COLUMN_H = 26

	Build.part({
		name = "PorticoFloor",
		size = Vector3.new(porticoWidth + 6, PLINTH, porticoDepth + 4),
		cframe = CFrame.new(centre.X, PLINTH * 0.5, porticoZ),
		color = stoneShade,
		material = Enum.Material.Sandstone,
		parent = portico,
	})

	for index = 0, 5 do
		local x = centre.X + (index - 2.5) * (porticoWidth / 5)
		Build.mesh({
			prop = "Column",
			name = "Column",
			untextured = true,
			color = quoin,
			size = Vector3.new(4.4, COLUMN_H, 4.4),
			collisionSize = Vector3.new(3.6, COLUMN_H, 3.6),
			cframe = CFrame.new(x, PLINTH + COLUMN_H * 0.5, porticoZ - porticoDepth * 0.5 + 3),
			parent = portico,
		})
	end

	Build.part({
		name = "Entablature",
		size = Vector3.new(porticoWidth + 8, 4.5, porticoDepth + 4),
		cframe = CFrame.new(centre.X, PLINTH + COLUMN_H + 2.25, porticoZ),
		color = quoin,
		material = Enum.Material.Sandstone,
		parent = portico,
	})

	--[[
		A flat roof with a balustrade on it, not a pediment.

		The pediment was a stepped stack the full depth of the portico —
		twenty-six studs of stone lying flat — so from the lawn it read as an
		enormous grey awning bolted across the middle of the house, and it hid
		the entire frontage behind it: the windows, the door, and the balcony
		that was supposed to be the point of the storey above.

		A balustraded portico roof is the other thing houses like this do with
		that space, and it is the better one here: nothing blocks the front,
		and the first floor gets somewhere to open onto.
	]]
	Build.part({
		name = "PorticoRoof",
		size = Vector3.new(porticoWidth + 10, 1.6, porticoDepth + 5),
		cframe = CFrame.new(centre.X, PLINTH + COLUMN_H + 5.3, porticoZ),
		color = lead,
		material = Enum.Material.Metal,
		parent = portico,
	})

	--- Steps the full width of the portico, which is how you arrive at one.
	for step = 0, 2 do
		local tread = PLINTH - step * 0.9
		Build.part({
			name = "Step",
			size = Vector3.new(porticoWidth + 6 + step * 3, tread, 3.6),
			cframe = CFrame.new(
				centre.X,
				tread * 0.5,
				porticoZ + porticoDepth * 0.5 + 1.8 + step * 3.4
			),
			color = stoneShade,
			material = Enum.Material.Sandstone,
			parent = portico,
		})
	end

	--------------------------------------------------------------------
	-- The frontage
	--------------------------------------------------------------------

	--[[
		What a front door on a house this size actually looks like.

		A single door leaf under a portico four columns wide reads as a shed
		door on a hotel. This is the arrangement every building like this
		has: a pair of tall doors, a fanlight over them, and a stone surround
		around the whole opening.
	]]
	local doorZ = frontZ - wingOut - 0.5
	Build.part({
		name = "DoorCase",
		size = Vector3.new(20, 22, 1.6),
		cframe = CFrame.new(centre.X, PLINTH + 11, doorZ + 0.4),
		color = quoin,
		material = Enum.Material.Sandstone,
		parent = manor,
	})
	for _, side in { -1, 1 } do
		Build.mesh({
			prop = "Door",
			name = "Door",
			untextured = true,
			color = Palette.color(Palette.estate.door),
			size = Vector3.new(7, 15, 0.9),
			collisionSize = Vector3.new(7, 15, 0.6),
			cframe = CFrame.new(centre.X + side * 3.7, PLINTH + 7.5, doorZ),
			canCollide = false,
			parent = manor,
		})
	end
	--- The fanlight over them, which is the one round thing on the frontage.
	glazed({
		name = "Fanlight",
		size = Vector3.new(13, 5, 0.9),
		cframe = CFrame.new(centre.X, PLINTH + 17.5, doorZ),
		glass = Palette.estate.window,
		parent = manor,
	})

	--[[
		A balcony over the portico, with glazed doors onto it.

		The portico's entablature is a flat stone shelf twenty-two studs deep
		at first-floor height, and nothing stood on it — so the middle of the
		frontage, the part the whole building is arranged around, was a blank
		wall above the columns. A balustraded balcony with a pair of glass
		doors behind it is what the room over the entrance opens onto, and it
		gives the front a middle storey to look at.
	]]
	local balconyY = PLINTH + COLUMN_H + 6.1
	local balconyZ = porticoZ + porticoDepth * 0.5 - 1.2
	local balusters = math.max(math.floor((porticoWidth + 8) / 5), 6)
	for index = 0, balusters - 1 do
		local x = centre.X - (porticoWidth + 8) * 0.5 + (porticoWidth + 8) * ((index + 0.5) / balusters)
		Build.part({
			name = "Baluster",
			size = Vector3.new(1.5, 4.2, 1.5),
			cframe = CFrame.new(x, balconyY + 2.1, balconyZ),
			color = quoin,
			material = Enum.Material.Sandstone,
			parent = portico,
		})
	end
	Build.part({
		name = "BalconyRail",
		size = Vector3.new(porticoWidth + 9, 1, 2.6),
		cframe = CFrame.new(centre.X, balconyY + 4.7, balconyZ),
		color = quoin,
		material = Enum.Material.Sandstone,
		parent = portico,
	})

	--- The glazed doors it belongs to, in their own stone surround.
	local frenchZ = frontZ - wingOut - 1.0
	Build.part({
		name = "BalconyCase",
		size = Vector3.new(19, 19, 1.4),
		cframe = CFrame.new(centre.X, balconyY + 8, frenchZ + 0.5),
		color = quoin,
		material = Enum.Material.Sandstone,
		parent = manor,
	})
	for _, side in { -1, 1 } do
		glazed({
			name = "FrenchDoor",
			size = Vector3.new(7, 15, 0.9),
			cframe = CFrame.new(centre.X + side * 3.8, balconyY + 7.5, frenchZ),
			glass = Palette.estate.window,
			parent = manor,
		})
	end

	--[[
		A lamp either side of the door, on a bracket.

		A frontage this wide needs something at eye level that is not stone,
		and a pair of lanterns either side of the door is the thing every
		house of this kind puts there.

		On a bracket, because the mesh is a hurricane lamp with a carrying
		hoop on the top of it and nothing was holding it: what stood on the
		wall was a black oval floating flat against fourteen studs of blank
		ashlar, and from the drive it read as a mark on the stone rather than
		as a light. A plate, an arm out of it and a hook to hang from, and it
		stands clear of the wall the way a lantern has to.

	]]
	local FLAME = Color3.fromRGB(255, 226, 170)
	for _, side in { -1, 1 } do
		local x = centre.X + side * (porticoWidth * 0.5 + 4)
		local hangZ = doorZ - 2.8
		local armY = PLINTH + 15.6
		Build.part({
			name = "LampPlate",
			size = Vector3.new(1.6, 3.2, 0.4),
			cframe = CFrame.new(x, armY - 0.6, doorZ - 0.6),
			color = Palette.color(Palette.estate.iron),
			material = Enum.Material.Metal,
			canCollide = false,
			parent = manor,
		})
		Build.part({
			name = "LampArm",
			size = Vector3.new(0.5, 0.5, 2.6),
			cframe = CFrame.new(x, armY, doorZ - 1.7),
			color = Palette.color(Palette.estate.iron),
			material = Enum.Material.Metal,
			canCollide = false,
			parent = manor,
		})
		Build.part({
			name = "LampHook",
			size = Vector3.new(0.4, 1.3, 0.4),
			cframe = CFrame.new(x, armY - 0.65, hangZ),
			color = Palette.color(Palette.estate.iron),
			material = Enum.Material.Metal,
			canCollide = false,
			parent = manor,
		})
		local lamp = Build.mesh({
			prop = "Lantern",
			name = "Lamp",
			untextured = true,
			color = Palette.color(Palette.estate.iron),
			size = Vector3.new(3.4, 4.4, 3.4),
			collisionSize = Vector3.new(2, 4.4, 2),
			cframe = CFrame.new(x, PLINTH + 13, hangZ),
			canCollide = false,
			parent = manor,
		})
		local glow = Instance.new("PointLight")
		glow.Color = FLAME
		glow.Range = 26
		glow.Brightness = 1.4
		glow.Parent = lamp
	end

	--------------------------------------------------------------------
	-- The garden front
	--------------------------------------------------------------------

	--[[
		The back of the house, which is the side you spend the run looking at.

		The front got a portico, a balcony, French doors, dormers, quoins and
		a flight of steps. The back got twenty-eight identical windows in two
		rows across a hundred and eighty studs of flat wall, no door, and a
		plain slab of roof over it — and the back is the side that faces the
		maze, the terrace and the whole walk to the exit, so it is what a
		player actually looks at for most of two and a half minutes.

		On a house of this kind the garden front is usually the better of the
		two. This one gets what one has: a centre bay standing proud of the
		wall its full height, dressed at the corners, carrying an attic and a
		balustrade above the cornice; French doors at ground level; and a
		perron of steps down to the lawn between balustraded cheeks. The rear
		roof slope gets the dormers the front slope already had.
	]]
	local backZ = centre.Z + halfDepth
	local BAY_OUT = 5
	local bayFace = backZ + BAY_OUT

	--- The bay, set into the wall by a stud so no two faces are coplanar.
	Build.part({
		name = "GardenBay",
		size = Vector3.new(bayWidth, wallTop, BAY_OUT + 2),
		cframe = CFrame.new(centre.X, wallTop * 0.5, backZ + BAY_OUT * 0.5 - 1),
		color = stone,
		material = Enum.Material.Sandstone,
		parent = manor,
	})

	--- Dressed corners, the same language the building's own corners use.
	for _, side in { -1, 1 } do
		Build.part({
			name = "Quoin",
			size = Vector3.new(3.4, wallTop, BAY_OUT + 2.6),
			cframe = CFrame.new(
				centre.X + side * (bayWidth * 0.5 - 1.7),
				wallTop * 0.5,
				backZ + BAY_OUT * 0.5 - 1
			),
			color = quoin,
			material = Enum.Material.Sandstone,
			parent = manor,
		})
	end

	--- Cornice, attic and balustrade over the bay.
	Build.part({
		name = "Cornice",
		size = Vector3.new(bayWidth + 5, 2.4, BAY_OUT + 4),
		cframe = CFrame.new(centre.X, wallTop + 1.2, backZ + BAY_OUT * 0.5 - 1),
		color = lead,
		material = Enum.Material.Metal,
		parent = manor,
	})
	Build.part({
		name = "BayAttic",
		size = Vector3.new(bayWidth - 8, 7, BAY_OUT + 1),
		cframe = CFrame.new(centre.X, wallTop + 5.9, backZ + BAY_OUT * 0.5 - 1.4),
		color = quoin,
		material = Enum.Material.Sandstone,
		parent = manor,
	})
	local balustradeCount = math.max(math.floor(bayWidth / 5), 4)
	for index = 0, balustradeCount do
		local x = centre.X - bayWidth * 0.5 + bayWidth * (index / balustradeCount)
		if math.abs(x - centre.X) > bayWidth * 0.5 - 6 then
			Build.part({
				name = "Baluster",
				size = Vector3.new(1.5, 4.5, 1.5),
				cframe = CFrame.new(x, wallTop + 4.6, bayFace - 1),
				color = quoin,
				material = Enum.Material.Sandstone,
				canCollide = false,
				parent = manor,
			})
		end
	end

	--- French doors onto the garden, with their surround.
	local doorTop = PLINTH + 17
	Build.part({
		name = "DoorCase",
		size = Vector3.new(23, 21, 1.4),
		cframe = CFrame.new(centre.X, PLINTH + 10.5, bayFace - 0.3),
		color = quoin,
		material = Enum.Material.Sandstone,
		parent = manor,
	})
	for _, side in { -1, 1 } do
		glazed({
			name = "FrenchDoor",
			size = Vector3.new(8, 16, 0.9),
			cframe = CFrame.new(centre.X + side * 4.4, PLINTH + 9, bayFace + 0.4)
				* CFrame.Angles(0, math.pi, 0),
			glass = Palette.estate.window,
			parent = manor,
		})
	end
	Build.part({
		name = "StringCourse",
		size = Vector3.new(27, 1.6, 2.6),
		cframe = CFrame.new(centre.X, doorTop + 4.4, bayFace),
		color = lead,
		material = Enum.Material.Metal,
		canCollide = false,
		parent = manor,
	})

	--[[
		A threshold rather than a flight of steps.

		A garden front of this size wants a perron — three broad steps down
		between balustraded cheeks. It does not fit: the long maze begins ten
		studs behind the house and the bay eats five of them, so the steps
		came out standing inside the first row of hedge. What fits in five
		studs is a threshold slab the width of the doors, which is what the
		doors need anyway to open onto something other than grass.
	]]
	Build.part({
		name = "Threshold",
		size = Vector3.new(30, PLINTH, 4),
		cframe = CFrame.new(centre.X, PLINTH * 0.5, bayFace + 2),
		color = quoin,
		material = Enum.Material.Sandstone,
		parent = manor,
	})

	--- Dormers in the rear slope, to match the front's.
	for index = 0, dormerCount - 1 do
		local t = (index + 0.5) / dormerCount
		local x = centre.X - halfWidth + width * t
		if math.abs(x - centre.X) > bayWidth * 0.5 + 4 then
			local z = backZ - 1
			Build.part({
				name = "Dormer",
				size = Vector3.new(9, 9, 5),
				cframe = CFrame.new(x, mansardY + 5.5, z),
				color = quoin,
				material = Enum.Material.Sandstone,
				parent = manor,
			})
			Build.part({
				name = "DormerRoof",
				size = Vector3.new(10.5, 1.6, 6),
				cframe = CFrame.new(x, mansardY + 10.8, z),
				color = lead,
				material = Enum.Material.Metal,
				parent = manor,
			})
			glazed({
				name = "Window",
				size = Vector3.new(5, 6, 0.9),
				cframe = CFrame.new(x, mansardY + 5.5, z + 2.7) * CFrame.Angles(0, math.pi, 0),
				glass = Palette.estate.window,
				parent = manor,
			})
		end
	end
end

local function buildHouse(world: Types.WorldDef, parent: Folder)
	local rect = world.houseRect
	if not rect then
		return
	end

	local house = Build.folder("House", parent)
	local centre = WorldService.tilePointFlat(rect.x + rect.w * 0.5, rect.z + rect.d * 0.5)
	local width, depth = rect.w * TILE, rect.d * TILE
	local wallHeight = ROOF_HEIGHT - 4

	--[[
		Brick foundation the siding sits on.

		A plain part rather than the brick model, for the reason the lawn is a
		plain surface: the model's courses are four studs wide, and stretched
		along a hundred and eighty stud frontage each brick became a
		hundred-and-eighty stud smear. Roblox's brick material tiles rather
		than stretches, so it is bricks at any length of wall.
	]]
	Build.part({
		name = "Foundation",
		size = Vector3.new(width + 1.5, 4, depth + 1.5),
		cframe = CFrame.new(centre + Vector3.new(0, 2, 0)),
		color = Palette.color(Palette.house.brick),
		material = Enum.Material.Brick,
		parent = house,
	})

	-- Solid core, so the shell is never see-through at a corner. Never seen
	-- directly — the lap courses stand outside it — so it is a plain mass.
	Build.part({
		name = "Core",
		size = Vector3.new(width - 1, wallHeight, depth - 1),
		cframe = CFrame.new(centre + Vector3.new(0, 4 + wallHeight * 0.5, 0)),
		color = Palette.color(Palette.house.sidingShade),
		material = Enum.Material.SmoothPlastic,
		parent = house,
	})

	local wallCentreY = 4 + wallHeight * 0.5
	local faces = {
		{ offset = Vector3.new(0, wallCentreY, -depth * 0.5), facing = Vector3.new(0, 0, 1), size = Vector3.new(width, wallHeight, 1) },
		{ offset = Vector3.new(0, wallCentreY, depth * 0.5), facing = Vector3.new(0, 0, 1), size = Vector3.new(width, wallHeight, 1) },
		{ offset = Vector3.new(-width * 0.5, wallCentreY, 0), facing = Vector3.new(1, 0, 0), size = Vector3.new(1, wallHeight, depth) },
		{ offset = Vector3.new(width * 0.5, wallCentreY, 0), facing = Vector3.new(1, 0, 0), size = Vector3.new(1, wallHeight, depth) },
	}
	for _, face in faces do
		Build.sidingWall(house, centre + face.offset, face.size, face.facing, 2.6)
	end

	-- The teal band under the eaves, the single most identifying colour here.
	Build.part({
		name = "Trim",
		size = Vector3.new(width + 4, 2.2, depth + 4),
		cframe = CFrame.new(centre + Vector3.new(0, 4 + wallHeight + 1, 0)),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		parent = house,
	})

	--[[
		The roof, which is either a deck or a roofline depending on the world.

		The House puts a section on top of its house — the Rooftop is somewhere
		you go and something you clear — so that one has to stay flat and
		walkable, and gets a capped slab. Nothing stands on the Mansion or the
		Gas Station's roof, so those get the pitch, which is what makes a
		building read as a house from the far side of a lawn instead of as a
		long shed.

		Either way it is no longer the shingle model stretched across the whole
		roof. That model is a panel of shingles about a stud across, so scaled
		to sixty by a hundred and eighty studs it came out as a coarse green
		chequerboard you could see from the road.
	]]
	if walkableRoof(world, rect) then
		Build.part({
			name = "Roof",
			size = Vector3.new(width + 5, GameConfig.HOUSE_ROOF_THICKNESS, depth + 5),
			cframe = CFrame.new(
				centre
					+ Vector3.new(
						0,
						GameConfig.HOUSE_FOUNDATION + wallHeight + GameConfig.HOUSE_ROOF_RISE,
						0
					)
			),
			color = Palette.color(Palette.house.roof),
			material = Enum.Material.Slate,
			parent = house,
		})
	else
		Build.gableRoof(
			house,
			centre,
			width + 4,
			depth + 4,
			4 + wallHeight + 2.2,
			math.clamp(math.min(width, depth) * 0.34, 8, 22),
			3.5,
			Palette.color(Palette.house.roof),
			Palette.color(Palette.house.trim),
			-- The gable is wall, not trim: it is the triangle of the house
			-- itself showing between the two slopes, so it takes the siding.
			Palette.color(Palette.house.siding)
		)
	end

	local frontZ = centre.Z - depth * 0.5

	--[[
		The garage's footprint on the front wall, measured once.

		The windows need it to keep off it and the doors need it to be built
		at, and when only the door builder knew it the window scatter placed
		two arched windows inside the bays — glass in the middle of a garage
		door, which is not a thing.
	]]
	--[[
		A bay is fourteen studs because a car is about ten, and how many
		of them there are follows the frontage: two on The House's
		hundred and seventy-six, three on The Mansion's two hundred and
		sixty-four. A two-car garage on a mansion reads as a shed
		bolted to a hotel.
	]]
	local GARAGE_BAY_WIDTH = 14
	local GARAGE_BAYS = math.clamp(math.round(width / 90), 2, 4)
	local garageWidth = GARAGE_BAY_WIDTH * GARAGE_BAYS + 1.5 * (GARAGE_BAYS - 1)
	local garageOffset = width * 0.28

	--[[
		Windows, on every side and enough of them to read as a house.

		There used to be two, both on the front, at fixed fractions of the
		width. The House's frontage is a hundred and eighty studs across, so two
		nine-stud windows on it is not a house with windows — it is a very long
		fence with two holes, and from the lawn that is exactly what it looked
		like. The other three walls had none at all, so from anywhere but the
		front the building was a blank slab.

		They are spaced along each wall now rather than placed at hand, at a
		pitch that divides the wall evenly, in two storeys where the wall is
		tall enough for a second. The margin keeps them off the corners, where
		a window would otherwise run past the end of its own wall.
	]]
	local WINDOW_PITCH = 17
	local WINDOW_WIDTH, WINDOW_HEIGHT = 7.5, 7
	--- Window centre heights. A second storey only where the wall is tall.
	local storeys: { number } = if wallHeight >= 24 then { 11, 22 } else { 11 }
	--- Kept clear of the corners, so a window never runs past its own wall.
	local MARGIN = 12

	--[[
		Places a row of windows along one wall.

		`origin` is the middle of the wall face, `along` the direction the wall
		runs, and `yaw` the way the window should face. `keepOuts` are stretches
		of the wall to leave alone, each an offset from the wall's middle and a
		half-width: the porch, whose roof would hide anything behind it, and the
		garage, whose doors are not a place to put a window.
	]]
	type KeepOut = { at: number, half: number }
	local function windowsAlong(
		origin: Vector3,
		along: Vector3,
		span: number,
		yaw: number,
		keepOuts: { KeepOut }?
	)
		local usable = span - MARGIN
		if usable <= 0 then
			return
		end
		local count = math.max(math.floor(usable / WINDOW_PITCH), 1)
		local step = usable / count

		for index = 0, count do
			local offset = -usable * 0.5 + step * index
			for storey, height in storeys do
				-- Both the porch and the garage are ground-floor things; a
				-- second storey sails over the top of either.
				local hidden = false
				if storey == 1 and keepOuts then
					for _, zone in keepOuts do
						if math.abs(offset - zone.at) < zone.half then
							hidden = true
							break
						end
					end
				end
				if not hidden then
					local at = origin + along * offset
					glazed({
						name = "Window",
						size = Vector3.new(WINDOW_WIDTH, WINDOW_HEIGHT, 0.9),
						cframe = CFrame.new(Vector3.new(at.X, height, at.Z)) * CFrame.Angles(0, yaw, 0),
						glass = Palette.house.window,
						parent = house,
					})
				end
			end
		end
	end

	local halfWidth, halfDepth = width * 0.5, depth * 0.5
	local porchClear = width * 0.42 * 0.5 + 6
	local sideways = Vector3.new(1, 0, 0)
	local frontways = Vector3.new(0, 0, 1)

	-- Front, back, then the two ends. Only the front has anything on it.
	local frontKeepOuts: { KeepOut } = {
		{ at = -width * 0.18, half = porchClear },
		-- The trim runs a stud past the doors on each side, and a window
		-- wants a little wall of its own beyond that.
		{ at = garageOffset, half = garageWidth * 0.5 + 7 },
	}
	windowsAlong(centre - frontways * (halfDepth + 0.7), sideways, width, 0, frontKeepOuts)
	windowsAlong(centre + frontways * (halfDepth + 0.7), sideways, width, math.pi, nil)
	windowsAlong(centre - sideways * (halfWidth + 0.7), frontways, depth, math.rad(-90), nil)
	windowsAlong(centre + sideways * (halfWidth + 0.7), frontways, depth, math.rad(90), nil)

	--[[
		A chimney, for the roofline.

		A house seen from across a lawn is mostly its silhouette, and a flat
		slab of roof has none. One stack breaks it.
	]]
	Build.part({
		name = "Chimney",
		size = Vector3.new(7, 12, 7),
		cframe = CFrame.new(centre + Vector3.new(halfWidth * 0.56, 4 + wallHeight + 7, halfDepth * 0.24)),
		color = Palette.color(Palette.house.brick),
		material = Enum.Material.Brick,
		parent = house,
	})

	--------------------------------------------------------------------
	-- Porch
	--------------------------------------------------------------------

	local porch = Build.folder("Porch", house)
	local porchDepth = 14
	local porchWidth = width * 0.42
	local porchZ = frontZ - porchDepth * 0.5
	local porchX = centre.X - width * 0.18

	Build.part({
		name = "PorchBrick",
		size = Vector3.new(porchWidth, 3.6, porchDepth),
		cframe = CFrame.new(porchX, 1.8, porchZ),
		color = Palette.color(Palette.house.brick),
		material = Enum.Material.Brick,
		parent = porch,
	})
	-- Boards, because a porch deck is boards. The paving model stretched to
	-- the width of a porch was one enormous slab.
	Build.part({
		name = "PorchDeck",
		size = Vector3.new(porchWidth, 0.8, porchDepth),
		cframe = CFrame.new(porchX, 3.9, porchZ),
		color = Palette.color(Palette.churchyard.timber),
		material = Enum.Material.WoodPlanks,
		parent = porch,
	})

	-- Square tapered columns carrying a porch roof.
	for _, side in { -1, 1 } do
		local x = porchX + side * (porchWidth * 0.5 - 1.6)
		Build.mesh({
			prop = "Column",
			name = "Column",
			size = Vector3.new(2.6, 13, 2.6),
			collisionSize = Vector3.new(2.2, 13, 2.2),
			cframe = CFrame.new(x, 10.8, porchZ - porchDepth * 0.5 + 1.4),
			parent = porch,
		})
	end
	Build.part({
		name = "PorchRoof",
		size = Vector3.new(porchWidth + 3, 1.6, porchDepth + 2),
		cframe = CFrame.new(porchX, 18, porchZ),
		color = Palette.color(Palette.house.roof),
		material = Enum.Material.Slate,
		parent = porch,
	})
	Build.part({
		name = "PorchTrim",
		size = Vector3.new(porchWidth + 3.4, 1, porchDepth + 2.4),
		cframe = CFrame.new(porchX, 17, porchZ),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		parent = porch,
	})

	--[[
		Rail down the open side of the porch — with a way through it.

		This ran the porch's whole front in one unbroken, collidable line, and
		the steps climbed straight into the middle of it: you walked up the
		path, up the stairs, and stood face to a fence with the front door on
		the other side. A porch rail has an opening at its steps, because the
		steps are the way onto the porch.
	]]
	local railZ = porchZ - porchDepth * 0.5 + 0.6
	local GAP = 10
	local railEnds = { porchX - (porchWidth - 4) * 0.5, porchX + (porchWidth - 4) * 0.5 }
	for _, run in { { railEnds[1], porchX - GAP * 0.5 }, { porchX + GAP * 0.5, railEnds[2] } } do
		local span = run[2] - run[1]
		if span > 1 then
			local railSections = math.max(math.floor(span / 10 + 0.5), 1)
			local railWidth = span / railSections
			for index = 0, railSections - 1 do
				Build.mesh({
					prop = "Railing",
					name = "RailTop",
					size = Vector3.new(railWidth, 4.2, 0.9),
					collisionSize = Vector3.new(railWidth, 4.2, 0.8),
					cframe = CFrame.new(run[1] + railWidth * (index + 0.5), 6.4, railZ),
					parent = porch,
				})
			end
		end
	end

	-- Steps down to the path, as wide as the opening in the rail above them
	-- rather than half the porch: steps wider than their doorway invite you
	-- to climb them anywhere and meet the rail everywhere but the middle.
	--[[
		Each step is solid from the ground to its own tread.

		They used to be three slabs a stud and a bit thick, hung at three
		heights with nothing underneath any of them: the bottom one floated a
		quarter of a stud over the lawn, the middle one a stud and a half, the
		top one nearly three. Walked up to they were fine — you climb the
		tops. Crouched beside them, which is where a player mowing the front
		garden actually is, they were three pale trays hovering over the path
		with daylight under each, and the whole thing read as a broken
		staircase dropped into the middle of the yard.

		A step is a block. The tread heights are unchanged, so the climb feels
		as it did; what is new is that the block goes all the way down. The top
		one now finishes flush with the porch brick rather than a tenth of a
		stud short of it, and each is deep enough to meet the one below with no
		slot to see through.
	]]
	for step = 0, 2 do
		local tread = 3.6 - step * 1.15
		Build.mesh({
			prop = "StepBlock",
			name = "Step",
			-- Painted stone rather than the model's own pale blue, because
			-- these steps are the last three feet of the flagstone path.
			untextured = true,
			color = Palette.color(Palette.ground.path),
			size = Vector3.new(GAP + 2, tread, 3.4),
			collisionSize = Vector3.new(GAP + 2, tread, 3.4),
			cframe = CFrame.new(
				porchX,
				tread * 0.5,
				porchZ - porchDepth * 0.5 - 1.5 - step * 2.4
			),
			parent = porch,
		})
	end

	Build.mesh({
		prop = "Door",
		name = "Door",
		size = Vector3.new(6.5, 11, 0.9),
		collisionSize = Vector3.new(6.5, 11, 0.6),
		cframe = CFrame.new(porchX, 9.5, frontZ - 0.4),
		canCollide = false,
		parent = house,
	})

	--------------------------------------------------------------------
	-- Attached garage door
	--------------------------------------------------------------------

	local garageX = centre.X + garageOffset
	local garage = Build.folder("GarageFront", house)
	--[[
		A sectional door is sections, so it is built as sections.

		One door model stretched across a sixty stud opening gave a flat
		salmon rectangle with three lines ruled across it — the model's own
		panel joints, pulled twenty times wider than they were drawn. Laid in
		courses at roughly the proportion the model was made at, the joints
		land where a garage door's joints land.
	]]
	--[[
		Two bays, at the size a garage door is.

		It used to be a third of the frontage, which on a house a hundred and
		seventy-six studs wide is a sixty stud door — not a garage, a hangar,
		and the thing that gave away that nothing on this building was drawn to
		a human scale. A car is about ten studs, so a bay is fourteen.
	]]
	local bayWidth, bays = GARAGE_BAY_WIDTH, GARAGE_BAYS
	-- A freshly built door is a shut door, whatever the last world's was doing.
	table.clear(garageSlats)
	garageOpen = false
	--[[
		The doors run from the driveway up, not from the plinth up.

		The house sits on a four-stud brick foundation and the bays were
		built on top of it, so the driveway ran up to a brick wall with the
		doors hanging above it — no car was ever getting in. A garage floor
		is at grade whatever the house does, so the opening starts at the
		ground and the doors stand proud of the brick.
	]]
	local garageHeight = 17
	local courses = math.max(math.floor(garageHeight / 2.6), 1)
	local courseHeight = garageHeight / courses
	for bay = 0, bays - 1 do
		local bayX = garageX + (bay - (bays - 1) * 0.5) * (bayWidth + 1.5)
		for course = 0, courses - 1 do
			local slat = Build.mesh({
				prop = "GarageDoor",
				name = "GarageDoor",
				-- Painted, not printed: the model's own texture is a strong
				-- salmon, and a tint multiplies rather than replaces, so the
				-- cream a suburban garage door is could not be asked for.
				untextured = true,
				color = Palette.color(Palette.house.garage),
				size = Vector3.new(bayWidth, courseHeight * 0.97, 1.2),
				collisionSize = Vector3.new(bayWidth, courseHeight, 0.8),
				cframe = CFrame.new(bayX, courseHeight * (course + 0.5), frontZ - 0.5),
				parent = garage,
			})
			--[[
				Where this course sits when the door is up.

				A roll-up door does not slide into the sky, it gathers into a
				drum under the lintel — so the courses stack tight at the top
				in the order they arrive, the bottom one travelling furthest
				and finishing outermost. Tipped back a little as they land,
				which is what sells it as a curl rather than a stack of
				planks that happens to be near the ceiling.
			]]
			local rolled = CFrame.new(
				bayX,
				garageHeight - 1.1 - course * 0.62,
				frontZ - 0.5 - 0.55 - course * 0.22
			) * CFrame.Angles(math.rad(-16 - course * 3), 0, 0)
			table.insert(garageSlats, { part = slat, shut = slat.CFrame, rolled = rolled })
		end
	end
	--[[
		What is behind a door that has just gone up.

		The trim used to be one slab the size of the whole opening, and while
		the doors were shut that was invisible and fine. Rolled up, it was the
		thing you were left looking at: a flat teal panel the colour of the
		house siding, filling both bays. Opening a garage revealed a painted
		wall.

		There is nothing behind these doors to reveal — the house is solid
		there, its own wall boards half a stud back. So rather than cut a hole
		into a wall, the panel becomes the back of a shallow recess and is
		painted the colour of an unlit garage. A door that goes up now shows
		a dark bay rather than a bright rectangle of siding, which is what the
		eye is expecting.
	]]
	Build.part({
		name = "GarageRecess",
		-- On the trim's own plane, which is the one thing here that is
		-- already proud of the siding. Measured in the running game, the
		-- siding's face is at frontZ - 0.6 and the trim's at frontZ - 0.75;
		-- set flush with the siding, as this first was, the recess sat a
		-- tenth of a stud behind it and simply did not draw.
		size = Vector3.new(garageWidth, garageHeight, 1.0),
		cframe = CFrame.new(garageX, garageHeight * 0.5, frontZ - 0.25),
		color = Palette.color(Palette.rgb(56, 52, 55)),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = garage,
	})

	--[[
		The trim, as a surround rather than a sheet.

		Two jambs, a lintel and a mullion between the bays, so it frames the
		opening instead of filling it. Its face sits at 0.75 out: the siding's
		proudest course is 0.6 and the doors are 1.1, so the trim reads as a
		surround with the doors standing proud of it — which is where the old
		slab had already been tuned to, and the only thing that changes is
		that it no longer covers the hole it is supposed to edge.
	]]
	local trimWidth = 1.6
	local halfOpening = garageWidth * 0.5
	local trimPieces = {
		-- { centre x, centre y, width, height }
		{ garageX - halfOpening - trimWidth * 0.5, garageHeight * 0.5, trimWidth, garageHeight },
		{ garageX + halfOpening + trimWidth * 0.5, garageHeight * 0.5, trimWidth, garageHeight },
		{ garageX, garageHeight + trimWidth * 0.5, garageWidth + trimWidth * 2, trimWidth },
	}
	-- A mullion in each gap between bays, which is where the bays already
	-- leave 1.5 studs of daylight.
	for bay = 1, bays - 1 do
		local left = garageX + ((bay - 1) - (bays - 1) * 0.5) * (bayWidth + 1.5)
		table.insert(trimPieces, { left + (bayWidth + 1.5) * 0.5, garageHeight * 0.5, 1.5, garageHeight })
	end
	for _, piece in trimPieces do
		Build.part({
			name = "GarageTrim",
			size = Vector3.new(piece[3], piece[4], 1.0),
			cframe = CFrame.new(piece[1], piece[2], frontZ - 0.25),
			color = Palette.color(Palette.house.trim),
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = garage,
		})
	end
end

--------------------------------------------------------------------
-- The gas station
--------------------------------------------------------------------

--- A flat disc facing whichever way `cf` looks. A part's cylinder lies along
--- its own X, so it is stood up by a quarter turn.
local function disc(name: string, diameter: number, thickness: number, cf: CFrame, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Name = name
	part.Size = Vector3.new(thickness, diameter, diameter)
	part.CFrame = cf * CFrame.Angles(0, math.rad(90), 0)
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--- The station's badge: a white horse standing proud of a red disc on a white
--- rim, facing whichever way `cf` looks.
local function stationEmblem(cf: CFrame, diameter: number, parent: Instance)
	local emblem = Build.folder("Emblem", parent)
	disc("Rim", diameter, 0.5, cf, Palette.color(Palette.station.trim), emblem)
	disc("Face", diameter * 0.86, 0.62, cf, Palette.color(Palette.station.fascia), emblem)
	local horse = diameter * 0.52
	Build.mesh({
		prop = "PonyEmblem",
		name = "Horse",
		size = Vector3.new(horse * 0.87, horse, 0.5),
		cframe = cf * CFrame.new(0, 0, -0.5),
		canCollide = false,
		castShadow = false,
		parent = emblem,
	})
end

--[[
	The gas station, which The Gas Station did not have.

	The world is named for a filling station and there was none: no canopy, no
	pumps, no shop — a stone lot with a wash bay off to one side, whose whole
	identity was carried by the level select's copy. It stands along the
	entrance strip between the road and the forecourt, on ground no section
	owns, so the mowable area is untouched: pumps under their canopy west of
	the spawn, the shop to the east, and everyone arrives at the kerb between
	them with the overgrown forecourt spreading out behind — which is what
	"closed for the season, nobody told the trees" should look like.
]]
local function buildGasStation(world: Types.WorldDef, parent: Folder)
	local station = Build.folder("Station", parent)
	local spawnAt = WorldService.tilePointFlat(world.spawn.x, world.spawn.z)
	local body = Palette.color(Palette.station.body)
	local fascia = Palette.color(Palette.station.fascia)
	local trim = Palette.color(Palette.station.trim)
	local dark = Palette.color(Palette.station.dark)

	----------------------------------------------------------------
	-- The canopy and its pump islands, west of the spawn.
	----------------------------------------------------------------
	local canopy = Build.folder("Canopy", station)
	local canopyCentre = Vector3.new(spawnAt.X - 90, 0, 22)
	local canopyW, canopyD, canopyH = 76, 30, 13

	--[[
		Four posts, not four Ionic columns.

		The canopy stood on the `Column` model — a fluted classical shaft
		with a scrolled capital on it, which is the right thing under The
		Mansion's portico and is a stranger on a forecourt. Painted white it
		still read as a temple: from the kerb the pumps were sheltering under
		a peristyle.

		What holds a canopy up is a square steel post on a plate, with a
		skirt round the foot in the brand's colour so a car door meeting it
		takes the paint and not the steel.
	]]
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local at = canopyCentre
				+ Vector3.new(sx * (canopyW * 0.5 - 7), 0, sz * (canopyD * 0.5 - 5))
			Build.part({
				name = "CanopyBase",
				size = Vector3.new(4, 0.8, 4),
				cframe = CFrame.new(at + Vector3.new(0, 0.4, 0)),
				color = dark,
				material = Enum.Material.Concrete,
				parent = canopy,
			})
			Build.part({
				name = "CanopyColumn",
				size = Vector3.new(2.6, canopyH, 2.6),
				cframe = CFrame.new(at + Vector3.new(0, canopyH * 0.5, 0)),
				color = trim,
				material = Enum.Material.Metal,
				parent = canopy,
			})
			Build.part({
				name = "CanopySkirt",
				size = Vector3.new(3, 3.4, 3),
				cframe = CFrame.new(at + Vector3.new(0, 2.5, 0)),
				color = fascia,
				material = Enum.Material.SmoothPlastic,
				canCollide = false,
				parent = canopy,
			})
			Build.part({
				name = "CanopyCollar",
				size = Vector3.new(3.4, 1, 3.4),
				cframe = CFrame.new(at + Vector3.new(0, canopyH - 0.6, 0)),
				color = trim,
				material = Enum.Material.Metal,
				canCollide = false,
				parent = canopy,
			})
		end
	end

	Build.part({
		name = "CanopyDeck",
		size = Vector3.new(canopyW, 1.6, canopyD),
		cframe = CFrame.new(canopyCentre + Vector3.new(0, canopyH + 0.8, 0)),
		color = trim,
		material = Enum.Material.SmoothPlastic,
		parent = canopy,
	})
	-- The red band around the canopy's edge, which is the stripe that says
	-- "filling station" from the far side of the lot.
	for _, sz in { -1, 1 } do
		Build.part({
			name = "CanopyFascia",
			size = Vector3.new(canopyW + 1.2, 2.6, 1.0),
			cframe = CFrame.new(canopyCentre + Vector3.new(0, canopyH + 1.1, sz * (canopyD * 0.5 + 0.1))),
			color = fascia,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = canopy,
		})
	end
	for _, sx in { -1, 1 } do
		Build.part({
			name = "CanopyFascia",
			size = Vector3.new(1.0, 2.6, canopyD + 1.2),
			cframe = CFrame.new(canopyCentre + Vector3.new(sx * (canopyW * 0.5 + 0.1), canopyH + 1.1, 0)),
			color = fascia,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = canopy,
		})
	end
	stationEmblem(
		CFrame.new(canopyCentre + Vector3.new(0, canopyH + 1.1, -(canopyD * 0.5 + 0.75))),
		4.6,
		canopy
	)

	-- Two pump islands: a raised kerb with a pump at each end, turned to face
	-- the lanes either side.
	for _, side in { -1, 1 } do
		local islandCentre = canopyCentre + Vector3.new(side * 16, 0, 0)
		Build.part({
			name = "PumpIsland",
			size = Vector3.new(14, 1, 5),
			cframe = CFrame.new(islandCentre + Vector3.new(0, 0.5, 0)),
			color = Palette.color(Palette.ground.path),
			material = Enum.Material.Concrete,
			parent = canopy,
		})
		for _, px in { -1, 1 } do
			Build.mesh({
				prop = "GasPump",
				name = "GasPump",
				size = Vector3.new(2.3, 4.4, 1.3),
				cframe = CFrame.new(islandCentre + Vector3.new(px * 4, 1 + 2.2, 0))
					* CFrame.Angles(0, if px > 0 then 0 else math.pi, 0),
				parent = canopy,
			})
		end
	end

	----------------------------------------------------------------
	-- The shop, east of the spawn, storefront to the road.
	----------------------------------------------------------------
	local shop = Build.folder("Shop", station)
	local shopCentre = Vector3.new(spawnAt.X + 67, 0, 24)
	local shopW, shopD, wallH = 72, 26, 11
	local frontZ = shopCentre.Z - shopD * 0.5

	Build.part({
		name = "ShopFloor",
		size = Vector3.new(shopW, 1, shopD),
		cframe = CFrame.new(shopCentre + Vector3.new(0, 0.5, 0)),
		color = Palette.color(Palette.ground.stoneDark),
		material = Enum.Material.Concrete,
		parent = shop,
	})
	Build.part({
		name = "ShopBack",
		size = Vector3.new(shopW, wallH, 1),
		cframe = CFrame.new(shopCentre + Vector3.new(0, 1 + wallH * 0.5, shopD * 0.5)),
		color = body,
		material = Enum.Material.SmoothPlastic,
		parent = shop,
	})
	for _, sx in { -1, 1 } do
		Build.part({
			name = "ShopSide",
			size = Vector3.new(1, wallH, shopD),
			cframe = CFrame.new(shopCentre + Vector3.new(sx * (shopW * 0.5 - 0.5), 1 + wallH * 0.5, 0)),
			color = body,
			material = Enum.Material.SmoothPlastic,
			parent = shop,
		})
	end

	--[[
		The back of the shop, dressed.

		The storefront faces the road, which means the forecourt — where the
		player spends the entire run — looks at the rear. Bare, that rear was
		the biggest white rectangle in the game. A service door and two high
		windows are what the back of a real shop wears, and they are enough
		to make it a building instead of a backdrop.
	]]
	-- The wall's outer face, not its centre: parts hung on the middle of a
	-- one-stud wall are inside it, which is where the door and both
	-- windows spent their first outing.
	local backZ = shopCentre.Z + shopD * 0.5 + 0.5
	--[[
		Painted, not the model's own.

		The door model is a panelled wooden one in a teal frame, which is The
		House's trim colour and The House's front door — and it arrived here
		with the texture still on it, because a tint on a textured mesh only
		shades what is already there. So the back of a red-and-cream filling
		station had a suburban front door on it, twice. Untextured it keeps
		its panels and takes the dark grey a service door is painted.
	]]
	Build.part({
		name = "ShopBackDoorFrame",
		size = Vector3.new(7.6, 10.2, 0.5),
		cframe = CFrame.new(shopCentre.X, 1 + 4.6, backZ + 0.15),
		color = dark,
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = shop,
	})
	Build.mesh({
		prop = "Door",
		name = "ShopBackDoor",
		size = Vector3.new(6.5, 9.2, 0.9),
		-- Centred, because at a quarter of the width it stood underneath
		-- the left-hand window.
		cframe = CFrame.new(shopCentre.X, 1 + 4.6, backZ + 0.35),
		untextured = true,
		--- A shade up from the frame around it, or the two read as one hole.
		color = Color3.fromRGB(104, 108, 112),
		parent = shop,
	})
	Build.part({
		name = "ShopBackHandle",
		size = Vector3.new(0.4, 2.4, 0.5),
		cframe = CFrame.new(shopCentre.X + 2.4, 1 + 4.6, backZ + 0.85),
		color = Palette.color(Palette.station.trim),
		material = Enum.Material.Metal,
		canCollide = false,
		parent = shop,
	})
	for _, sx in { -1, 1 } do
		local wx = shopCentre.X + sx * shopW * 0.28
		Build.part({
			name = "ShopBackWindowFrame",
			size = Vector3.new(8.6, 3.0, 0.5),
			cframe = CFrame.new(wx, 1 + wallH - 2.6, backZ + 0.15),
			color = dark,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = shop,
		})
		Build.part({
			name = "ShopBackWindow",
			size = Vector3.new(8, 2.4, 0.6),
			cframe = CFrame.new(wx, 1 + wallH - 2.6, backZ + 0.35),
			color = Palette.color(Palette.station.glass),
			material = Enum.Material.Glass,
			-- Barely see-through. The forecourt looks at these from the
			-- north with an unlit stockroom behind them, and at a third
			-- clear that is not a window, it is a black rectangle.
			transparency = 0.1,
			canCollide = false,
			parent = shop,
		})
	end

	--[[
		The storefront: pier, knee wall and glass, a door bay in the middle,
		and a continuous header over the lot of it. Glass rather than the
		house's windows because a shop front is one sheet of it, and the knee
		wall is what stops the glass reading as a hole.
	]]
	local pierW, glassW, doorBayW = 9, 21, 12
	for _, sx in { -1, 1 } do
		Build.part({
			name = "ShopPier",
			size = Vector3.new(pierW, wallH, 1),
			cframe = CFrame.new(shopCentre.X + sx * (shopW - pierW) * 0.5, 1 + wallH * 0.5, frontZ),
			color = body,
			material = Enum.Material.SmoothPlastic,
			parent = shop,
		})
		local glassX = shopCentre.X + sx * (doorBayW * 0.5 + glassW * 0.5)
		Build.part({
			name = "ShopKnee",
			size = Vector3.new(glassW, 1.8, 1),
			cframe = CFrame.new(glassX, 1.9, frontZ),
			color = body,
			material = Enum.Material.SmoothPlastic,
			parent = shop,
		})
		Build.part({
			name = "ShopGlass",
			size = Vector3.new(glassW, 6.4, 0.6),
			cframe = CFrame.new(glassX, 2.8 + 3.2, frontZ),
			color = Palette.color(Palette.station.glass),
			material = Enum.Material.Glass,
			transparency = 0.35,
			parent = shop,
		})
		-- Mullions, so the glass is a shopfront rather than a gap.
		for m = -1, 1 do
			Build.part({
				name = "Mullion",
				size = Vector3.new(0.5, 6.4, 0.8),
				cframe = CFrame.new(glassX + m * glassW / 3, 2.8 + 3.2, frontZ),
				color = trim,
				material = Enum.Material.SmoothPlastic,
				canCollide = false,
				parent = shop,
			})
		end
	end
	Build.part({
		name = "ShopHeader",
		size = Vector3.new(shopW, wallH - 8.2, 1),
		cframe = CFrame.new(shopCentre.X, 1 + 8.2 + (wallH - 8.2) * 0.5, frontZ),
		color = body,
		material = Enum.Material.SmoothPlastic,
		parent = shop,
	})
	Build.mesh({
		prop = "Door",
		name = "ShopDoor",
		size = Vector3.new(7, 9.2, 0.9),
		cframe = CFrame.new(shopCentre.X, 1 + 4.6, frontZ),
		-- The same teal front door as the one round the back. See there.
		untextured = true,
		color = dark,
		parent = shop,
	})

	-- Flat roof with the same red band as the canopy, and the badge over the
	-- door where a shop wears its name.
	Build.part({
		name = "ShopRoof",
		size = Vector3.new(shopW + 3, 1.6, shopD + 3),
		cframe = CFrame.new(shopCentre + Vector3.new(0, 1 + wallH + 0.8, 0)),
		color = trim,
		material = Enum.Material.SmoothPlastic,
		parent = shop,
	})
	for _, sz in { -1, 1 } do
		Build.part({
			name = "ShopFascia",
			size = Vector3.new(shopW + 3.6, 2.4, 0.9),
			cframe = CFrame.new(shopCentre + Vector3.new(0, 1 + wallH + 0.9, sz * (shopD * 0.5 + 1.55))),
			color = fascia,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = shop,
		})
	end
	for _, sx in { -1, 1 } do
		Build.part({
			name = "ShopFascia",
			size = Vector3.new(0.9, 2.4, shopD + 3.6),
			cframe = CFrame.new(shopCentre + Vector3.new(sx * (shopW * 0.5 + 1.8), 1 + wallH + 0.9, 0)),
			color = fascia,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = shop,
		})
	end
	stationEmblem(CFrame.new(shopCentre.X, 1 + wallH + 0.9, frontZ - 2.1), 4.4, shop)

	-- Stock on show through the glass: the counter and a couple of sacks,
	-- because an empty lit box reads as an unfinished room.
	Build.mesh({
		prop = "Counter",
		name = "ShopCounter",
		size = Vector3.new(22, 5.5, 4.6),
		cframe = CFrame.new(shopCentre + Vector3.new(-14, 1 + 2.75, shopD * 0.5 - 3.4)),
		parent = shop,
	})
	for index, offset in { Vector3.new(16, 0, 6), Vector3.new(20, 0, 2) } do
		Build.mesh({
			prop = "Sack",
			name = "ShopSack",
			size = Vector3.new(3, 3.6, 3.2),
			cframe = CFrame.new(shopCentre + offset + Vector3.new(0, 1 + 1.8, 0))
				* CFrame.Angles(0, index * 1.1, 0),
			canCollide = false,
			parent = shop,
		})
	end

	----------------------------------------------------------------
	-- The yards behind, which were bare concrete with weeds on it.
	----------------------------------------------------------------

	--[[
		Everything built on this property stood on the front thirty studs.

		The forecourt has a canopy, two pump islands, a glazed shop and a
		sign at the kerb; behind it the back lot and the storage yard are
		five hundred studs of empty slab, and counted against the other two
		properties this one had the fewest parts on the largest ground. From
		anywhere past the canopy it read as a field with a fence round it.

		What a working yard has is paint and things stacked in it, and both
		are cheap. The bays are flat parts that bury nothing — paint does not
		hide a tile, so the weeds still grow through it and the markings come
		out from under them as you clear, which is the one place on the
		property where finishing a patch shows you something.
	]]
	local yard = Build.folder("Yard", station)

	local function rectOf(id: string): Types.Rect?
		for _, section in world.sections do
			if section.id == id then
				return section.rect
			end
		end
		return nil
	end

	local paint = Palette.color(Palette.court.line)
	local function marking(at: Vector3, size: Vector3)
		Build.part({
			name = "BayLine",
			size = size,
			-- Clear of the slab rather than flush with it: two surfaces at
			-- the same height flicker against each other, which is what the
			-- tennis court's apron was doing.
			cframe = CFrame.new(at + Vector3.new(0, 0.2, 0)),
			color = paint,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			castShadow = false,
			parent = yard,
		})
	end

	--- Parking bays across the back lot, with a stop line along the head.
	local backLot = rectOf("back_lot")
	if backLot then
		local BAY, DEPTH, BAYS = 11, 22, 10
		local low = WorldService.tilePointFlat(backLot.x + 3, backLot.z + 3)
		for index = 0, BAYS do
			marking(low + Vector3.new(index * BAY, 0, DEPTH * 0.5), Vector3.new(0.7, 0.25, DEPTH))
		end
		marking(low + Vector3.new(BAYS * BAY * 0.5, 0, 0), Vector3.new(BAYS * BAY, 0.25, 0.7))

		--- Lamp standards, one to a corner of the bays.
		for _, sx in { 0, BAYS * BAY } do
			for _, sz in { -6, DEPTH + 6 } do
				local at = low + Vector3.new(sx, 0, sz)
				Build.part({
					name = "LampPost",
					size = Vector3.new(1, 22, 1),
					cframe = CFrame.new(at + Vector3.new(0, 11, 0)),
					color = dark,
					material = Enum.Material.Metal,
					parent = yard,
				})
				Build.part({
					name = "LampHead",
					size = Vector3.new(5, 1.2, 2.6),
					cframe = CFrame.new(at + Vector3.new(0, 22.2, 0)),
					color = trim,
					material = Enum.Material.SmoothPlastic,
					canCollide = false,
					parent = yard,
				})
			end
		end
	end

	--[[
		Containers in the storage yard, which is what a storage yard is for.

		Solid, so the tiles under them are swept out of the section's total
		the way the shed's are — you cannot mow under a shipping container and
		the property should not ask you to.
	]]
	local storage = rectOf("storage_yard")
	if storage then
		local shells = {
			{ colour = fascia, at = Vector3.new(-14, 0, -30), yaw = 0 },
			{ colour = Palette.color(Palette.court.tarmac), at = Vector3.new(10, 0, -6), yaw = math.rad(8) },
			{ colour = Palette.color(Palette.props.binLid), at = Vector3.new(10, 11.6, -6), yaw = math.rad(8) },
			{ colour = dark, at = Vector3.new(-10, 0, 26), yaw = math.rad(-12) },
		}
		local centre = WorldService.tilePointFlat(storage.x + storage.w * 0.5, storage.z + storage.d * 0.5)
		for _, shell in shells do
			local basis = CFrame.new(centre + shell.at + Vector3.new(0, 5.8, 0)) * CFrame.Angles(0, shell.yaw, 0)
			Build.part({
				name = "Container",
				size = Vector3.new(11, 11.5, 26),
				cframe = basis,
				color = shell.colour,
				material = Enum.Material.CorrodedMetal,
				parent = yard,
			})
			-- The door end, and a rib either side of it, so it is a container
			-- rather than a painted box.
			Build.part({
				name = "ContainerDoors",
				size = Vector3.new(11.2, 9.5, 0.6),
				cframe = basis * CFrame.new(0, 0, 13),
				color = dark,
				material = Enum.Material.CorrodedMetal,
				canCollide = false,
				parent = yard,
			})
			for _, edge in { -1, 1 } do
				Build.part({
					name = "ContainerRib",
					--- Inside the shell's own top and bottom faces, not level
					--- with them: at five point two the rail's top face and
					--- the container's were one plane.
					size = Vector3.new(11.3, 1.1, 1),
					cframe = basis * CFrame.new(0, edge * 5.05, 0),
					color = dark,
					material = Enum.Material.CorrodedMetal,
					canCollide = false,
					parent = yard,
				})
			end
			--[[
				Corrugation down the sides, and a casting at each corner.

				The doors and the two rails were meant to be what stopped this
				reading as a painted box, and from the door end they are. From
				either side — which is the side you walk past, because the
				yard is longer than it is wide — there was nothing at all:
				eleven by twenty-six studs of flat rust, and the four of them
				stood in the grass like coloured crates the size of a bus.

				The corrugation is the whole silhouette of a container. So is
				the casting at each corner, which is the one part that is
				always a different colour from the paint because it is the
				part that gets hit.
			]]
			local FINS = 10
			for _, face in { -1, 1 } do
				for fin = 0, FINS do
					Build.part({
						name = "ContainerFin",
						size = Vector3.new(0.5, 9.4, 0.8),
						cframe = basis
							* CFrame.new(face * 5.5, 0, -11.5 + 23 * fin / FINS),
						color = shell.colour,
						material = Enum.Material.CorrodedMetal,
						canCollide = false,
						parent = yard,
					})
				end
			end
			for _, corner in {
				Vector3.new(-1, -1, -1),
				Vector3.new(1, -1, -1),
				Vector3.new(-1, 1, -1),
				Vector3.new(1, 1, -1),
				Vector3.new(-1, -1, 1),
				Vector3.new(1, -1, 1),
				Vector3.new(-1, 1, 1),
				Vector3.new(1, 1, 1),
			} do
				Build.part({
					name = "ContainerCasting",
					size = Vector3.new(2.4, 2.2, 2.4),
					cframe = basis
						* CFrame.new(corner.X * 4.6, corner.Y * 4.9, corner.Z * 12),
					color = dark,
					material = Enum.Material.CorrodedMetal,
					canCollide = false,
					parent = yard,
				})
			end
			--- Two leaves and the bars that hold them shut.
			for _, bar in { -3.4, -1.2, 1.2, 3.4 } do
				Build.part({
					name = "ContainerBar",
					size = Vector3.new(0.7, 9.2, 0.7),
					cframe = basis * CFrame.new(bar, 0, 13.4),
					color = dark,
					material = Enum.Material.CorrodedMetal,
					canCollide = false,
					parent = yard,
				})
			end
		end
	end

	----------------------------------------------------------------
	-- The road sign at the kerb, badge facing both ways.
	----------------------------------------------------------------
	local signAt = Vector3.new(spawnAt.X + 22, 0, 4)
	Build.part({
		name = "SignPole",
		size = Vector3.new(1.2, 16, 1.2),
		cframe = CFrame.new(signAt + Vector3.new(0, 8, 0)),
		color = dark,
		material = Enum.Material.Metal,
		parent = station,
	})
	stationEmblem(CFrame.new(signAt + Vector3.new(0, 16.5, -0.4)), 7, station)
	stationEmblem(
		CFrame.new(signAt + Vector3.new(0, 16.5, 0.4)) * CFrame.Angles(0, math.pi, 0),
		7,
		station
	)
end

--[[
	The shed: a workshop you walk into, not a signpost.

	Plank ceiling, pegboard wall, a run of counters, a hanging lantern and the
	stock floating above the counter with loud labels. Almost every purchase in
	the game happens here, so it is worth being a room.
]]
local function buildShed(world: Types.WorldDef, parent: Folder): BasePart
	local centre = WorldService.tilePointFlat(world.shed.x, world.shed.z)
	local shed = Build.folder("Shed", parent)

	local width, depth, height = 30, 26, 16

	--[[
		The shed itself, as one model.

		It used to be a concrete floor, three concrete slabs for walls and
		twelve planks laid across the top — a box you stood inside. The model
		has its walls, its roof and its open front already, so all that is left
		to build is the floor you stand on and the counter you buy from.
	]]
	Build.part({
		name = "Floor",
		size = Vector3.new(width, 1, depth),
		--[[
			A shade proud of the model's own base.

			The shed model's part is a one-stud box sitting at the same
			height as this floor, so its top face and the floor's were on
			the same plane and flickered in the middle of the shop — the
			one square of ground every player in every world walks over.
		]]
		cframe = CFrame.new(centre + Vector3.new(0, 0.56, 0)),
		color = Palette.color(Palette.ground.stoneDark),
		material = Enum.Material.Concrete,
		parent = shed,
	})

	--[[
		A plinth, where the ground under the shed has been cut away.

		The shed stands on open ground between the sections, but a sunken
		one reaches under its floor: on both The House and The Mansion the
		back of the shed hung over an eighteen-stud drop with nothing
		holding it up. A building at the edge of a sunken yard stands on a
		retaining wall, so this fills whatever the cut took away.
	]]
	local lowest = 0
	local halfW, halfD = math.ceil(width / TILE / 2), math.ceil(depth / TILE / 2)
	for tz = world.shed.z - halfD, world.shed.z + halfD do
		for tx = world.shed.x - halfW, world.shed.x + halfW do
			lowest = math.min(lowest, Worlds.elevationAt(world, tx, tz))
		end
	end
	if lowest < 0 then
		Build.part({
			name = "ShedPlinth",
			size = Vector3.new(width, -lowest, depth),
			cframe = CFrame.new(centre + Vector3.new(0, lowest * 0.5, 0)),
			color = Palette.color(Palette.ground.stoneDark),
			material = Enum.Material.Concrete,
			parent = shed,
		})
	end

	--[[
		The shell, stood on the floor rather than in the air above it.

		`Build.mesh` lifts a mesh by half the difference between the model and
		the collision box under it, so that a box shorter than the model does
		not leave the model half buried. That rule expects the caller to have
		placed the part at half the box's height — its base on the ground.

		This asked for a one-stud box and then placed it at half the *model's*
		height, ten studs up, so the lift was applied to something that was
		already where it belonged and the shed's roof and walls drew nine and
		a half studs above the floor, hanging over the yard with daylight
		underneath. Moving the shed to the front verge is what made it
		obvious; it had been doing this out of sight in the back garden.

		Every other mesh in the world that carries a lift places its part the
		way the rule expects — thirty-six of thirty-seven, checked in the
		running game — so the caller is what changes here, not the rule.

		No collision on the shell either: the walls the player can bump into
		stay as thin slabs, so the open front is genuinely open and nobody
		gets caught on a roof overhang.
	]]
	local shellBox = Vector3.new(1, 1, 1)
	Build.mesh({
		prop = "Shed",
		name = "Shell",
		size = Vector3.new(width + 4, height + 4, depth + 4),
		collisionSize = shellBox,
		cframe = CFrame.new(centre + Vector3.new(0, shellBox.Y * 0.5, 0)),
		canCollide = false,
		parent = shed,
	})

	-- Thin collision walls behind the model, leaving the front open.
	local walls = {
		{ Vector3.new(0, height * 0.5, depth * 0.5), Vector3.new(width, height, 1.2) },
		{ Vector3.new(-width * 0.5, height * 0.5, 0), Vector3.new(1.2, height, depth) },
		{ Vector3.new(width * 0.5, height * 0.5, 0), Vector3.new(1.2, height, depth) },
	}
	for _, wall in walls do
		Build.part({
			name = "Wall",
			size = wall[2],
			cframe = CFrame.new(centre + wall[1]),
			color = Palette.color(Palette.props.shed),
			material = Enum.Material.Concrete,
			transparency = 1,
			parent = shed,
		})
	end

	-- Counter run along the back and one side.
	local counter = Build.mesh({
		prop = "Counter",
		name = "ShedCounter",
		size = Vector3.new(width - 4, 6, 5),
		collisionSize = Vector3.new(width - 4, 6, 5),
		cframe = CFrame.new(centre + Vector3.new(0, 3, depth * 0.5 - 4)),
		parent = shed,
	})
	Build.mesh({
		prop = "Counter",
		name = "CounterTop",
		size = Vector3.new(width - 3.4, 0.7, 5.6),
		cframe = CFrame.new(centre + Vector3.new(0, 6.3, depth * 0.5 - 4)),
		color = Palette.color(Palette.fence.picket),
		parent = shed,
	})
	-- No drawer fronts or handles: the counter model has its own cabinetry, and
	-- the old ones were drawn on top of it.

	-- Pegboard on the side wall with tools hung on it.
	Build.part({
		name = "Pegboard",
		size = Vector3.new(0.5, 10, depth - 8),
		cframe = CFrame.new(centre + Vector3.new(width * 0.5 - 1.2, 9, 0)),
		color = Palette.color(Palette.rgb(206, 186, 146)),
		material = Enum.Material.WoodPlanks,
		canCollide = false,
		parent = shed,
	})
	for index = 0, 2 do
		Build.mesh({
			prop = "HungTools",
			name = "HungTool",
			size = Vector3.new(2.2, 5, 1),
			collisionSize = Vector3.new(1.2, 1.6, 6),
			cframe = CFrame.new(centre + Vector3.new(width * 0.5 - 2.2, 11 - index * 3.4, -4 + index * 4))
				* CFrame.Angles(0, math.rad(90), 0),
			canCollide = false,
			parent = shed,
		})
	end

	-- Hanging lantern, the warm point of light in the room.
	local lantern = Build.mesh({
		prop = "Lantern",
		name = "Lantern",
		size = Vector3.new(2.4, 3, 2.4),
		cframe = CFrame.new(centre + Vector3.new(0, height - 4, -2)),
		color = Palette.color(Palette.ui.tips),
		canCollide = false,
		parent = shed,
	})
	local glow = Instance.new("PointLight")
	glow.Color = Palette.color(Palette.ui.tips)
	glow.Range = 26
	glow.Brightness = 2
	glow.Parent = lantern

	--[[
		Floating stock above the counter, with loud labels.

		Spacing, label width and label height all matter together here. Three
		nine-stud-wide signs eight and a half studs apart overlap even head on,
		and from any angle at all they slid straight through each other into one
		unreadable smear — "Leaf BloweInfinite BUpgrade Bag". The labels are now
		narrower than the gap between them, and the middle one rides higher, so
		no two can collide from any direction you can stand in.

		Both heights are then bounded by something the stagger did not account
		for: the shed's own roof. Measured with markers along the counter, the
		underside of the front lintel is at fourteen and a half studs, and the
		middle sign was hung with its centre at fourteen point seven — so the
		one item in the shop meant to be the loudest thing in it was drawn
		entirely inside the roof and had never once been seen. The pair now
		use the band beneath the lintel: shorter boxes, and a smaller step
		between them, which costs nothing because at eight studs wide every
		one of these labels is limited by its width and not its height.
	]]
	local displays = {
		{ label = "Upgrade Bag", prop = "Sack", rainbow = false, color = Palette.rgb(96, 206, 140), offset = -10, lift = 2.1 },
		{ label = "Infinite Bag", prop = "Sack", rainbow = true, color = Palette.ui.tips, offset = 0, lift = 4.0 },
		{ label = "Leaf Blower", prop = "LeafBlower", rainbow = false, color = Palette.rgb(120, 168, 220), offset = 10, lift = 2.1 },
	}
	for _, display in displays do
		-- The stock is the thing it sells, not a coloured cube standing for it.
		local item = Build.mesh({
			prop = display.prop,
			name = display.label,
			size = Vector3.new(4.5, 4.5, 4.5),
			collisionSize = Vector3.new(4, 4, 4),
			cframe = CFrame.new(centre + Vector3.new(display.offset, 9.5, depth * 0.5 - 4)),
			canCollide = false,
			parent = shed,
		})
		--[[
			Stood out in front of the shed rather than inside it.

			Hung on the stock where it sits, these were cut off by the shed's
			own frame: "Upgrade Bag" read as "pgrade Bag" and "Leaf Blower" as
			"Leaf Blow", each losing exactly what stuck out past the opening.
			Confirmed by hiding the shell, which made both whole. Five studs
			forward clears the frame from every angle you can stand at, and
			six and a half wide leaves the pair either side clear of the
			middle one.
		]]
		local sign = Build.billboard(item, UDim2.fromScale(6.5, 1.5), display.lift, 90, 5)
		if display.rainbow then
			Build.rainbowText(sign, display.label, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), 1.2)
		else
			Build.label(sign, display.label, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), 1.2)
		end
	end

	--[[
		Clear of the roof, rather than halfway through it.

		Hung at fourteen studs above the counter this sign straddled the
		roofline: "THE SHED" cleared it and "Tools & Upgrades" — the line that
		says what the building is for — sat behind the shingles and was never
		visible from anywhere on the property. Seventeen puts the whole board
		above the ridge, which is where a shop hangs its sign anyway.
	]]
	local gui = Build.billboard(counter, UDim2.fromScale(13, 3.6), 17, 280)
	Build.label(gui, "THE SHED", UDim2.fromScale(1, 0.56), UDim2.fromScale(0, 0), 2.4)
	Build.label(gui, "Tools & Upgrades", UDim2.fromScale(1, 0.4), UDim2.fromScale(0, 0.58), 1.2)

	return counter
end

local function buildTrailer(world: Types.WorldDef, parent: Folder): BasePart
	local centre = WorldService.tilePointFlat(world.trailer.x, world.trailer.z)
	local trailer = Build.folder("Trailer", parent)

	--[[
		One trailer, at the size a trailer is.

		The old numbers drew it twenty-four studs wide by nine tall — with the
		model's long axis turned sideways, so it was also stretched three and a
		half times across its width — which made the thing you dump your bag
		into bigger than the gas station's shop and taller than its pumps. The
		size is in the model's own proportions now, and the quarter turn is in
		the CFrame instead, parking it along the kerb the way a trailer parks.
	]]
	local bed = Build.mesh({
		prop = "Trailer",
		name = "Bed",
		size = Vector3.new(9.9, 6.1, 15),
		collisionSize = Vector3.new(7, 4, 14),
		cframe = CFrame.new(centre + Vector3.new(0, 2, 0)) * CFrame.Angles(0, math.rad(90), 0),
		parent = trailer,
	})

	local gui = Build.billboard(bed, UDim2.fromScale(12, 3.2), 6, 300)
	Build.label(gui, "TRAILER", UDim2.fromScale(1, 0.55), UDim2.fromScale(0, 0), 2.2)
	Build.label(gui, "Dump your bag here", UDim2.fromScale(1, 0.4), UDim2.fromScale(0, 0.58), 1.2)

	bed.Name = "TrailerBed"
	return bed
end

--[[
	Where a section's front door stands: a point on the edge named by
	`gateSide` (south by default), and the CFrame that faces it outward, away
	from the section, so a gate built in it reads from the approach.
]]
local function gateBasis(section: Types.ZoneDef): CFrame
	local r = section.rect
	local side = section.gateSide or "south"
	if side == "north" then
		local at = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z + r.d)
		return CFrame.new(at) * CFrame.Angles(0, math.pi, 0)
	elseif side == "east" then
		local at = WorldService.tilePointFlat(r.x + r.w, r.z + r.d * 0.5)
		return CFrame.new(at) * CFrame.Angles(0, math.rad(90), 0)
	elseif side == "west" then
		local at = WorldService.tilePointFlat(r.x, r.z + r.d * 0.5)
		return CFrame.new(at) * CFrame.Angles(0, math.rad(-90), 0)
	end
	local at = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z)
	return CFrame.new(at)
end

--[[
	One sign per paid section, naming it.

	The price and the prompt live on the gate's door now. This comment used to
	say the sign carried them, and when they moved the sign was left as it is
	built here: a seven-stud hanging board beside every paid gate with nothing
	written on it. Walked up to in the gas station, that was a blank plank next
	to a door that says "Unlock $75.00" — the one place the property could say
	*what* you were buying, and it did not. The board carries the section's name.
]]
local function buildSectionSigns(world: Types.WorldDef, parent: Folder): { [string]: BasePart }
	local signs: { [string]: BasePart } = {}
	local folder = Build.folder("ZoneSigns", parent)

	for _, section in world.sections do
		-- A rooftop is earned and a garage is found, so neither gets a price tag.
		-- Signs also stand on the ground plane rather than the section's own floor,
		-- so a basement's sign is at the top of its stairs and not sealed inside.
		if section.cost > 0 and Worlds.unlockKind(section) == "cash" then
			local basis = gateBasis(section)

			local post = Build.mesh({
				prop = "Sign",
				name = section.id,
				size = Vector3.new(7, 12, 1.4),
				collisionSize = Vector3.new(1, 12, 1),
				--[[
					Beside the gate rather than on top of it, and on the side
					you are standing when you decide.

					`gateBasis` looks *into* the section it gates, so its -Z
					is the far side of the door and its +Z is the approach.
					This read -2 and so put the board two studs past the gate,
					facing away from anyone walking up to it: the one thing on
					the property that says what eighteen dollars buys was only
					legible once you had already bought it. From the backyard
					there was a shut door with a price on it and nothing else.

					The half turn is the other half of the same mistake — the
					post inherits the basis' facing, which is inwards too. It
					is applied after the offset so the offset stays in the
					gate's frame and the board keeps the side of the doorway
					it was put on.
				]]
				cframe = basis * CFrame.new(8, 6, 2) * CFrame.Angles(0, math.pi, 0),
				canCollide = false,
				parent = folder,
			})
			post:SetAttribute("ZoneId", section.id)

			--[[
				The name goes on the board, not in the air above it.

				`Build.billboard` lifts its text clear of whatever it hangs
				on, which is right for a price floating over a door and wrong
				here. This sign is a plank hanging from a crossbar, and the
				lift put the writing exactly on the plank's top edge, where
				the crossbar cuts through it and whatever tree stands behind
				the sign shows through it. Every paid section had a blank
				board with its name drawn in the air somewhere behind.

				So the writing is adorned to a marker sitting on the board's
				own face, half a stud proud of the wood. Going through the
				sign's CFrame rather than a billboard offset keeps it honest:
				the sign turns to face whichever way you walk up to it, and
				`post.CFrame * CFrame.new(...)` turns with it, whereas the
				two kinds of studs-offset differ in exactly this case.
			]]
			--[[
				Painted on the plank, not floated in front of it.

				This was a marker standing a stud and a half proud of the
				wood with a billboard on it, and a billboard turns to face
				the camera — so the moment you looked at the sign from
				anywhere but square on, its far half swung behind the plank
				and the name lost a letter at each end. Walking up the path
				to it, "Pool Deck" read "ool Dec". Confirmed by hiding the
				post, which made the name whole. No clearance fixes that: at
				a shallow enough angle any width is too wide.

				A plate sitting just proud of the plank's front face, with
				the name painted onto it, cannot be cut by the plank because
				it never leaves its plane. The plate faces the same way the
				sign does, which is the way the player walks up to it.
			]]
			--[[
				Written on both sides, because one side was the wrong one.

				The plank carried a single painted plate on the post's front
				face, on the reasoning that `gateBasis` looks into the section
				and the half turn above therefore leaves the sign meeting
				whoever walks up to it. Measured on the Mansion, it does not:
				the Orangery's post ends up facing +Z, into the section, so
				the one board on the property that says what a hundred and
				forty dollars buys was blank from the lawn and legible only
				from inside the glasshouse you had not paid for yet. Two
				sections of the first property had it the right way round and
				one did not, which is how it survived.

				A hanging board is double sided in life and there is no reason
				for this one not to be. Painted both ways it does not matter
				which way the basis happens to point, on this property or on
				the next one somebody adds.
			]]
			for _, side in { { forward = -0.78, face = Enum.NormalId.Front }, { forward = 0.78, face = Enum.NormalId.Back } } do
				local plate = Build.part({
					name = "Face",
					-- The plank inside the seven-stud envelope, measured
					-- against the mesh: a little off the post's centre, and
					-- just proud of the wood so the paint does not fight it
					-- for the same pixels.
					size = Vector3.new(4.9, 1.7, 0.1),
					cframe = post.CFrame * CFrame.new(0.6, 0, side.forward),
					color = Color3.fromRGB(255, 255, 255),
					material = Enum.Material.SmoothPlastic,
					transparency = 1,
					canCollide = false,
					parent = post,
				})
				plate.CastShadow = false

				local label = Build.painted(plate, side.face, 0.92)
				label.Text = section.name
				-- Paint on pale wood, not a label floating over a bush: the
				-- white and its black stroke belong to the things that hang
				-- in the air.
				label.TextColor3 = Color3.fromRGB(78, 52, 30)
			end

			signs[section.id] = post
		end
	end

	return signs
end

--[[
	Builds everything a section needs beyond its tiles.

	Rooms get walls, the pool gets water, the maze gets hedges, and every section
	gets its share of clutter. Only `house` properties get the full treatment;
	the big open lots stay open, which is where the wide-deck mowers earn their
	price.
]]
--[[
	Upgrade stations: the shop, standing in the world.

	One board per upgrade line, in a row in front of the shed. The board shows
	the buyer's own current level, the next one, and the price — text the client
	fills in locally, because levels are per-player and one shared sign cannot
	be right for two people. The prompt on the board is the purchase.

	This is most of what "the shed" means now: the journal remains for reading
	quests and prices at a distance, but buying is something you walk up and do.
]]
local function buildUpgradeStations(world: Types.WorldDef, parent: Folder)
	local folder = Build.folder("UpgradeStations", parent)
	local centre = WorldService.tilePointFlat(world.shed.x, world.shed.z)

	-- A row across the shed's open front, facing the lawn.
	local count = #Upgrades.list
	-- Boards are seven wide, so seven apart left them edge to edge and their
	-- billboards ran into each other: "ReserveFortune" across two signs.
	local spacing = 9.5
	local startX = -(count - 1) * spacing * 0.5

	for index, def in Upgrades.list do
		local at = centre + Vector3.new(startX + (index - 1) * spacing, 0, -16)

		Build.mesh({
			prop = "Column",
			name = "Post",
			size = Vector3.new(0.8, 5, 0.8),
			cframe = CFrame.new(at + Vector3.new(0, 2.5, 0)),
			color = Palette.color(Palette.fence.rail),
			transparency = 1,
			parent = folder,
		})

		local board = Build.mesh({
			prop = "ShopBoard",
			name = def.id,
			size = Vector3.new(7, 8, 1.2),
			collisionSize = Vector3.new(6, 3.4, 0.6),
			cframe = CFrame.new(at + Vector3.new(0, 4.6, 0)),
			parent = folder,
		})
		board:SetAttribute("UpgradeId", def.id)

		--[[
			A badge on the board, because the boards are otherwise identical.

			Every station is the same `ShopBoard` mesh, which carries a raised
			blue hammer on a shield. Five of them stand a pace apart in front
			of the shed, so the row read as one sign repeated five times: the
			only thing telling Reserve from Fortune was the words floating
			above them, which you cannot see at all from the side.

			The badge is a disc rather than a patch. Matching the shield's
			orange would need to be exact or it reads as a repair, and a
			cream roundel with the line's own icon on it reads as something
			pinned to the board on purpose. It stands a little clear of the
			mesh so the hammer behind it is covered rather than poking out.
		]]
		if def.icon then
			local badge = Build.part({
				name = "Badge",
				size = Vector3.new(3.4, 3.4, 0.2),
				cframe = CFrame.new(at + Vector3.new(0, 7, -0.85)),
				color = Color3.fromRGB(246, 236, 210),
				material = Enum.Material.SmoothPlastic,
				canCollide = false,
				parent = folder,
			})
			badge.Shape = Enum.PartType.Cylinder
			-- A cylinder's flat ends face along its X, so it is turned to
			-- look at the lawn the way the boards do.
			badge.CFrame = CFrame.new(at + Vector3.new(0, 7, -0.85))
				* CFrame.Angles(0, math.rad(90), 0)
			badge.Size = Vector3.new(0.2, 3.4, 3.4)

			local face = Instance.new("SurfaceGui")
			-- Turned by ninety degrees, the cylinder's flat end that looks at
			-- the lawn is its Right. On Left the badge came out blank.
			face.Face = Enum.NormalId.Right
			face.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			face.PixelsPerStud = 64
			face.LightInfluence = 0
			face.Parent = badge

			local picture = Instance.new("ImageLabel")
			picture.Size = UDim2.fromScale(0.78, 0.78)
			picture.Position = UDim2.fromScale(0.5, 0.5)
			picture.AnchorPoint = Vector2.new(0.5, 0.5)
			picture.BackgroundTransparency = 1
			picture.Image = def.icon
			picture.ScaleType = Enum.ScaleType.Fit
			picture.Parent = face
		end

		local prompt = Build.prompt(board, "Buy", def.name, 9)
		prompt.Triggered:Connect(function(player: Player)
			stationSignal:Fire(player, def.id)
		end)
	end
end

--[[
	A blue door with a price on it, for each section bought with run cash.

	The door is the shop: the price hangs on the wood, the prompt is on the
	handle, and paying is something you do standing in front of it with money
	swept off the lawn. It stands at the middle of the section's near edge —
	the same edge the signs use — and is destroyed the moment the section opens.
]]
--[[
	The frame it hangs in, by property.

	The door is the same door everywhere on purpose — it is the shop, and a
	player should know one when they see one. Its frame was the same
	everywhere too, and that is a different thing: a rustic timber arch on
	two turned posts, in the tan The House fences its garden with. Standing
	in the doorway of a concrete wash bay it read as a garden trellis
	somebody had wheeled onto a filling station, and it did the same on the
	estate and in the churchyard. Same shape, the property's own metal.
]]
local CASH_FRAME: {
	[string]: { colour: Types.Color3Like, leaf: Types.Color3Like?, material: Enum.Material },
} = {
	--- The one it was built as, on the property it was built for.
	house = { colour = Palette.fence.rail, material = Enum.Material.WoodPlanks },
	estate = { colour = Palette.estate.iron, leaf = Palette.estate.lead, material = Enum.Material.Metal },
	lot = { colour = Palette.station.dark, leaf = Palette.station.trim, material = Enum.Material.Metal },
	churchyard = {
		colour = Palette.churchyard.iron,
		leaf = Palette.churchyard.granite,
		material = Enum.Material.Metal,
	},
}

local function buildCashGates(world: Types.WorldDef, parent: Folder): { [string]: Model }
	local gates: { [string]: Model } = {}
	local folder = Build.folder("CashGates", parent)
	local frame = CASH_FRAME[world.style or "house"] or CASH_FRAME.house
	local frameColour = Palette.color(frame.colour)
	--- Timber keeps the model's own grain; painted metal does not.
	local bare = frame.material ~= Enum.Material.WoodPlanks
	--[[
		The leaves a shade up from the frame, or there is no door in it.

		The first pass repainted the posts and the beam and left the door
		alone, which was worse than leaving all three: the model's arched
		surround is part of the *door*, so a wash bay ended up with a wooden
		arch hanging between two steel posts. Either the whole gate is the
		property's or none of it is.
	]]
	local leafColour = if frame.leaf then Palette.color(frame.leaf) else nil

	for _, section in world.sections do
		if Worlds.unlockKind(section) ~= "cash" then
			continue
		end

		local basis = gateBasis(section)

		local gate = Instance.new("Model")
		gate.Name = section.id
		gate:SetAttribute("SectionId", section.id)
		gate.Parent = folder

		-- A blue door in a wooden arch. Opening simply removes the model, so
		-- the door does not need hinges — only presence.
		Build.mesh({
			prop = "Gate",
			name = "Arch",
			size = Vector3.new(14, 2, 2),
			cframe = basis * CFrame.new(0, 11, 0),
			untextured = bare,
			color = frameColour,
			parent = gate,
		})

		for side = -1, 1, 2 do
			Build.mesh({
				prop = "Column",
				name = "Post",
				size = Vector3.new(2, 12, 2),
				cframe = basis * CFrame.new(side * 6, 5, 0),
				untextured = bare,
				color = frameColour,
				parent = gate,
			})
		end

		local door = Build.mesh({
			prop = "Gate",
			name = "Door",
			size = Vector3.new(12, 11, 1.8),
			collisionSize = Vector3.new(10, 10, 1),
			cframe = basis * CFrame.new(0, 5, 0),
			untextured = bare,
			color = leafColour,
			parent = gate,
		})

		--[[
			Stood out in front of the door, not inside it.

			The billboard hung on the door itself, which is a mesh nearly two
			studs deep — so the writing sat in the middle of the wood it was
			labelling, and a billboard turns to face the camera: walk up to
			the gate from either side and half of it is behind the door.
			"Unlock" read as "nlock". The marker goes on the approach side,
			through the gate's own basis so it is the right side whichever
			way round the gate was built — `gateBasis` looks into the section
			it gates, so +Z is the side you walk up from and -Z is past the
			door. Below the arch, too: at nine studs the top line ran into the
			crossbeam and lost the same word to it instead.
		]]
		local front = Build.part({
			name = "SignFace",
			size = Vector3.new(0.2, 0.2, 0.2),
			cframe = basis * CFrame.new(0, 7.5, 2.4),
			transparency = 1,
			canCollide = false,
			castShadow = false,
			parent = gate,
		})

		local gui = Build.billboard(front, UDim2.fromOffset(160, 70), 0, 90)
		Build.label(gui, "Unlock", UDim2.fromScale(1, 0.5), UDim2.fromScale(0, 0), 0.8)
		local price = Build.label(
			gui,
			`${string.format("%.2f", section.cost)}`,
			UDim2.fromScale(1, 0.5),
			UDim2.fromScale(0, 0.5),
			0.9
		)
		price.TextColor3 = Color3.fromRGB(126, 226, 108)

		local prompt = Build.prompt(door, "Unlock", section.name, 10)
		prompt.Triggered:Connect(function(player: Player)
			gateSignal:Fire(player, section.id)
		end)

		gates[section.id] = gate
	end

	return gates
end


--------------------------------------------------------------------
-- Where a stairway or a doorway can go
--------------------------------------------------------------------

--[[
	Where the way out goes when the property has a cellar.

	Recorded while the sunken room is built, because that is the only place
	that knows which wall the stairs came through — the way out belongs in the
	opposite one. Cleared on every load, so a property without a cellar falls
	back to the tile in its config.
]]
local cellarExit: { position: Vector3, facing: Vector3 }? = nil

--- Width of a flight of steps, and of the gap left in a wall for one.
--[[
	As wide as the doorway it comes through, and not a stud less.

	The wall a stairway passes through is broken `DOOR_WIDTH` wide and the
	flight was built ten, so there was a two stud slot down each side of every
	staircase in the game. On a sunken room that slot runs from the lawn to
	the cellar floor sixteen studs below — and the near half of it is past the
	edge of the floor slab, so squeezing into it drops you out of the world
	entirely. Reported as "next to the staircase there is a hole in each side
	where you can squeeze through and fall out".

	The flight fills the opening now, which closes it by construction rather
	than by patching a hole either side.
]]
local DOOR_WIDTH = 14
local STAIR_WIDTH = DOOR_WIDTH
--- Studs of run per stud of climb: about a thirty-degree staircase.
local STAIR_RUN_PER_RISE = 1.6
local STAIR_MIN_RUN = 12
--- Clear space a player needs over a flight, and in front of a door.
local STAIR_HEADROOM = 10
local DOOR_APPROACH = 10
--- How far outside a sunken section to check before dropping a stairwell in.
local STAIR_OUTSIDE_MARGIN = 8

--[[
	Parts a stairway is allowed to pass through.

	The lawn and the flat dressing over it are the floor everything stands on,
	so overlapping them means nothing; a wall, a shed or a porch roof is a
	different matter, and is exactly what the search below is looking for.
]]
local WALKABLE_PARTS: { [string]: boolean } = {
	Surrounds = true,
	Road = true,
	Paving = true,
	Path = true,
	SpawnPad = true,
	MowSpawn = true,
	RoofDeck = true,
}

local function isWalkablePart(part: BasePart): boolean
	if WALKABLE_PARTS[part.Name] then
		return true
	end
	return string.match(part.Name, "^Ground%d+$") ~= nil
end

--- True when nothing solid already built inside `parent` sits in the box.
local function volumeIsClear(parent: Instance, centre: Vector3, size: Vector3): boolean
	local half = size * 0.5
	local low, high = centre - half, centre + half
	for _, part in parent:GetDescendants() do
		if part:IsA("BasePart") and part.CanCollide and not isWalkablePart(part) then
			local partLow = part.Position - part.Size * 0.5
			local partHigh = part.Position + part.Size * 0.5
			if
				low.X < partHigh.X
				and high.X > partLow.X
				and low.Y < partHigh.Y
				and high.Y > partLow.Y
				and low.Z < partHigh.Z
				and high.Z > partLow.Z
			then
				return false
			end
		end
	end
	return true
end

--- True when a footprint on the ground plane lies over another section.
local function overlapsAnotherSection(
	world: Types.WorldDef,
	section: Types.ZoneDef,
	centre: Vector3,
	size: Vector3
): boolean
	local half = size * 0.5
	local low, high = centre - half, centre + half
	for _, other in world.sections do
		if other.id ~= section.id then
			local r = other.rect
			local otherLowX, otherHighX = r.x * TILE, (r.x + r.w) * TILE
			local otherLowZ, otherHighZ = r.z * TILE, (r.z + r.d) * TILE
			if
				low.X < otherHighX
				and high.X > otherLowX
				and low.Z < otherHighZ
				and high.Z > otherLowZ
			then
				return true
			end
		end
	end
	return false
end

type ApproachSide = {
	normal: Vector3,
	span: number,
	alongX: boolean,
}

export type Approach = {
	--- Outward direction of the side used.
	normal: Vector3,
	--- Distance along that side from its centre.
	offset: number,
	--- Point on the section's edge the flight arrives at or leaves from.
	edge: Vector3,
	--- Horizontal length of the flight.
	run: number,
}

--[[
	Picks the side of a section its stairs or its door can use.

	Where a flight goes is not free. The rooftop's front is the porch and the
	basement's front is the shed, so the one fixed side the builder used to
	take buried both flights inside a building: the roof stairs ran through the
	porch roof and the cellar steps ran into the back wall of the shed, which
	is why neither section could be reached on foot. Every side is tried in
	turn, and several positions along each, against everything already standing
	— and, for a flight rather than a door, a first pass also keeps it off
	other sections' lawns so it never covers ground somebody has to mow.
]]
local function chooseApproach(
	world: Types.WorldDef,
	section: Types.ZoneDef,
	elevation: number,
	ringOverhang: number,
	parent: Folder
): Approach?
	local r = section.rect
	local rise = math.abs(elevation)
	local run = if rise > 0 then math.max(rise * STAIR_RUN_PER_RISE, STAIR_MIN_RUN) else DOOR_APPROACH
	local sunken = elevation < 0

	-- Rooms and roofs are laid out from tile centres, so the ring being broken
	-- is measured the same way rather than from the raw rectangle.
	local centre = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z + r.d * 0.5)
	local halfX = r.w * TILE * 0.5 + ringOverhang
	local halfZ = r.d * TILE * 0.5 + ringOverhang

	local sides: { ApproachSide } = {
		{ normal = Vector3.new(0, 0, -1), span = r.w * TILE, alongX = true },
		{ normal = Vector3.new(0, 0, 1), span = r.w * TILE, alongX = true },
		{ normal = Vector3.new(-1, 0, 0), span = r.d * TILE, alongX = false },
		{ normal = Vector3.new(1, 0, 0), span = r.d * TILE, alongX = false },
	}
	local shifts = { 0, 0.25, -0.25, 0.38, -0.38 }

	--- The box a flight on this side would need to itself.
	local function volumeFor(side: ApproachSide, offset: number): (Vector3, Vector3)
		local normal = side.normal
		local edge = centre + Vector3.new(normal.X * halfX, 0, normal.Z * halfZ)
		local slide = if side.alongX then Vector3.new(offset, 0, 0) else Vector3.new(0, 0, offset)
		edge += slide

		-- A sunken flight drops inwards from the edge, and needs the ground
		-- just outside it clear too, because that is where you step on from.
		-- Everything else approaches the edge from outside.
		local a = if sunken
			then edge + normal * STAIR_OUTSIDE_MARGIN
			else edge + normal * 1
		local b = if sunken then edge - normal * run else edge + normal * run

		local mid = (a + b) * 0.5
		local along = math.abs(a.X - b.X) + math.abs(a.Z - b.Z)
		local size = if side.alongX
			then Vector3.new(STAIR_WIDTH + 4, 1, along)
			else Vector3.new(along, 1, STAIR_WIDTH + 4)

		local lowY = math.min(0, elevation)
		local highY = math.max(0, elevation) + STAIR_HEADROOM
		local boxCentre = Vector3.new(mid.X, (lowY + highY) * 0.5, mid.Z)
		local boxSize = Vector3.new(size.X, highY - lowY, size.Z)
		return boxCentre, boxSize
	end

	local fallback: Approach? = nil
	for _, side in sides do
		for _, fraction in shifts do
			local offset = side.span * fraction
			local boxCentre, boxSize = volumeFor(side, offset)
			if volumeIsClear(parent, boxCentre, boxSize) then
				local normal = side.normal
				local slide = if side.alongX
					then Vector3.new(offset, 0, 0)
					else Vector3.new(0, 0, offset)
				local approach: Approach = {
					normal = normal,
					offset = offset,
					edge = centre + Vector3.new(normal.X * halfX, 0, normal.Z * halfZ) + slide,
					run = run,
				}
				if rise <= 0 or not overlapsAnotherSection(world, section, boxCentre, boxSize) then
					return approach
				end
				fallback = fallback or approach
			end
		end
	end
	return fallback
end

local cashGates: { [string]: Model } = {}
--[[
	The grille across a room's doorway, by section.

	A cash gate is a door you buy and it already stands there saying so; the
	garage has a shutter its hidden switch rolls up. A room earned by finishing
	the section before it had nothing at all — the chapel's doorway was a hole
	in a wall whether or not you were allowed through it, so "locked" was
	something the client knew and the property did not show. These are the
	portcullis the way out uses, hung in the doorway and raised the same way.
]]
local sectionGates: { [string]: { BasePart } } = {}

--- Hangs a gate on the section that opening it should open.
local function registerGate(sectionId: string, gate: BasePart)
	local list = sectionGates[sectionId]
	if not list then
		list = {}
		sectionGates[sectionId] = list
	end
	table.insert(list, gate)
end

--[[
	The hidden switches that open `button` sections.

	`unlock = "button"` and `buttonIn` have been in the world tables from the
	start and nothing ever built the button, so the Garage could not be opened
	by any means — and the quest chain, which waits on it at step five and only
	ever advances its current quest, could never get past it. The switch goes
	into a corner of the section named by `buttonIn`, off the walked line
	rather than out in the middle, because finding it is the whole point of it.
]]
local function buildSwitches(world: Types.WorldDef, parent: Folder)
	local folder: Folder? = nil

	for _, section in world.sections do
		local hostId = section.buttonIn
		local host = if hostId then Worlds.section(world, hostId) else nil
		if Worlds.unlockKind(section) == "button" and host then
			local made = folder or Build.folder("Switches", parent)
			folder = made

			local r = host.rect
			local at = WorldService.tilePointFlat(r.x + 2, r.z + r.d - 3)

			Build.mesh({
				prop = "Column",
				name = "Post",
				size = Vector3.new(1.2, 7, 1.2),
				cframe = CFrame.new(at + Vector3.new(0, 3.5, 0)),
				color = Palette.color(Palette.house.trim),
				parent = made,
			})
			local box = Build.mesh({
				prop = "ShopBoard",
				name = section.id,
				size = Vector3.new(4, 4, 2),
				cframe = CFrame.new(at + Vector3.new(0, 8, 0)),
				color = Palette.color(Palette.ui.cash),
				parent = made,
			})
			box:SetAttribute("SectionId", section.id)

			local gui = Build.billboard(box, UDim2.fromScale(6, 2.6), 4, 140)
			Build.label(gui, "SWITCH", UDim2.fromScale(1, 0.54), UDim2.fromScale(0, 0), 2)
			Build.label(gui, section.name, UDim2.fromScale(1, 0.4), UDim2.fromScale(0, 0.58), 1.2)

			local prompt = Build.prompt(box, "Flip", "Switch", 12)
			prompt.Triggered:Connect(function(player: Player)
				switchSignal:Fire(player, section.id)
			end)
		end
	end
end

local function buildSectionStructures(world: Types.WorldDef, parent: Folder)
	local context: Structures.Context = {
		parent = parent,
		world = world,
		flat = function(tx: number, tz: number): Vector3
			return WorldService.tilePointFlat(tx, tz)
		end,
		tileSize = TILE,
		groundY = GameConfig.GROUND_Y,
		rng = rng,
	}

	--[[
		Structure is driven by the section, not by the world's style.

		This whole block used to be wrapped in `world.style == "house"`, which
		meant the Gas Station — a lot, not a house — got no rooms, no floors and
		no stairs. Its Workshop is a sunken room, and the ground is cut away for
		anything sunken whatever the style, so the last required section of that
		world was an eighteen-stud hole with no floor and no way in or out. It
		never showed because nothing could load that world; now that beating one
		world leads to the next, it very much can. What a section is made of is
		its own business: `kind` and `elevation` decide it, and the style only
		decides the fencing and dressing further down.
	]]
	for _, section in world.sections do
		local kind = section.kind or "open"
		local elevation = section.elevation or 0

		do
			-- A roof's parapet stands on a deck that overhangs the section by
			-- two studs, so the gap in it — and the flight that arrives at it
			-- — are measured from the deck's edge, not the section's.
			local overhang = if kind == "roof" then 2 else 0
			-- A glasshouse is walled like a room and a terrace stands above the
			-- lawn, so both want the same doorway-and-stairs treatment.
			local needsWayIn = kind == "room" or kind == "glasshouse" or elevation ~= 0
			local approach = if needsWayIn
				then chooseApproach(world, section, elevation, overhang, parent)
				else nil
			local opening: Structures.Opening? = if approach
				then { normal = approach.normal, width = DOOR_WIDTH, offset = approach.offset }
				else nil

			if not approach and needsWayIn then
				warn(`[Mow] no clear way into {section.id}; it may be unreachable`)
			end

			if kind == "room" then
				--[[
					A room in the colours of the property it stands on.

					The cellars under an estate are stone vaults, not the red
					brick cellar of a suburban house, and a filling station's
					wash bay is built out of the station's own cream and dark
					grey rather than out of lap siding. Same builder, three
					sets of materials.
				]]
				local skin: Structures.RoomSkin = if world.style == "estate"
					then {
						wall = Palette.color(Palette.estate.stone),
						wallSunken = Palette.color(Palette.estate.stoneShade),
						roof = Palette.color(Palette.estate.roof),
						fascia = Palette.color(Palette.estate.lead),
						floor = Palette.color(Palette.estate.gravelDark),
					}
					elseif world.style == "churchyard" then {
						-- The room under a chapel is a crypt, not a cellar.
						underground = "crypt",
						wall = Palette.color(Palette.churchyard.granite),
						wallSunken = Palette.color(Palette.churchyard.graniteDark),
						roof = Palette.color(Palette.churchyard.graniteDark),
						fascia = Palette.color(Palette.churchyard.iron),
						floor = Palette.color(Palette.churchyard.gravel),
						-- Only the one above ground: the crypt is a crypt and
						-- already has its own furniture. `Structures.room`
						-- fits a chapel out only when it is building a roof.
						fitting = "chapel",
					}
					elseif world.style == "lot" then {
						-- The room under a filling station is its workshop,
						-- not somebody's cellar; the one above it is the wash
						-- bay, which is lanes rather than an empty shed.
						underground = "workshop",
						fitting = "washbay",
						-- A wash bay floor is concrete that is wet most of the
						-- time, not the sand the default leaves it.
						floor = Palette.color(Palette.station.dark),
						wall = Palette.color(Palette.station.body),
						wallSunken = Palette.color(Palette.station.dark),
						-- Dark roof, red band. The fascia stripe is the
						-- station's livery; the whole roof painted in it is a
						-- forty-stud red slab visible from the far fence.
						roof = Palette.color(Palette.station.dark),
						fascia = Palette.color(Palette.station.fascia),
					}
					else {
						wall = Palette.color(Palette.house.siding),
						wallSunken = Palette.color(Palette.house.brickDark),
						roof = Palette.color(Palette.house.roof),
						-- The only room above ground on this property is the
						-- garage; below it is somebody's cellar, which is what
						-- the sunken default already builds.
						fitting = "garage",
					}
				Structures.room(context, section, 16, elevation < 0, opening, skin)

				--[[
					A grille in the doorway until the section is earned.

					Only where nothing else is already holding the door: a
					cash-gated section has a door you buy and the garage has
					its shutter, so a second barrier behind either would mean
					opening one and finding another. That leaves the rooms
					earned by finishing the section before them, which had
					nothing.

					Hung on the doorway the approach already worked out — the
					edge sits at flat ground level, so the section's own floor
					has to be added.

					It swings rather than rising. The way out is a portcullis
					because it stands in a free block of masonry with nothing
					above it; a room has a wall over its door and a roof over
					that. Fifteen studs of grate lifted thirteen would stand
					clear through the roof of the chapel, and up through the
					lawn on anything underground. Hinged on one jamb it stays
					where it belongs, and a door on hinges is what a doorway
					has anyway.

					Where it ends up is worked out here and kept on the part,
					so the opener does not have to reconstruct the frame it
					was hung in.
				]]
				if approach and Worlds.unlockKind(section) == "completion" then
					--[[
						A cellar's gate stands at the head of its steps.

						An above-ground room is simple: the doorway is a gap
						in the wall, and the gate fills it from the floor to
						the head of the wall.

						A sunken one is not. Its wall is a retaining wall from
						the floor up to ground level, and the flight descends
						*inside* the room from the opening — so the volume of
						that opening is where the staircase is. A gate hung in
						it is buried in the treads and the stringer: invisible
						from either side, and no obstacle at all, because you
						walk over the top of it at ground level. That is what
						the first attempt did on The House's basement, and
						only the chapel looked right because it stands on the
						ground where the floor and the doorway are the same
						height.

						What bars a cellar is a gate across the top of the
						steps. So on anything sunken it stands on the ground
						at the mouth of the stairwell rather than in the wall
						below it.
					]]
					local sunkenRoom = elevation < 0
					local rise = if sunkenRoom then 11 else 16
					--- Ground level at the stairwell mouth, or the room's own
					--- floor where the doorway is in a wall you walk through.
					local gateBase = if sunkenRoom then 0 else elevation + 0.06
					local gateAt = approach.edge + Vector3.new(0, gateBase, 0)
					local hung = CFrame.lookAt(gateAt, gateAt + approach.normal)
						* CFrame.new(0, rise * 0.5, 0)
					local half = DOOR_WIDTH * 0.5
					--- The jamb it turns on, and the leaf hanging off it.
					local hinge = hung * CFrame.new(-half, 0, 0)
					local leaf = CFrame.new(half, 0, 0)
					local gate = Build.mesh({
						prop = "Grate",
						name = "RoomGate",
						size = Vector3.new(DOOR_WIDTH, rise, 2),
						collisionSize = Vector3.new(DOOR_WIDTH, rise, 1),
						cframe = hinge * leaf,
						parent = parent,
					})
					gate:SetAttribute("Shut", true)
					gate:SetAttribute("Swung", hinge * CFrame.Angles(0, math.rad(-104), 0) * leaf)
					registerGate(section.id, gate)
				end

				--[[
					A cellar's far wall is where the way out goes.

					`approach.normal` points out of the room on the side the
					stairs come down, so its opposite is the wall furthest
					from them — which is the one worth walking the length of
					the room to reach, and the one that reads as a back door
					rather than a second way onto the same staircase.
				]]
				if elevation < 0 and approach then
					local roomCentre = WorldService.tilePointFlat(
						section.rect.x + section.rect.w * 0.5,
						section.rect.z + section.rect.d * 0.5
					)
					local facing = -approach.normal
					local reach = if math.abs(facing.X) > 0.5
						then section.rect.w * TILE * 0.5
						else section.rect.d * TILE * 0.5
					cellarExit = {
						position = roomCentre + facing * (reach - 0.4) + Vector3.new(0, elevation, 0),
						facing = facing,
					}
				end
			elseif kind == "court" then
				Structures.court(context, section)
			elseif kind == "terrace" then
				Structures.terrace(context, section, opening)
			elseif kind == "glasshouse" then
				Structures.glasshouse(context, section, opening)
			elseif kind == "pool" then
				Structures.pool(context, section)
			elseif kind == "graves" then
				Structures.graves(context, section)
			elseif kind == "maze" then
				--[[
					An estate's maze is yew, and taller than a garden one.

					The Mansion's maze was the same bright garden hedge at the
					same nine studs as The House's, which is most of what made
					"the mansion looks identical to the first level" true from
					the air. A parterre maze is clipped out of something almost
					black and it is over your head, so you cannot see the way
					out by standing on your toes.
				]]
				--[[
					What each property's maze is grown out of.

					This asked whether the property was the estate, which was
					true of every maze in the game right up until there were
					two — and the Cemetery's was coming out in The House's
					bright garden green at shoulder height, a hedge maze in a
					churchyard at midnight lit like a lawn.

					A table rather than a chain of `if`s, so a property that
					wants its own crop says so in one line here.
				]]
				local CROP: { [string]: Structures.MazeCrop } = {
					estate = {
						prop = "Hedge",
						tint = Palette.color(Palette.estate.yew),
						height = 13,
						shade = true,
					},
					--[[
						Corn, not yew.

						A churchyard maze at the end of October is a corn maze;
						that is the thing this section is for and it is what
						was asked for. Corn takes no tint — it is already the
						colour of a crop left standing too long — and every
						tile is turned its own way, because a corridor of one
						plant repeated is wallpaper.
					]]
					churchyard = { prop = "Corn", height = 13, spin = true, sentinels = 3 },
				}
				Structures.maze(context, section, CROP[world.style or ""])
			elseif kind == "roof" then
				-- The roof slab is the floor the rooftop's debris rests on.
				local r = section.rect
				local centre = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z + r.d * 0.5)
				Build.part({
					name = "RoofDeck",
					size = Vector3.new(r.w * TILE + 4, 2, r.d * TILE + 4),
					cframe = CFrame.new(centre + Vector3.new(0, elevation - 1, 0)),
					color = Palette.color(Palette.house.roof),
					material = Enum.Material.Slate,
					parent = parent,
				})
				-- A parapet, so a player on the roof does not simply walk off
				-- it — broken only where the stairs come up.
				Structures.parapet(context, section, 4, opening)
			end

			-- Stairs into anything not on the lawn.
			if approach and elevation ~= 0 then
				local top = approach.edge + Vector3.new(0, elevation, 0)
				local outside = approach.edge + approach.normal * approach.run
				local inside = approach.edge - approach.normal * approach.run
				if elevation > 0 then
					-- Climb from the lawn outside up to the section's edge.
					Structures.stairs(context, outside, top, STAIR_WIDTH, parent)
				else
					-- Drop from the edge down into the room.
					Structures.stairs(
						context,
						approach.edge,
						inside + Vector3.new(0, elevation, 0),
						STAIR_WIDTH,
						parent
					)
				end
			end
		end

		Structures.clutter(
			context,
			section,
			--[[
				Nothing loose in a maze.

				A corridor is three tiles across and a crate dropped in one is
				a wall you have to back out of — the props were making a
				section whose whole difficulty is already the route harder in
				the one way that is no fun. The hedges are the obstacle.
			]]
			if (section.kind or "open") == "maze" then 0 else (section.clutter or 0),
			Structures.clutterSets[world.style or "house"],
			Structures.roomSets[world.style or "house"]
		)
	end
end

--------------------------------------------------------------------
-- The exit
--------------------------------------------------------------------

local exitPart: BasePart? = nil

--- Builds the grate, shut. It opens when the last section is clear.
--[[
	The way out, in the cellar where there is one.

	It used to stand on the lawn: a brick arch in the middle of the grass with
	WAY OUT over it, which is a gate to nowhere in particular. A property with
	a cellar has a better answer already built — the room at the bottom of the
	stairs has a wall nobody uses, furthest from the way in, and a back door
	in it turns the last thing you do on a job into walking the length of the
	cellar and out. Asked for exactly that.

	`cellarExit` is set while the sunken room is built, because that is the
	only place that knows which wall the stairs came through. Without one —
	a property with no cellar — this falls back to the tile in the config and
	the arch on the lawn it has always been.
]]
--[[
	The churchyard: a wall you cannot see over, and a chapel you can.

	The other three properties are entered off a road and fenced with whatever
	suits them — pickets, estate stone, chain-link. A churchyard is walled in
	rubble with iron on top of it and got into through a lychgate, and the one
	thing standing above the wall is the chapel. At night that tower is the
	only landmark on the property, so it is lit from inside and its windows are
	the warmest thing in the world.

	Dead trees and lanterns are scattered over the top: the trees because a
	bare silhouette is what says late October, and the lanterns because a
	property this dark needs somewhere for the eye to rest between the graves.
]]
--[[
	Walls and fences between the parts of a property, not just space.

	Reported twice, once for each property it applies to: besides a pathway
	there is nothing separating the sections. Which was true — the strip
	between two section rectangles is bare ground, so one part of the ground
	runs into the next with nothing to say where one ends. A churchyard is
	divided into quarters by dwarf walls and a filling station's lot is
	divided by chain-link, and it is most of what makes either read as a place
	rather than as a field with things on it.

	Only between sections that are both open ground. A maze walls itself, and
	a room has its own walls and its own gate, so a division against either
	would be a barrier behind a barrier.

	Each run is a single part rather than one per tile, because these are
	straight and long. The strip belongs to no section, so nothing sown is
	lost underneath them.
]]
type DivideStyle = {
	height: number,
	thickness: number,
	body: Color3,
	bodyMaterial: Enum.Material,
	cap: Color3,
	--- Chain-link is a translucent sheet on posts; a dwarf wall is a solid
	--- run with a coping. The two want different parts.
	wire: boolean?,
}

local DIVIDE_OPENING = 16

local function buildDivisions(world: Types.WorldDef, parent: Folder, style: DivideStyle)
	local folder = Build.folder("Divisions", parent)

	local function divides(section: Types.ZoneDef): boolean
		local kind = section.kind or "open"
		return kind == "open" or kind == "graves"
	end

	local function run(from: Vector3, to: Vector3, alongX: boolean)
		local length = (to - from).Magnitude
		if length < 2 then
			return
		end
		local mid = (from + to) * 0.5
		if style.wire then
			--[[
				Chain-link the way the boundary fence builds it: a translucent
				sheet with a rail along the top and a post every so often.
				Built from plain parts rather than the picket panel — that
				prop is a row of pickets, and a filling station is not fenced
				with those. One sheet the length of the run, because a
				material tiles with the part it is on and does not smear the
				way a stretched mesh does.
			]]
			Build.part({
				name = "DivideMesh",
				size = if alongX
					then Vector3.new(length, style.height, 0.4)
					else Vector3.new(0.4, style.height, length),
				cframe = CFrame.new(mid + Vector3.new(0, style.height * 0.5, 0)),
				color = style.body,
				material = Enum.Material.DiamondPlate,
				transparency = 0.55,
				castShadow = false,
				parent = folder,
			})
			Build.part({
				name = "DivideRail",
				size = if alongX
					then Vector3.new(length, 0.5, 0.55)
					else Vector3.new(0.55, 0.5, length),
				cframe = CFrame.new(mid + Vector3.new(0, style.height, 0)),
				color = style.cap,
				material = Enum.Material.Metal,
				canCollide = false,
				castShadow = false,
				parent = folder,
			})
			local posts = math.max(math.floor(length / 20), 1)
			for index = 0, posts do
				local at = from + (to - from) * (index / posts)
				Build.part({
					name = "DividePost",
					size = Vector3.new(1.1, style.height + 1, 1.1),
					cframe = CFrame.new(at + Vector3.new(0, (style.height + 1) * 0.5, 0)),
					color = style.cap,
					material = Enum.Material.Metal,
					castShadow = false,
					parent = folder,
				})
			end
		else
			Build.part({
				name = "DivideWall",
				size = if alongX
					then Vector3.new(length, style.height, style.thickness)
					else Vector3.new(style.thickness, style.height, length),
				cframe = CFrame.new(mid + Vector3.new(0, style.height * 0.5, 0)),
				color = style.body,
				material = style.bodyMaterial,
				parent = folder,
			})
			Build.part({
				name = "DivideCoping",
				size = if alongX
					then Vector3.new(length, 0.9, style.thickness + 1)
					else Vector3.new(style.thickness + 1, 0.9, length),
				cframe = CFrame.new(mid + Vector3.new(0, style.height + 0.45, 0)),
				color = style.cap,
				material = Enum.Material.Slate,
				parent = folder,
			})
		end
	end

	--- A post where a run stops, so the opening has two jambs rather than two
	--- cut ends.
	local function jamb(at: Vector3)
		local tall = style.height + 2.6
		Build.part({
			name = "DividePier",
			size = Vector3.new(if style.wire then 1.6 else 4, tall, if style.wire then 1.6 else 4),
			cframe = CFrame.new(at + Vector3.new(0, tall * 0.5, 0)),
			color = style.body,
			material = style.bodyMaterial,
			parent = folder,
		})
		Build.part({
			name = "DividePierCap",
			size = Vector3.new(if style.wire then 2.4 else 5, 1, if style.wire then 2.4 else 5),
			cframe = CFrame.new(at + Vector3.new(0, tall + 0.5, 0)),
			color = style.cap,
			material = Enum.Material.Slate,
			parent = folder,
		})
	end

	--[[
		And a gate in the opening, hung on the section it lets you into.

		Only where that section is earned by finishing the one before it. A
		section you buy already has a door you bought, and putting a second
		one behind it would mean opening one gate and finding another.
	]]
	local function gate(at: Vector3, facing: Vector3, section: Types.ZoneDef)
		if Worlds.unlockKind(section) ~= "completion" then
			return
		end
		local tall = style.height + 2
		local hung = CFrame.lookAt(at, at + facing) * CFrame.new(0, tall * 0.5, 0)
		local half = DIVIDE_OPENING * 0.5
		local hinge = hung * CFrame.new(-half, 0, 0)
		local leaf = CFrame.new(half, 0, 0)
		--[[
			In the fence's own metal where the fence is metal.

			The gate mesh carries its own pale texture, which is right in a
			churchyard wall and wrong hung between two galvanised posts: the
			forecourt had a white ornamental gate standing in a run of dark
			chain-link. Untextured it keeps its bars and takes the colour of
			the rail and the posts either side of it.
		]]
		local part = Build.mesh({
			prop = "Grate",
			name = "DivideGate",
			size = Vector3.new(DIVIDE_OPENING, tall, 2),
			collisionSize = Vector3.new(DIVIDE_OPENING, tall, 1),
			cframe = hinge * leaf,
			color = if style.wire then style.cap else nil,
			untextured = style.wire,
			parent = folder,
		})
		part:SetAttribute("Shut", true)
		part:SetAttribute("Swung", hinge * CFrame.Angles(0, math.rad(-104), 0) * leaf)
		registerGate(section.id, part)
	end

	for i, a in world.sections do
		for j, b in world.sections do
			if j <= i or not divides(a) or not divides(b) then
				continue
			end
			--- The later of the two in the world's own order is the one you
			--- have to earn, so it is the one the gate belongs to.
			local later = b
			local ar, br = a.rect, b.rect
			local lowX = math.max(ar.x, br.x)
			local highX = math.min(ar.x + ar.w, br.x + br.w)
			local lowZ = math.max(ar.z, br.z)
			local highZ = math.min(ar.z + ar.d, br.z + br.d)

			if highX > lowX then
				local gapLow = math.min(ar.z + ar.d, br.z + br.d)
				local gapHigh = math.max(ar.z, br.z)
				if gapHigh - gapLow >= 1 and gapHigh - gapLow <= 4 then
					local z = (gapLow + gapHigh) * 0.5 * TILE
					local x0, x1 = lowX * TILE, highX * TILE
					local mid = (x0 + x1) * 0.5
					run(Vector3.new(x0, 0, z), Vector3.new(mid - DIVIDE_OPENING * 0.5, 0, z), true)
					run(Vector3.new(mid + DIVIDE_OPENING * 0.5, 0, z), Vector3.new(x1, 0, z), true)
					jamb(Vector3.new(mid - DIVIDE_OPENING * 0.5, 0, z))
					jamb(Vector3.new(mid + DIVIDE_OPENING * 0.5, 0, z))
					gate(Vector3.new(mid, 0, z), Vector3.new(0, 0, 1), later)
				end
			elseif highZ > lowZ then
				local gapLow = math.min(ar.x + ar.w, br.x + br.w)
				local gapHigh = math.max(ar.x, br.x)
				if gapHigh - gapLow >= 1 and gapHigh - gapLow <= 4 then
					local x = (gapLow + gapHigh) * 0.5 * TILE
					local z0, z1 = lowZ * TILE, highZ * TILE
					local mid = (z0 + z1) * 0.5
					run(Vector3.new(x, 0, z0), Vector3.new(x, 0, mid - DIVIDE_OPENING * 0.5), false)
					run(Vector3.new(x, 0, mid + DIVIDE_OPENING * 0.5), Vector3.new(x, 0, z1), false)
					jamb(Vector3.new(x, 0, mid - DIVIDE_OPENING * 0.5))
					jamb(Vector3.new(x, 0, mid + DIVIDE_OPENING * 0.5))
					gate(Vector3.new(x, 0, mid), Vector3.new(1, 0, 0), later)
				end
			end
		end
	end
end

local function buildChurchyard(world: Types.WorldDef, parent: Folder)
	local yard = Build.folder("Churchyard", parent)
	local granite = Palette.color(Palette.churchyard.granite)
	local graniteDark = Palette.color(Palette.churchyard.graniteDark)
	local iron = Palette.color(Palette.churchyard.iron)
	local candle = Palette.color(Palette.churchyard.candle)
	local width = world.gridWidth * TILE
	local depth = world.gridDepth * TILE
	local spawnAt = WorldService.tilePointFlat(world.spawn.x, world.spawn.z)

	----------------------------------------------------------------
	-- The boundary: rubble wall, iron above it, open at the road
	----------------------------------------------------------------
	local WALL_H, RAIL_H = 9, 7
	local runs = {
		{ from = Vector3.new(0, 0, depth), to = Vector3.new(width, 0, depth) },
		{ from = Vector3.new(0, 0, 0), to = Vector3.new(0, 0, depth) },
		{ from = Vector3.new(width, 0, 0), to = Vector3.new(width, 0, depth) },
	}
	for _, run in runs do
		local delta = run.to - run.from
		local length = delta.Magnitude
		local along = delta.Unit
		local mid = run.from + along * (length * 0.5)
		local alongX = math.abs(delta.X) > math.abs(delta.Z)
		Build.part({
			name = "YardWall",
			size = if alongX then Vector3.new(length, WALL_H, 3) else Vector3.new(3, WALL_H, length),
			cframe = CFrame.new(mid + Vector3.new(0, WALL_H * 0.5, 0)),
			color = granite,
			material = Enum.Material.Rock,
			parent = yard,
		})
		Build.part({
			name = "YardCoping",
			size = if alongX then Vector3.new(length, 1, 4) else Vector3.new(4, 1, length),
			cframe = CFrame.new(mid + Vector3.new(0, WALL_H + 0.5, 0)),
			color = graniteDark,
			material = Enum.Material.Slate,
			parent = yard,
		})
		--- Railings above the coping, in panels.
		local panels = math.max(math.floor(length / 16), 1)
		for index = 0, panels - 1 do
			local at = run.from + along * (length * (index + 0.5) / panels)
			Build.mesh({
				prop = "Railing",
				name = "YardRail",
				untextured = true,
				color = iron,
				size = Vector3.new(length / panels, RAIL_H, 0.8),
				collisionSize = Vector3.new(length / panels, RAIL_H, 0.8),
				cframe = CFrame.new(at + Vector3.new(0, WALL_H + 1 + RAIL_H * 0.5, 0))
					* CFrame.Angles(0, if alongX then 0 else math.rad(90), 0),
				parent = yard,
			})
		end
	end
	--[[
		A pier where the wall turns, and one where it stops at the road.

		Two runs of coping meeting at a corner overlap in a square with both
		top faces on the same plane, which flickers; every world's boundary
		showed it. A wall like this is built with a pier at every corner and
		terminal anyway, so the junction goes inside a block of stone rather
		than being fudged out of existence.
	]]
	local PIER_W, PIER_H = 5.5, WALL_H + 3
	for _, corner in {
		Vector3.new(0, 0, depth),
		Vector3.new(width, 0, depth),
		Vector3.new(0, 0, 0),
		Vector3.new(width, 0, 0),
	} do
		Build.part({
			name = "YardPier",
			size = Vector3.new(PIER_W, PIER_H, PIER_W),
			cframe = CFrame.new(corner + Vector3.new(0, PIER_H * 0.5, 0)),
			color = granite,
			material = Enum.Material.Rock,
			parent = yard,
		})
		Build.part({
			name = "YardPierCap",
			size = Vector3.new(PIER_W + 1, 1.2, PIER_W + 1),
			cframe = CFrame.new(corner + Vector3.new(0, PIER_H + 0.6, 0)),
			color = graniteDark,
			material = Enum.Material.Slate,
			parent = yard,
		})
	end

	--[[
		Mist lying on the ground, which is most of what makes a churchyard
		frightening and costs almost nothing.

		Sheets rather than particles: a `ParticleEmitter` big enough to cover
		a hundred and forty tiles is thousands of quads a frame on a tablet,
		and this is the largest property in the game. Six wide, very
		transparent slabs a stud and a half up, at slightly different heights
		so they overlap into something uneven rather than reading as one
		floor, do the same job for six parts. They cast no shadow and stop
		nothing — you walk through them, which is the point.
	]]
	local mistRng = Random.new(world.gridWidth * 6151 + world.gridDepth)
	for index = 1, 6 do
		local at = Vector3.new(
			mistRng:NextNumber(0.15, 0.85) * width,
			1.4 + mistRng:NextNumber(0, 0.9),
			mistRng:NextNumber(0.15, 0.85) * depth
		)
		Build.part({
			name = "Mist",
			size = Vector3.new(mistRng:NextNumber(150, 240), 0.4, mistRng:NextNumber(150, 240)),
			cframe = CFrame.new(at) * CFrame.Angles(0, mistRng:NextNumber(0, math.pi), 0),
			color = Color3.fromRGB(206, 212, 224),
			material = Enum.Material.SmoothPlastic,
			transparency = 0.88,
			canCollide = false,
			castShadow = false,
			parent = yard,
		})
	end

	----------------------------------------------------------------
	-- The lychgate, over the way in
	----------------------------------------------------------------
	--[[
		Four posts, a plate down each side and a tie across each end.

		It stood on two: one pair, in the middle, with twenty-two studs of
		pitched roof balanced on them fore and aft. A lychgate is a frame —
		a post at each corner, a beam along each side joining its pair, and
		a tie across the opening at both ends — and without one this was a
		roof that would have gone over in the first wind.

		The posts run up into the slab rather than stopping under it. The
		roof is pitched, so its underside falls a stud and a quarter across
		the depth of a post; a flat top cut to meet it leaves a wedge of
		daylight on the higher side, and there is nothing to see inside the
		timber.
	]]
	local gateZ = 6
	local REACH = 5
	local timber = Palette.color(Palette.churchyard.timber)
	for _, side in { -1, 1 } do
		for _, along in { -1, 1 } do
			Build.part({
				name = "LychPost",
				size = Vector3.new(2.6, 19, 2.6),
				cframe = CFrame.new(spawnAt.X + side * 11, 9.5, gateZ + along * REACH),
				color = timber,
				material = Enum.Material.WoodPlanks,
				parent = yard,
			})
		end
		Build.part({
			name = "LychPlate",
			size = Vector3.new(2.2, 1.4, REACH * 2 + 2.6),
			cframe = CFrame.new(spawnAt.X + side * 11, 14.6, gateZ),
			color = timber,
			material = Enum.Material.WoodPlanks,
			parent = yard,
		})
	end
	for _, along in { -1, 1 } do
		Build.part({
			name = "LychTie",
			size = Vector3.new(24.6, 1.6, 2.2),
			cframe = CFrame.new(spawnAt.X, 14.6, gateZ + along * REACH),
			color = timber,
			material = Enum.Material.WoodPlanks,
			canCollide = false,
			parent = yard,
		})
	end
	--- The two pitches meet at the ridge rather than overlapping in it: laid
	--- on the same centre they were coplanar where they crossed and flickered.
	for _, pitch in { -1, 1 } do
		Build.part({
			name = "LychRoof",
			size = Vector3.new(30, 1.4, 12),
			cframe = CFrame.new(spawnAt.X, 18.4 + pitch * 0.12, gateZ + pitch * 5.2)
				* CFrame.Angles(math.rad(pitch * 26), 0, 0),
			color = Palette.color(Palette.churchyard.timberDark),
			material = Enum.Material.Slate,
			parent = yard,
		})
	end
	for _, side in { -1, 1 } do
		local lamp = Build.mesh({
			prop = "JackOLantern",
			name = "JackOLantern",
			size = Vector3.new(4, 3.4, 4.2),
			collisionSize = Vector3.new(3, 3.4, 3),
			--- Outside the front posts, which now stand where these did.
			cframe = CFrame.new(spawnAt.X + side * 11, 1.7, gateZ + REACH + 3),
			parent = yard,
		})
		--[[
			A candle in a gourd, not a floodlight.

			Twenty-six studs at brightness two is nearly twice what the cellar
			lamps run at, and those are indoors with walls to catch them. Out
			here at night there is nothing to stop it: the two lanterns either
			side of the gate washed the posts, the roof, the path and the grass
			the same saturated orange, so the first thing anybody saw of the
			property was a lychgate that appeared to be on fire.

			Half the brightness over half the range leaves a pool at the foot
			of each lantern and lets the gate stay the colour of wet stone.
		]]
		local glow = Instance.new("PointLight")
		glow.Color = Palette.color(Palette.churchyard.pumpkin)
		glow.Range = 13
		glow.Brightness = 0.6
		glow.Parent = lamp
	end

	----------------------------------------------------------------
	-- The chapel's tower, which is the only thing above the wall
	----------------------------------------------------------------
	local chapel
	for _, section in world.sections do
		if section.id == "chapel" then
			chapel = section
		end
	end
	if chapel then
		local r = chapel.rect
		local at = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z + r.d * 0.5)
		local towerAt = at + Vector3.new(-(r.w * TILE) * 0.5 + 8, 0, 0)
		local TOWER = 34
		Build.part({
			name = "Tower",
			size = Vector3.new(16, TOWER, 16),
			cframe = CFrame.new(towerAt + Vector3.new(0, TOWER * 0.5, 0)),
			color = granite,
			material = Enum.Material.Rock,
			parent = yard,
		})
		--- The spire: three narrowing blocks, which reads as a point from the
		--- far end of the property and costs three parts.
		for step = 0, 2 do
			local wide = 13 - step * 4
			Build.part({
				name = "Spire",
				size = Vector3.new(wide, 7, wide),
				cframe = CFrame.new(towerAt + Vector3.new(0, TOWER + 3.5 + step * 6.6, 0)),
				color = graniteDark,
				material = Enum.Material.Slate,
				parent = yard,
			})
		end
		--- Lit windows, on all four faces, so the tower is a lantern.
		for _, face in {
			Vector3.new(0, 0, 1), Vector3.new(0, 0, -1),
			Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0),
		} do
			local window = Build.part({
				name = "ChapelWindow",
				size = if math.abs(face.X) > 0.5
					then Vector3.new(0.8, 9, 5)
					else Vector3.new(5, 9, 0.8),
				cframe = CFrame.new(towerAt + face * 8.1 + Vector3.new(0, TOWER - 12, 0)),
				color = Palette.color(Palette.churchyard.window),
				material = Enum.Material.Neon,
				canCollide = false,
				parent = yard,
			})
			local glow = Instance.new("PointLight")
			glow.Color = candle
			glow.Range = 40
			glow.Brightness = 1.8
			glow.Parent = window
		end
	end

	----------------------------------------------------------------
	-- Dead trees and lanterns, kept off the sections' own ground
	----------------------------------------------------------------
	local rng = Random.new(20261031)
	local placed = 0
	for _ = 1, 60 do
		if placed >= 18 then
			break
		end
		local tx = rng:NextInteger(4, world.gridWidth - 5)
		local tz = rng:NextInteger(4, world.gridDepth - 5)
		local index = Grid.toIndex(WorldService.grid :: Grid.Grid, tx, tz)
		local owner = WorldService.tileSection
		-- Only on ground nobody has to mow, so nothing is ever hidden under one.
		if owner ~= nil and (owner[index] or "") == "" then
			placed += 1
			local at = WorldService.tilePointFlat(tx, tz)
			local tall = rng:NextNumber(26, 40)
			Build.mesh({
				prop = "DeadTree",
				name = "DeadTree",
				untextured = false,
				size = Vector3.new(tall * 0.7, tall, tall * 0.6),
				collisionSize = Vector3.new(3, tall, 3),
				cframe = CFrame.new(at + Vector3.new(0, tall * 0.5, 0))
					* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
				parent = yard,
			})
		end
	end
end

local function buildExit(world: Types.WorldDef, parent: Folder)
	local underground = cellarExit
	local at = if underground
		then underground.position
		else WorldService.tilePointFlat(world.exit.x, world.exit.z)
	--- Turned so its own -Z looks into the room, which is the side you arrive
	--- from and the side the grate hangs on.
	local basis = if underground
		then CFrame.lookAt(at, at - underground.facing)
		else CFrame.new(at)

	--[[
		Behind the bars is a hole, not a wall.

		The gate hung on a solid brick block, so the one door on the property
		that means "you are finished" was a grille bolted to masonry — you
		could see it was shut, and you could also see there was nothing on the
		other side of it. Asked for a black hole behind the gate until it
		opens, which is right: a way out has to look like somewhere before it
		looks like a door.

		So the panel behind the grate is a dark void, and the brick is cut
		back to a surround — a jamb either side and a lintel over — which is
		what holds the gate and what the sign hangs on.
	]]
	--[[
		And nothing of the room's own standing in it.

		A cellar's walls carry piers at intervals, and the room that builds
		them has no idea where the way out is going to be cut — so on the
		churchyard one of them landed dead centre in the opening. Behind the
		bars, where a black hole was supposed to be, was four studs of pale
		granite pillar: the one door on the property that means "you are
		finished" looked like a grille bolted to a column.

		The exit is cut last and knows exactly where it is, so it takes out
		what is in the way, which is the same bargain `clearTileAt` makes with
		the buried-tile sweep. Only piers: the wall itself is meant to be
		there and the void is what replaces the hole in it.
	]]
	for _, part in workspace:GetPartBoundsInBox(basis * CFrame.new(0, 7.3, 0.7), Vector3.new(13.6, 15.8, 4)) do
		if part.Name == "Pier" then
			part:Destroy()
		end
	end

	--[[
		On the room's side of the wall, not the far side of it.

		The panel was hung seven tenths of a stud *behind* the basis, and the
		wall it is cut into is a stud and a half thick — so on all four
		properties the order along the line of sight was bars, then masonry,
		then the hole. What a player saw through the grate was the inside
		face of the cellar wall: the way out looked shut in the sense of
		bricked up, which is not the same thing as locked, and the black
		panel that was supposed to say "somewhere" had never been visible.

		Set in front of the wall's face and inside the grate's own depth, so
		it is what the bars are drawn against.
	]]
	Build.part({
		name = "ExitVoid",
		size = Vector3.new(12.4, 14.6, 0.6),
		cframe = basis * CFrame.new(0, 7.3, -0.7),
		color = Color3.fromRGB(9, 8, 10),
		material = Enum.Material.SmoothPlastic,
		parent = parent,
	})

	--[[
		The surround, in the masonry the property is actually built of.

		This was The House's dark brick everywhere, which was right while
		there was one property. A suburban brick jamb is a stranger in an
		estate's stone cellar, against a filling station's block wall and in a
		granite crypt — the same fault the room skins exist to fix, in the one
		piece of a property that means you are finished.
	]]
	local SURROUND: { [string]: { colour: Types.Color3Like, material: Enum.Material } } = {
		estate = { colour = Palette.estate.stoneShade, material = Enum.Material.Sandstone },
		lot = { colour = Palette.station.dark, material = Enum.Material.Concrete },
		churchyard = { colour = Palette.churchyard.graniteDark, material = Enum.Material.Rock },
	}
	local surround = SURROUND[world.style or ""]
	local brick = if surround
		then Palette.color(surround.colour)
		else Palette.color(Palette.house.brickDark)
	local masonry = if surround then surround.material else Enum.Material.Brick
	for _, jamb in { -1, 1 } do
		Build.part({
			name = "ExitJamb",
			size = Vector3.new(1.6, 16, 2),
			cframe = basis * CFrame.new(jamb * 7, 8, 0),
			color = brick,
			material = masonry,
			parent = parent,
		})
	end

	--- The lintel, which is also what the sign hangs from.
	local frame = Build.part({
		name = "ExitFrame",
		size = Vector3.new(15.6, 2.2, 2),
		cframe = basis * CFrame.new(0, 15, 0),
		color = brick,
		material = masonry,
		parent = parent,
	})

	local grate = Build.mesh({
		prop = "Grate",
		name = "ExitGrate",
		size = Vector3.new(11, 13, 2),
		collisionSize = Vector3.new(11, 13, 1),
		cframe = basis * CFrame.new(0, 6.5, -0.8),
		parent = parent,
	})
	grate:SetAttribute("Shut", true)

	-- Above the gate's raised position, not the block's top: opened, the gate
	-- rises ten studs and a sign hung at eleven was read through its bars.
	-- Lower underground, where eighteen would put it out through the lawn.
	local gui = Build.billboard(frame, UDim2.fromScale(9, 3), if underground then 4 else 11, 220)
	Build.label(gui, "WAY OUT", UDim2.fromScale(1, 0.55), UDim2.fromScale(0, 0), 2).Name = "Title"
	-- Named, because two things write to it and both used to find it by
	-- reading what it currently said.
	Build.label(gui, "Locked", UDim2.fromScale(1, 0.4), UDim2.fromScale(0, 0.58), 1.1).Name = "Status"

	exitPart = grate
end

--- The line under WAY OUT, or nil when the exit has not been built.
local function exitStatusLabel(): TextLabel?
	local grate = exitPart
	local frame = grate and grate.Parent and grate.Parent:FindFirstChild("ExitFrame")
	local gui = frame and frame:FindFirstChildOfClass("BillboardGui")
	local label = gui and gui:FindFirstChild("Status")
	return if label and label:IsA("TextLabel") then label else nil
end

--[[
	What is still holding the grate shut.

	It said "Locked" and nothing else for a whole run. That is fine while
	there is obviously work left, and it is a dead end at the point it
	matters: The House's Pool Deck is a required section that sits off the
	completion chain behind an eighteen dollar gate, so a player can clear
	the front yard, the backyard, the maze, the farm and the basement — the
	entire chain, in order, as the game led them — walk up to the way out
	and be told "Locked" with no indication anywhere that a door they walked
	past an hour ago is the reason. The sign is the one thing looking at them
	when they ask the question, so it is the thing that answers.
]]
function WorldService.setExitStatus(text: string)
	local label = exitStatusLabel()
	if label then
		label.Text = text
	end
end

--[[
	Opens the grate and puts a prompt on it.

	The prompt matters: walking out has to be a deliberate act, so nobody ends
	the run for the server by wandering past it while still working.
]]
function WorldService.openExit()
	local grate = exitPart
	if not grate or not grate:GetAttribute("Shut") then
		return
	end
	grate:SetAttribute("Shut", false)

	--[[
		Open has to look like something.

		Shut, the grate is an arched iron gate set in a brick block, and it
		reads. Open, it was faded to three-quarters transparent neon green
		over dark brick — which from any distance is nothing at all, so the
		block that had a gate in it now had none: "open" looked like a wall,
		with only the sign's small text to say otherwise. Walked up to at the
		end of the Gas Station with every section clear, the way out was a
		brick monolith on a lawn.

		A portcullis that has gone up is the shape everybody knows. The gate
		rises clear of the arch, stays solid, and the doorway it leaves is lit
		in the cash green so it carries across the property. The prompt moves
		to the doorway, where the player actually stands.
	]]
	grate.CanCollide = false
	local lift = grate.Size.Y * 0.8
	TweenService:Create(grate, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = grate.CFrame + Vector3.new(0, lift, 0),
	}):Play()

	-- Half a stud in front of where the gate hung: the gate's own centre is
	-- inside the front of the brick, so a panel left there was buried in it.
	local doorway = Build.part({
		name = "ExitDoorway",
		size = Vector3.new(grate.Size.X - 1.5, grate.Size.Y - 1.5, 0.3),
		cframe = grate.CFrame * CFrame.new(0, 0, -0.5),
		color = Palette.color(Palette.ui.cash),
		material = Enum.Material.Neon,
		transparency = 0.15,
		canCollide = false,
		parent = grate.Parent,
	})
	doorway.CanQuery = false

	WorldService.setExitStatus("Open — leave to finish")

	--[[
		Walk out. There is nothing left to press.

		This was a prompt with a hold on it, and the reasoning was that
		leaving has to be deliberate so nobody ends the run for the server by
		wandering past the grate while still working. That cannot happen: the
		grate is shut, and solid, until every required section is clear —
		which is to say until there is no work left to wander away from. Once
		it is open, walking through the way out is the only thing left to do
		on the property, and a door you have to stand at and hold a button on
		is a door that does not behave like a door.

		Once each, because a doorway is touched many times a second by every
		limb that passes through it.
	]]
	local left: { [Player]: boolean } = {}
	doorway.CanTouch = true
	doorway.Touched:Connect(function(hit: BasePart)
		local character = hit:FindFirstAncestorOfClass("Model")
		local player = if character then Players:GetPlayerFromCharacter(character) else nil
		if player and not left[player] then
			left[player] = true
			exitSignal:Fire(player)
		end
	end)
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

WorldService.shedPart = nil :: BasePart?
WorldService.trailerPart = nil :: BasePart?
WorldService.sectionSigns = {} :: { [string]: BasePart }

--- Tears down the previous world and generates `worldId`.
--[[
	Debris built over is debris nobody can see.

	A tile is seeded before anything is built on top of it, so the porch deck,
	a flight of steps, a gate arch and the upgrade stations all end up standing
	on ground that was sown. Those clippings are inside a structure: you cannot
	see them, and because cutting is decided by where you stand rather than
	what you can see, the only way to clear them is to walk onto the porch and
	mow what looks like bare boards. That is the last two percent of a section
	spent hunting for nothing, which is exactly the tedium the clutter is
	supposed to replace.

	So once the world is built, whatever it built over is swept. A room's own
	ceiling does not count — a roofed room is somewhere you walk into, not
	something standing on top of you.
]]
local BURIES_NOTHING: { [string]: boolean } = { Ceiling = true, Eaves = true }

local function clearBuriedTiles(world: Types.WorldDef, grid: Grid.Grid, tiles: buffer)
	local root = container
	if not root then
		return
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { root }
	params.MaxParts = 6

	--[[
		Something standing on this tile, or close enough to it that a tuft
		drawn here would come out through its side.

		This was a ray fired upward from a stud and a half above the floor. A
		ray does not hit the part it starts inside, and a wall or a bin
		standing on a tile is exactly that — so a tile under a wall was never
		found, and its tuft was drawn straight through the brick. It also only
		counted a hit that could be collided with, and clutter cannot, so the
		grass under every bin and barrel stayed sown and stayed hidden, which
		is a tile you have to clear and cannot see.

		A box asked over the tile's footprint has neither blind spot. It is
		a touch narrower than the tile, so a wall has to actually stand on
		the tile to claim it rather than merely border it.
	]]
	--[[
		As tall as a player, not as tall as a crate.

		Two and a half studs of box catches anything standing on the tile and
		misses anything hanging over it. The Gas Station's workshop benches
		are the case that found this: the top is a plank at four and a half
		studs on legs set back from the tile's centre, so the sweep saw
		nothing, left the tile sown — and a player cannot stand under a bench
		to mow it, because their head is where the plank is. Four tiles of the
		workshop were sown and unreachable, which is a section that cannot
		reach zero, which is a property that cannot be finished.

		What the sweep is really asking is "can somebody stand here", so the
		box is the height of somebody standing. A room's own ceiling and eaves
		are named exceptions already, and the things that overhang higher than
		this — a lychgate roof at eighteen studs, a mausoleum's lintel at nine
		— are still well clear of it.
	]]
	local COVER_FOOTPRINT = Vector3.new(3.2, 5.2, 3.2)
	local function covered(x: number, y: number, z: number): boolean
		for _, part in workspace:GetPartBoundsInBox(CFrame.new(x, y + 2.7, z), COVER_FOOTPRINT, params) do
			if BURIES_NOTHING[part.Name] then
				continue
			end
			local folder = part.Parent
			local clutter = folder ~= nil and string.sub(folder.Name, 1, 8) == "Clutter_"
			--[[
				Paving buries a tile, and had to be named to do it.

				A slab is `canCollide = false` — you walk over a path, you do
				not bump into it — and it lives in a folder called `Paving`
				rather than `Clutter_`, so it satisfied neither half of this
				test. Every stone in every path had whatever was sown under
				it still sown, and the tufts came up through the stone: a
				front garden with grass growing out of the middle of its own
				flagstones, which is the complaint that keeps coming back.
			]]
			local paving = folder ~= nil and folder.Name == "Paving"
			if part.CanCollide or clutter or paving then
				return true
			end
		end
		return false
	end

	for _, section in world.sections do
		local state = WorldService.sections[section.id]
		if state then
			local elevation = section.elevation or 0
			local r = section.rect
			for tz = r.z, math.min(r.z + r.d - 1, grid.depth - 1) do
				for tx = r.x, math.min(r.x + r.w - 1, grid.width - 1) do
					local index = Grid.toIndex(grid, tx, tz)
					if WorldService.tileSection and WorldService.tileSection[index] == section.id then
						--[[
							Every tile is asked, not only the sown ones.

							Clearing only needs to touch a tile that has
							something on it, so this used to skip the rest. But
							the answer is also the record a wave refill reads,
							and at a density of 0.94 roughly one tile in
							sixteen under the porch was simply never sown — so
							it was never asked, never remembered, and came
							straight back on the next wave. One is enough to
							stop a section reaching zero.
						]]
						local x, z = Grid.tileToWorld(grid, tx, tz)
						if covered(x, elevation, z) then
							WorldService.buriedTiles[index] = true
							local byte = buffer.readu8(tiles, index - 1)
							if ChunkCodec.height(byte) > 0 then
								local units = Cutting.unitsOnTile(byte)
								buffer.writeu8(tiles, index - 1, 0)
								state.totalUnits -= units
								state.remainingUnits -= units
								WorldService.totalUnits -= units
								WorldService.remainingUnits -= units
							end
						end
					end
				end
			end
		end
	end

	-- The client was handed the total at attach time, before any of this was
	-- built; without this the bar can never reach a hundred.
	ReplicationService.setTotalUnits(WorldService.totalUnits)
end

--[[
	Clears the one tile something is about to stand on.

	`clearBuriedTiles` above is the sweep, and it runs once, just after `Built`
	— but `Built` is a BindableEvent, and a BindableEvent's handlers are
	deferred: they do not run at the `Fire`, they run at the next resumption
	point. The sweep yields, so tree planting and the sweep interleave, and any
	trunk that goes up after the sweep has passed its own tile keeps whatever
	was sown there. Measured across the four properties: one tile on the
	Mansion, two on The House, six on the Gas Station, seven on the Cemetery.

	That is not a cosmetic miss. A section is clear at `remainingUnits <= 0`
	and nothing short of it, a trunk is three and a half studs across on a
	four-stud tile, so nobody can stand on one — and the promise the tree
	service is written around is that everything lying on a tile can be
	cleared with bare hands. Seven tiles nobody can reach on the starting
	section of the last property is that property unfinishable.

	So a builder that puts something solid down after the sweep clears its own
	tile, which needs no ordering to be right.
]]
function WorldService.clearTileAt(worldX: number, worldZ: number)
	local grid, tiles = WorldService.grid, WorldService.tiles
	if not grid or not tiles then
		return
	end
	local tx, tz = Grid.worldToTile(grid, worldX, worldZ)
	if not Grid.inBounds(grid, tx, tz) then
		return
	end
	local index = Grid.toIndex(grid, tx, tz)
	-- Remembered whether or not anything was sown here, because the record is
	-- what a wave refill reads to know not to sow it again.
	WorldService.buriedTiles[index] = true

	local byte = buffer.readu8(tiles, index - 1)
	if ChunkCodec.height(byte) <= 0 then
		return
	end
	local sections = WorldService.tileSection
	local state = WorldService.sections[(if sections then sections[index] else nil) or ""]
	local units = Cutting.unitsOnTile(byte)
	buffer.writeu8(tiles, index - 1, 0)
	if state then
		state.totalUnits -= units
		state.remainingUnits -= units
	end
	WorldService.totalUnits -= units
	WorldService.remainingUnits -= units
	ReplicationService.setTotalUnits(WorldService.totalUnits)
end

--[[
	A statue of the owner, on the lawn in front of the house.

	`CreateHumanoidModelFromUserId` builds the avatar as it stands today,
	which is the whole point of a likeness, so it is fetched when the
	property is built rather than baked into the place. It is also a web
	call: it goes in a thread of its own behind a pcall, and if it fails the
	lawn has an empty plinth on it rather than no world at all.

	Everything that makes an avatar an avatar comes off — the humanoid so it
	cannot animate or fall over, the animations that drive it, the shirt, the
	trousers, the skin colours and every texture on every mesh. A statue is
	one stone. What is left is the shape, which is the part that looks like
	somebody.

	The figure does not collide and the plinth does: the plinth is what
	stands on the lawn, so the plinth is what takes its own tile out of the
	section's work, and it is built before the buried-tile sweep runs while
	the figure may well arrive after it.
]]
local STATUE_OF = 1213625298

local function buildStatue(foot: CFrame, parent: Folder, body: Color3, stone: Color3)
	local DIE, TALL = 7, 10
	Build.part({
		name = "StatueBase",
		size = Vector3.new(DIE + 2.4, 1.4, DIE + 2.4),
		cframe = foot * CFrame.new(0, 0.7, 0),
		color = body,
		material = Enum.Material.Sandstone,
		parent = parent,
	})
	Build.part({
		name = "StatuePlinth",
		size = Vector3.new(DIE, TALL, DIE),
		cframe = foot * CFrame.new(0, TALL * 0.5, 0),
		color = body,
		material = Enum.Material.Sandstone,
		parent = parent,
	})
	Build.part({
		name = "StatueCap",
		size = Vector3.new(DIE + 1.8, 1.2, DIE + 1.8),
		cframe = foot * CFrame.new(0, TALL + 0.6, 0),
		color = body,
		material = Enum.Material.Sandstone,
		parent = parent,
	})

	--- The plaque, on the face you walk up to.
	local plaque = Build.part({
		name = "StatuePlaque",
		--- Wider than the die it is bolted to, which is what an inscription
		--- tablet is, and wide enough for a name to sit on one line.
		size = Vector3.new(DIE + 1.6, 1.7, 0.4),
		cframe = foot * CFrame.new(0, TALL * 0.58, -(DIE * 0.5 + 0.15)),
		color = Palette.color(Palette.estate.lead),
		material = Enum.Material.Metal,
		canCollide = false,
		parent = parent,
	})

	--- Filled in below, off the main thread: naming a user is a web call and
	--- the world does not wait on one.
	local label = Build.painted(plaque, Enum.NormalId.Front, 0.86)
	label.Text = ""
	label.TextColor3 = Palette.color(Palette.estate.quoin)
	--[[
		A fixed size on one line, not scaled to the box.

		Scaled, a thirteen-letter name with no spaces in it broke across two
		rows in the middle of a syllable — "UncleNickR / ush". Turning
		wrapping off is not the fix either: `TextScaled` implies wrapping, so
		clearing one clears the other and the label fell back to eight
		point, which from the drive is a blank grey band. A size the plaque
		was cut to fit is the answer.
	]]
	label.TextWrapped = false
	label.TextScaled = false
	label.TextSize = 36

	task.spawn(function()
		local named, who = pcall(function()
			return Players:GetNameFromUserIdAsync(STATUE_OF)
		end)
		label.Text = if named and typeof(who) == "string" then who else "The Owner"

		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromUserId(STATUE_OF)
		end)
		if not ok or typeof(model) ~= "Instance" then
			warn(`[Statue] avatar {STATUE_OF} did not load: {model}`)
			return
		end
		local figure = model :: Model
		--- Anything that would move it, dress it or colour it.
		for _, thing in figure:GetDescendants() do
			if
				thing:IsA("Humanoid")
				or thing:IsA("LuaSourceContainer")
				or thing:IsA("Animation")
				or thing:IsA("Constraint")
				or thing:IsA("BodyColors")
				or thing:IsA("Clothing")
				or thing:IsA("ShirtGraphic")
				or thing:IsA("Decal")
				or thing:IsA("SurfaceAppearance")
				or thing:IsA("BindableFunction")
			then
				thing:Destroy()
			end
		end
		for _, thing in figure:GetDescendants() do
			if thing:IsA("BasePart") then
				thing.Anchored = true
				thing.CanCollide = false
				thing.CanQuery = false
				thing.CanTouch = false
				thing.Massless = true
				thing.Color = stone
				thing.Material = Enum.Material.Sandstone
				thing.Transparency = 0
				thing.Reflectance = 0
				if thing:IsA("MeshPart") then
					thing.TextureID = ""
				end
			end
		end

		local _, natural = figure:GetBoundingBox()
		if natural.Y > 0.1 then
			figure:ScaleTo(14 / natural.Y)
		end
		figure:PivotTo(foot * CFrame.new(0, TALL + 1.2, 0))
		--[[
			Stood on the cap rather than trusted to the pivot: an avatar's
			pivot is its root part, which is at the hips, so pivoting it to
			the top of the plinth buries it to the waist.
		]]
		local pivot, size = figure:GetBoundingBox()
		local base = pivot.Position.Y - size.Y * 0.5
		local want = (foot * CFrame.new(0, TALL + 1.2, 0)).Position.Y
		figure:PivotTo(CFrame.new(0, want - base, 0) * figure:GetPivot())
		figure.Name = "Statue"
		figure.Parent = parent
	end)
end

function WorldService.load(worldId: string)
	local world = Worlds.expect(worldId)

	if container then
		container:Destroy()
	end
	container = Build.folder("MowWorld", Workspace)
	local parent = container :: Folder

	local grid = Grid.new(world.gridWidth, world.gridDepth)
	local tiles = buffer.create(Grid.tileCount(grid))

	WorldService.grid = grid
	WorldService.tiles = tiles
	WorldService.world = world
	table.clear(openSections)
	-- Tile indices belong to the grid that produced them, so last world's
	-- buried set would suppress seeding at unrelated places in this one.
	-- Keyed by section id, and ids repeat between properties, so last world's
	-- gates would otherwise be found and raised on this one.
	table.clear(sectionGates)
	table.clear(WorldService.buriedTiles)

	-- Before anything is sown or scattered, so the whole property comes out
	-- the same on every server that builds it. Published, because the
	-- services that plant and hide things build on top of this one and have
	-- to agree with it about which property this is.
	WorldService.seed = seedOf(world)
	rng = Random.new(WorldService.seed)

	seedTiles(world, grid, tiles)

	-- The replicator is handed the buffer it is to stream, rather than reaching
	-- back here for it. Done after seeding so the totals it reports to joiners
	-- are the finished ones.
	ReplicationService.attach(grid, tiles, {
		worldId = world.id,
		width = grid.width,
		depth = grid.depth,
		totalUnits = WorldService.totalUnits,
	})
	buildGround(world, grid, parent)
	if world.style == "estate" then
		buildManor(world, parent)
	else
		buildHouse(world, parent)
	end
	WorldService.shedPart = buildShed(world, parent)
	WorldService.trailerPart = buildTrailer(world, parent)
	WorldService.sectionSigns = buildSectionSigns(world, parent)
	cashGates = buildCashGates(world, parent)
	buildUpgradeStations(world, parent)
	-- Cleared before the sections are built, because building the sunken room
	-- is what fills it in.
	cellarExit = nil
	buildSectionStructures(world, parent)
	buildSwitches(world, parent)
	exitPart = nil
	buildExit(world, parent)

	-- Fence the outer boundary so the lot reads as a world, not a plane.
	local width = grid.width * TILE
	local depth = grid.depth * TILE

	if world.style == "house" then
		-- Picket fencing on three sides, open at the kerb where players arrive.
		local fences = Build.folder("Fences", parent)
		local corners = {
			{ Vector3.new(0, 0, 0), Vector3.new(0, 0, depth) },
			{ Vector3.new(0, 0, depth), Vector3.new(width, 0, depth) },
			{ Vector3.new(width, 0, depth), Vector3.new(width, 0, 0) },
		}
		for index, run in corners do
			Build.picketFence(fences, run[1], run[2], 9, index == 2)
		end

		--[[
			Hedges along the side yard. The court wall that used to run with
			them is gone.

			It was a brick retaining wall topped with chain-link, copied from
			the reference, where it borders a court. There is no court here.
			It stood ten studs inside the picket fence that already closes
			that boundary, so what it actually made was a second barrier
			parallel to the first with a strip of unreachable grass between
			them — and because the chain-link panel above it is translucent
			and thin, all that read at play distance was a brick wall with
			green poles sticking out of the top of it for no reason.

			Reported from the game as a wall next to the pool that does not do
			anything, which is exactly what it was.
		]]
		local scenery = Build.folder("Scenery", parent)
		--[[
			The side hedge is thick enough to meet the house.

			At seven studs deep its west face stood three and a half studs
			clear of the house's foundation, and it runs the whole length of
			that wall — so between the two there was a crevice the length of
			the building, narrower than a player and open at the front. Walk
			east along the house and you slide into it and wedge, and the only
			way out is backwards. Measured in the running game at 3.5 studs;
			a character is four.

			Twelve closes it against the foundation without moving the run, so
			the corner where this meets the back hedge is untouched and the
			east path to the roof stairs — thirty studs wide out there — is
			unchanged. A deeper hedge is also just a hedge.
		]]
		Build.hedge(scenery, WorldService.tilePointFlat(72, 8), WorldService.tilePointFlat(72, 54), 13, 12)
		--[[
			The back hedge stops short of the pool gate.

			It ran from tile 24, which put its first block seven studs in
			front of the gate's door and dead on its centre line — thirteen
			studs of hedge standing in a doorway. Walk at the gate from the
			backyard and you meet a wall, and have to go round the end of it
			and back again to reach a door you were looking straight at.

			From 27 the run still separates the backyard from the maze along
			every part of that edge anybody walks, and the west end of it is
			now the way through to the pool, which is what that corner is.
		]]
		Build.hedge(scenery, WorldService.tilePointFlat(27, 78), WorldService.tilePointFlat(72, 78), 13, 7)

		--[[
			A flagstone path from the kerb to the porch, and a driveway from
			the kerb to the garage doors.

			The rectangles come from Worlds.pavingRects — the same ones the
			tree and clutter scatters keep off of — so the slabs land on the
			door and bay axes of whichever house this lot builds, not the
			tiles they were once measured at on The House.
		]]
		for _, slab in Worlds.pavingRects(world) do
			Build.flagstone(
				parent,
				Vector3.new(slab.x + slab.w * 0.5, GameConfig.GROUND_Y + 0.25, slab.z + slab.d * 0.5),
				Vector2.new(slab.w, slab.d),
				slab.stone,
				rng
			)
		end
	elseif world.style == "estate" then
		--[[
			The grounds of an estate, which is the other half of why the
			second property used to look like the first.

			Everything below the house was shared too: the same white picket
			fence round three sides, the same two garden hedges — placed, as
			it happens, at The House's own tile numbers, so on a grid half as
			big again they landed in the middle of nothing — and the same grey
			flagstone path and driveway. A player walked out of one property
			and into a bigger copy of it.

			An estate has a boundary wall rather than a fence, gates rather
			than a gap at the kerb, a gravel carriage drive rather than a
			garden path, and a parterre rather than two hedges: clipped yew
			in a shape, with a fountain in the middle of it. None of it is
			decoration for its own sake — it is what tells you at a glance
			which of the two places you are standing in.
		]]
		local estate = Build.folder("Estate", parent)
		local ground = GameConfig.GROUND_Y
		local stone = Palette.color(Palette.estate.stone)
		local quoin = Palette.color(Palette.estate.quoin)
		local lead = Palette.color(Palette.estate.lead)
		local iron = Palette.color(Palette.estate.iron)
		local yew = Palette.color(Palette.estate.yew)

		--------------------------------------------------------------------
		-- The boundary wall
		--------------------------------------------------------------------

		--[[
			A stone wall with piers, on the three sides the picket fence used
			to close. The kerb is left open the same way, because that is
			where the players arrive; the gates below stand in that opening.
		]]
		local WALL_H, WALL_T, PIER_GAP = 11, 2.4, 34
		local runs = {
			{ Vector3.new(0, 0, 0), Vector3.new(0, 0, depth) },
			{ Vector3.new(0, 0, depth), Vector3.new(width, 0, depth) },
			{ Vector3.new(width, 0, depth), Vector3.new(width, 0, 0) },
		}
		--[[
			Where a pier already stands.

			Every run puts one at each of its own ends, and consecutive runs
			share an end, so both back corners of the estate were carrying two
			identical piers in exactly the same place — five studs of sandstone
			inside another five studs of sandstone, with their faces on the
			same planes.
		]]
		local piered: { [string]: boolean } = {}
		for _, run in runs do
			local from, to = run[1], run[2]
			local delta = to - from
			local length = delta.Magnitude
			local along = delta.Unit
			local mid = from + delta * 0.5
			local across = Vector3.new(-along.Z, 0, along.X)
			Build.part({
				name = "EstateWall",
				size = Vector3.new(
					math.abs(along.X) * length + math.abs(across.X) * WALL_T,
					WALL_H,
					math.abs(along.Z) * length + math.abs(across.Z) * WALL_T
				),
				cframe = CFrame.new(mid + Vector3.new(0, ground + WALL_H * 0.5, 0)),
				color = stone,
				material = Enum.Material.Sandstone,
				parent = estate,
			})
			-- A lead coping, so the top of the wall is a line and not an edge.
			Build.part({
				name = "WallCoping",
				size = Vector3.new(
					math.abs(along.X) * length + math.abs(across.X) * (WALL_T + 1.4),
					1.1,
					math.abs(along.Z) * length + math.abs(across.Z) * (WALL_T + 1.4)
				),
				cframe = CFrame.new(mid + Vector3.new(0, ground + WALL_H + 0.55, 0)),
				color = lead,
				material = Enum.Material.Metal,
				parent = estate,
			})
			local piers = math.max(math.floor(length / PIER_GAP), 1)
			for index = 0, piers do
				local at = from + along * (length * index / piers)
				local key = string.format("%.0f,%.0f", at.X, at.Z)
				if piered[key] then
					continue
				end
				piered[key] = true
				Build.part({
					name = "Pier",
					size = Vector3.new(5, WALL_H + 4, 5),
					cframe = CFrame.new(at + Vector3.new(0, ground + (WALL_H + 4) * 0.5, 0)),
					color = quoin,
					material = Enum.Material.Sandstone,
					parent = estate,
				})
			end
		end

		--------------------------------------------------------------------
		-- The gates
		--------------------------------------------------------------------

		local spawnAt = WorldService.tilePointFlat(world.spawn.x, world.spawn.z)
		local GATE_HALF = 17
		for _, side in { -1, 1 } do
			Build.part({
				name = "GatePier",
				size = Vector3.new(7, 24, 7),
				cframe = CFrame.new(spawnAt.X + side * GATE_HALF, ground + 12, ground + 4),
				color = quoin,
				material = Enum.Material.Sandstone,
				parent = estate,
			})
			-- A stone ball on each, which is the one detail everybody draws
			-- when they draw a gatepost.
			Build.part({
				name = "GateBall",
				shape = Enum.PartType.Ball,
				size = Vector3.new(5, 5, 5),
				cframe = CFrame.new(spawnAt.X + side * GATE_HALF, ground + 26.5, ground + 4),
				color = quoin,
				material = Enum.Material.Sandstone,
				parent = estate,
			})
			--- The leaf itself, swung open against its pier.
			Build.mesh({
				prop = "Gate",
				name = "GateLeaf",
				untextured = true,
				color = iron,
				size = Vector3.new(14, 18, 1.4),
				collisionSize = Vector3.new(1.4, 18, 14),
				cframe = CFrame.new(spawnAt.X + side * (GATE_HALF - 1), ground + 9, ground + 11)
					* CFrame.Angles(0, math.rad(side * 78), 0),
				canCollide = false,
				parent = estate,
			})
		end

		--------------------------------------------------------------------
		-- The carriage drive
		--------------------------------------------------------------------

		--[[
			Gravel, not flagstone, and a circle rather than a path.

			`Worlds.pavingRects` reports the same rectangles to the tree and
			clutter scatters, so nothing is planted through the drive for the
			same reason nothing is planted through The House's path.

			Pebble, not Sand. Roblox's sand carries a heavy rolling ripple in
			its normal map, which on a hundred and eighty studs of pale drive
			straight up to the front door read as a beach — dunes across the
			whole approach to the house. Pebble is the small hard chip a
			carriage drive is actually made of.
		]]
		--[[
			Each rectangle a hundredth of a stud above the last.

			The drive is a union of overlapping rectangles — the circle in
			front of the door and the straight run out to the road cross each
			other — and laid at one height the overlaps flickered. A step this
			small is nothing to walk over and nothing to see.
		]]
		for index, slab in Worlds.pavingRects(world) do
			Build.part({
				name = "Drive",
				size = Vector3.new(slab.w, 0.5, slab.d),
				cframe = CFrame.new(
					slab.x + slab.w * 0.5,
					ground + 0.25 + index * 0.04,
					slab.z + slab.d * 0.5
				),
				color = Palette.color(Palette.estate.gravel),
				material = Enum.Material.Pebble,
				castShadow = false,
				parent = estate,
			})
		end

		--------------------------------------------------------------------
		-- The fountain, in the middle of the circle
		--------------------------------------------------------------------

		--[[
			On the house's axis, not the spawn's.

			The drive is laid by `Worlds.pavingRects`, which measures from the
			middle of `houseRect`; the fountain took its x from the spawn
			instead, and the two are a tile apart. So the basin, the parterre
			around it and the urns up either side all stood four studs to one
			side of the drive they are the middle of, and of the door they
			point at. On a formal front, the axis is the whole composition.
		]]
		local hr = world.houseRect
		local axisTile = if hr then hr.x + hr.w * 0.5 else world.spawn.x
		local axis = WorldService.tilePointFlat(axisTile, world.spawn.z)
		local circle = Vector3.new(
			axis.X,
			ground,
			if hr then (hr.z * TILE + TILE * 0.5) - 46 else spawnAt.Z + 60
		)

		local basinR = 15
		Build.part({
			name = "FountainBasin",
			shape = Enum.PartType.Cylinder,
			size = Vector3.new(4.5, basinR * 2, basinR * 2),
			cframe = CFrame.new(circle + Vector3.new(0, 2.25, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			color = quoin,
			material = Enum.Material.Sandstone,
			parent = estate,
		})
		Build.part({
			name = "FountainWater",
			shape = Enum.PartType.Cylinder,
			size = Vector3.new(0.6, basinR * 2 - 3, basinR * 2 - 3),
			cframe = CFrame.new(circle + Vector3.new(0, 4.3, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			color = Palette.color(Palette.estate.water),
			material = Enum.Material.Glass,
			transparency = 0.3,
			canCollide = false,
			parent = estate,
		})
		--[[
			Round bowls on a round stem, each of them holding water.

			The three tiers were always cylinders and always read as square,
			because the thing running up through the middle of them was a
			two-stud block twelve studs tall — a square post in a round
			basin, with a stud and a half of daylight between each disc and
			nothing in any of them. What you saw from the drive was a stack
			of slabs on a chimney standing in a pond.

			A stem that is round and steps in as it rises, a lip round each
			bowl so it has an edge to hold anything, a sheet of water in it,
			and a ball on the top: a fountain is a thing water comes out of
			and down, and none of that was legible.
		]]
		local water = Palette.color(Palette.estate.water)
		local BOWLS = { { across = 9, at = 9.2 }, { across = 6, at = 13.6 }, { across = 3.6, at = 17 } }
		local stemBase = 4
		for index, bowl in BOWLS do
			--- The shaft up to this bowl, narrower each time.
			local shaft = 4 - (index - 1) * 0.8
			local top = bowl.at - 0.7
			Build.part({
				name = "FountainStem",
				shape = Enum.PartType.Cylinder,
				size = Vector3.new(top - stemBase, shaft, shaft),
				cframe = CFrame.new(circle + Vector3.new(0, (stemBase + top) * 0.5, 0))
					* CFrame.Angles(0, 0, math.rad(90)),
				color = quoin,
				material = Enum.Material.Sandstone,
				parent = estate,
			})
			Build.part({
				name = "FountainTier",
				shape = Enum.PartType.Cylinder,
				size = Vector3.new(1.4, bowl.across, bowl.across),
				cframe = CFrame.new(circle + Vector3.new(0, bowl.at, 0))
					* CFrame.Angles(0, 0, math.rad(90)),
				color = quoin,
				material = Enum.Material.Sandstone,
				parent = estate,
			})
			Build.part({
				name = "FountainLip",
				shape = Enum.PartType.Cylinder,
				size = Vector3.new(0.7, bowl.across + 0.9, bowl.across + 0.9),
				cframe = CFrame.new(circle + Vector3.new(0, bowl.at + 0.7, 0))
					* CFrame.Angles(0, 0, math.rad(90)),
				color = quoin,
				material = Enum.Material.Sandstone,
				parent = estate,
			})
			Build.part({
				name = "FountainWater",
				shape = Enum.PartType.Cylinder,
				size = Vector3.new(0.4, bowl.across - 0.4, bowl.across - 0.4),
				cframe = CFrame.new(circle + Vector3.new(0, bowl.at + 0.85, 0))
					* CFrame.Angles(0, 0, math.rad(90)),
				color = water,
				material = Enum.Material.Glass,
				transparency = 0.3,
				castShadow = false,
				canCollide = false,
				parent = estate,
			})
			stemBase = bowl.at + 0.5
		end
		--- The jet the whole thing is built under.
		Build.part({
			name = "FountainFinial",
			shape = Enum.PartType.Ball,
			size = Vector3.new(2.2, 2.2, 2.2),
			cframe = CFrame.new(circle + Vector3.new(0, 18.9, 0)),
			color = quoin,
			material = Enum.Material.Sandstone,
			parent = estate,
		})

		--------------------------------------------------------------------
		-- The parterre, and an avenue to the gates
		--------------------------------------------------------------------

		--[[
			Clipped yew in a shape, either side of the drive.

			Low and dark, which is what separates a parterre from the garden
			hedge on the first property: that one is bright green and taller
			than a player, and it is a boundary. This is a pattern you look
			down on and walk around.
		]]
		local PARTERRE = 3.5
		for _, side in { -1, 1 } do
			local x = circle.X + side * 40
			Build.hedge(estate, Vector3.new(x - 22, ground, circle.Z - 20), Vector3.new(x + 22, ground, circle.Z - 20), PARTERRE, 4, yew)
			Build.hedge(estate, Vector3.new(x - 22, ground, circle.Z + 20), Vector3.new(x + 22, ground, circle.Z + 20), PARTERRE, 4, yew)
			Build.hedge(estate, Vector3.new(x - 22, ground, circle.Z - 20), Vector3.new(x - 22, ground, circle.Z + 20), PARTERRE, 4, yew)
			Build.hedge(estate, Vector3.new(x + 22, ground, circle.Z - 20), Vector3.new(x + 22, ground, circle.Z + 20), PARTERRE, 4, yew)
		end

		--[[
			Urns on plinths down the drive, in pairs. `Structures.urn` says
			what one is made of and why; the old one here was a five-stud
			ball on a four-stud box, and it overhung its plinth far enough to
			reach across the tile boundary it stood on and clip the top of a
			player's head on the next tile along.

			On tile centres, too, and not across the seam between two.

			Twenty-six studs off the drive's middle is six and a half tiles,
			so every plinth stood on the boundary between two of them —
			burying half of each, taking two tiles of work out where it only
			occupies one, and putting its own widest moulding exactly where
			the next tile's headroom is. Said in tiles it lands on a tile,
			and it goes on landing on one whatever a property's spawn is.
		]]
		local stoneShade = Palette.color(Palette.estate.stoneShade)
		for index = 0, 3 do
			for _, side in { -1, 1 } do
				local at = WorldService.tilePointFlat(
					math.round(axisTile) + side * 7,
					world.spawn.z + 4 + index * 7
				)
				Structures.urn({
					foot = CFrame.new(at.X, ground, at.Z),
					plinth = 4,
					body = quoin,
					bodyMaterial = Enum.Material.Sandstone,
					stone = stoneShade,
					stoneMaterial = Enum.Material.Sandstone,
					parent = estate,
				})
			end
		end

		--[[
			And the owner, on the lawn beside the fountain.

			Not on the axis: that belongs to the fountain and the door, and a
			third thing on it would make the front read as a queue. Not in
			the middle of the west parterre either, tempting as that is — the
			drive is described by two rectangles and the parterre straddles
			the edge of the bigger one, so a statue at its centre stands on
			gravel with a hedge in front of it.

			Fourteen tiles out is the strip of lawn between the drive's edge
			and the west wing, level with the fountain, which is where you
			can stand back from it. Turned to face down the drive, so you
			meet it coming up rather than passing its back.
		]]
		local statueAt = WorldService.tilePointFlat(math.round(axisTile) - 14, world.spawn.z + 36)
		buildStatue(
			CFrame.lookAt(
				Vector3.new(statueAt.X, ground, statueAt.Z),
				Vector3.new(statueAt.X, ground, statueAt.Z - 1)
			),
			estate,
			quoin,
			stoneShade
		)
	elseif world.style == "churchyard" then
		buildChurchyard(world, parent)
		--[[
			Dwarf walls between the quarters, in the churchyard's own stone.
		]]
		buildDivisions(world, parent, {
			height = 5,
			thickness = 2.4,
			body = Palette.color(Palette.churchyard.granite),
			bodyMaterial = Enum.Material.Rock,
			cap = Palette.color(Palette.churchyard.graniteDark),
		})
	else
		local lot = world.style == "lot"
		Build.fence(
			parent,
			0,
			0,
			width,
			depth,
			if lot then 11 else 6,
			Palette.color(Palette.fence.rail),
			14,
			lot,
			-- A filling station is fenced with wire on steel, not with the
			-- back garden's picket panels. Eleven studs rather than six,
			-- because a boundary that keeps people out is over head height.
			if lot
				then { mesh = Palette.color(Palette.court.mesh), frame = Palette.color(Palette.station.dark) }
				else nil
		)
		if lot then
			buildGasStation(world, parent)
			--[[
				Chain-link between the parts of the lot, with a gate.

				A filling station is divided by wire on steel rather than by
				masonry, and the gate in each opening is the one that comes up
				when you have finished the section before it — which is how the
				lot tells you what you have earned rather than leaving it to
				the sign.
			]]
			buildDivisions(world, parent, {
				height = 9,
				thickness = 1,
				body = Palette.color(Palette.court.mesh),
				bodyMaterial = Enum.Material.Metal,
				cap = Palette.color(Palette.station.dark),
				wire = true,
			})
		end
	end

	local spawnAt = WorldService.tilePointFlat(world.spawn.x, world.spawn.z)
	local spawnPart = Build.part({
		name = "SpawnPad",
		size = Vector3.new(20, 0.4, 20),
		cframe = CFrame.new(spawnAt + Vector3.new(0, 0.2, 0)),
		color = Palette.color(Palette.ground.path),
		material = Enum.Material.Concrete,
		castShadow = false,
		parent = parent,
	})

	--[[
		Facing the work.

		A `SpawnLocation` points whichever way its CFrame does, and this one was
		built from the pad's, which is unrotated — so every player arrived
		looking down the road with the entire property behind them: the lawn,
		the trailer, the house, all of it out of shot until they thought to turn
		around. It now looks at the middle of the section the run starts in,
		levelled so nobody spawns staring at the grass or the sky.
	]]
	local startSection = Worlds.startSection(world)
	local lookAt = WorldService.tilePointFlat(
		startSection.rect.x + startSection.rect.w * 0.5,
		startSection.rect.z + startSection.rect.d * 0.5
	)
	local spawnPos = spawnPart.Position + Vector3.new(0, 0.4, 0)
	local level = Vector3.new(lookAt.X, spawnPos.Y, lookAt.Z)

	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "MowSpawn"
	spawnLocation.Size = Vector3.new(18, 0.2, 18)
	-- Guarded, because `lookAt` on two points in the same place is undefined.
	spawnLocation.CFrame = if (level - spawnPos).Magnitude > 0.5
		then CFrame.lookAt(spawnPos, level)
		else spawnPart.CFrame + Vector3.new(0, 0.4, 0)
	spawnLocation.Anchored = true
	spawnLocation.CanCollide = false
	spawnLocation.Transparency = 1
	spawnLocation.Neutral = true
	spawnLocation.Parent = parent

	-- Kept for whoever has to put players on this property. A SpawnLocation
	-- only places anybody when a character is *loaded*, and moving between
	-- worlds does not load one. See `RunService`.
	WorldService.spawnAt = spawnLocation.CFrame + Vector3.new(0, 4, 0)

	-- Trees and stumps go in now, so the two passes below can see them.
	builtSignal:Fire(world)

	-- Both of these ask what is standing where, so they wait until it is all
	-- standing. The clutter scatter runs during the build and cannot see the
	-- maze hedges, retaining walls, stairs or trunks that go up after it.
	Structures.settleClutter(parent)
	clearBuriedTiles(world, grid, tiles)

	loadedSignal:Fire(world)
end

--- Where to stand on the property now loaded, if one is.
function WorldService.spawnPoint(): CFrame?
	return WorldService.spawnAt
end

function WorldService.isLoaded(): boolean
	return WorldService.grid ~= nil
end

--------------------------------------------------------------------
-- Section gates
--------------------------------------------------------------------

--- True when this run has opened `sectionId`'s gate. Ground belonging to no
--- section — paths, the street, the shed apron — is never open, because there
--- is nothing there to clear.
function WorldService.isSectionOpen(sectionId: string): boolean
	return openSections[sectionId] == true
end

--[[
	Rolls the garage door, once, when its section opens.

	The door was twelve solid courses that never moved. Flipping the switch
	opened the section — the gate lifted, the quest ticked, the grass inside
	counted — and left the opening bricked up with a door, so the one thing
	the switch is for could not be walked through. Nothing in the game said
	why, because from the outside a shut garage door and a locked garage look
	the same.

	Each course tweens to its rolled place and stops colliding as it goes, so
	a player who flips the switch and walks straight at the opening is not
	stopped by a slat that has not finished travelling.
]]
local function rollGarage(open: boolean)
	if #garageSlats == 0 or garageOpen == open then
		return
	end
	garageOpen = open
	for index, slat in garageSlats do
		local part = slat.part
		if not part.Parent then
			continue
		end
		part.CanCollide = not open
		local goal = if open then slat.rolled else slat.shut
		-- The lowest course leads, so the door reads as lifting from the
		-- ground rather than every panel setting off at once.
		local lead = (index - 1) % GARAGE_COURSES_PER_BAY * 0.06
		TweenService:Create(
			part,
			TweenInfo.new(1.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, lead),
			{ CFrame = goal }
		):Play()
	end
end

function WorldService.setSectionOpen(sectionId: string, open: boolean)
	if sectionId == GARAGE_SECTION then
		rollGarage(open)
	end
	if open then
		openSections[sectionId] = true
		--[[
			A fenced court's gate swings when the court unlocks.

			The fence goes all the way round, so until this happens it reads
			as a boundary; the gate opening is what turns it into a way in.
			Harmless on a section that has no court in it.
		]]
		if container then
			Structures.openCourtGate(container, sectionId)
		end
		-- An open section has no door: the purchase consumes it.
		local gate = cashGates[sectionId]
		if gate then
			cashGates[sectionId] = nil
			gate:Destroy()
		end

		--[[
			Every gate this section owns swings open and stays there.

			More than one, because a section can be walled off from two
			neighbours: the Gas Station's back lot has the forecourt on one
			side and the storage yard on the other, and finishing what came
			before opens the way in from whichever side you approach.

			They are not faded out. A gate that disappears leaves a doorway
			that never had one in it, and half of what a gate is for is being
			visibly the thing that was shut a minute ago. Swung back on its
			jamb it still reads as a gate and is no longer in the way.
		]]
		local gates = sectionGates[sectionId]
		if gates then
			sectionGates[sectionId] = nil
			for _, grille in gates do
				if grille:GetAttribute("Shut") then
					grille:SetAttribute("Shut", false)
					grille.CanCollide = false
					local swung = grille:GetAttribute("Swung")
					if typeof(swung) == "CFrame" then
						TweenService:Create(
							grille,
							TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
							{ CFrame = swung }
						):Play()
					end
				end
			end
		end

	else
		openSections[sectionId] = nil
	end
end

--- Shuts every gate, for the start of a fresh run.
function WorldService.closeAllSections()
	table.clear(openSections)
	--[[
		The door is not this function's business.

		It cleared the slat list here, and a run begins by loading the world
		and then shutting its gates — so the door was built, recorded, and the
		record thrown away a moment later. `rollGarage` then had nothing to
		roll and the switch went on doing nothing, which is the bug this was
		all meant to fix. The build owns the list and resets the flag.
	]]
end

--- Fraction of the world's debris that has been cleared, 0..1.
function WorldService.completion(): number
	if WorldService.totalUnits <= 0 then
		return 1
	end
	return 1 - WorldService.remainingUnits / WorldService.totalUnits
end

--- The section whose rect contains a tile-space point, or "" for open ground.
function WorldService.sectionIdAtTile(tx: number, tz: number): string
	local grid = WorldService.grid
	if not grid or not Grid.inBounds(grid, tx, tz) then
		return ""
	end
	return WorldService.sectionIdAt(Grid.toIndex(grid, tx, tz))
end

--[[
	Fills a section's debris back up for another wave.

	Only that section's tiles are touched, and its own totals are rebuilt from
	scratch — the world totals are adjusted by the difference so a refill never
	makes the overall completion bar jump backwards past what has actually been
	cleared elsewhere.
]]
function WorldService.refillSection(sectionId: string)
	local grid = WorldService.grid
	local tiles = WorldService.tiles
	local world = WorldService.world
	local state = WorldService.sections[sectionId]
	if not grid or not tiles or not world or not state then
		return
	end

	local section = state.def
	local before = state.remainingUnits
	local fresh = 0
	local dirty: { [number]: boolean } = {}

	local r = section.rect
	-- The wave refills the lawn, not the swimming pool.
	local water = if (section.kind or "open") == "pool" then Structures.poolRect(section) else nil

	for tz = r.z, math.min(r.z + r.d - 1, grid.depth - 1) do
		for tx = r.x, math.min(r.x + r.w - 1, grid.width - 1) do
			local index = Grid.toIndex(grid, tx, tz)
			local byte = 0

			local onWater = water ~= nil
				and tx >= water.x
				and tx < water.x + water.w
				and tz >= water.z
				and tz < water.z + water.d

			--[[
				A refill obeys the same three rules the first sowing did.

				It obeyed one of them. The pool was spared and nothing else
				was, so every wave after the first re-seeded the tiles under
				the shed — which `seedTiles` skips precisely because they are
				inside a building — and every tile `clearBuriedTiles` had
				emptied under the porch deck, the steps and the walls.

				Waves are `math.max(playerCount, 1)`, so this only ever
				happened with somebody else on the server. Measured across the
				three worlds it puts back 55, 77 and 22 tiles of debris inside
				the structures each of them stands on, every wave.

				None of it is strictly unreachable — everything that buries a
				tile here is something you can stand on or walk under, so a
				player who knows can clear it by mowing what looks like bare
				porch boards. That is exactly the hunt `clearBuriedTiles` was
				written to end, handed back on every wave after the first.
			]]
			local wx, wz = Grid.tileToWorld(grid, tx, tz)
			local blocked = onWater
				or WorldService.buriedTiles[index] == true
				or Worlds.underShed(world, wx, wz)

			if not blocked and rng:NextNumber() <= section.density then
				local entry = pickFill(section)
				if entry then
					local height = math.clamp(
						rng:NextInteger(entry.heightMin, entry.heightMax),
						0,
						GameConfig.MAX_HEIGHT
					)
					byte = ChunkCodec.pack(entry.debris, height, false)
					fresh += Cutting.unitsOnTile(byte)
				end
			end

			buffer.writeu8(tiles, index - 1, byte)
			dirty[Grid.chunkOfTileIndex(grid, index)] = true
		end
	end

	state.totalUnits = fresh
	state.remainingUnits = fresh
	WorldService.totalUnits += fresh - before
	WorldService.remainingUnits += fresh - before
	ReplicationService.setTotalUnits(WorldService.totalUnits)

	for chunkIndex in dirty do
		ReplicationService.markDirty(chunkIndex)
	end
end

--- Records that `units` were removed from `sectionId`, keeping totals in step.
function WorldService.consumeUnits(sectionId: string, units: number)
	WorldService.remainingUnits = math.max(WorldService.remainingUnits - units, 0)
	local section = WorldService.sections[sectionId]
	if section then
		section.remainingUnits = math.max(section.remainingUnits - units, 0)
	end
end

function WorldService.container(): Folder?
	return container
end

return WorldService
