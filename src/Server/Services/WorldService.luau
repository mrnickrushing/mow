--!strict
--[[
	WorldService — generates a world and owns its authoritative tile state.

	The tile state is a `buffer`, one byte per tile, and no grass Instance is
	ever created on the server. Everything else — ground, house, shed, trailer,
	fences, section signs — is built once per round from the tables in Worlds,
	so there is no hand-built map to keep in step with the config.
]]

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
local rng = Random.new()

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

	-- The road along the south edge, with the trailer parked at the curb.
	-- Plain asphalt for the same reason the lawn is plain grass: a concrete
	-- panel's texture stretched over six hundred studs is not concrete, it is
	-- a smear.
	Build.part({
		name = "Road",
		size = Vector3.new(width + 240, 0.6, 26),
		cframe = CFrame.new(width * 0.5, GameConfig.GROUND_Y + 0.05, -16),
		color = Palette.color(Palette.ground.road),
		material = Enum.Material.Asphalt,
		castShadow = false,
		parent = parent,
	})
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
					Build.mesh({
						prop = "Window",
						name = "Window",
						size = Vector3.new(WINDOW_WIDTH, WINDOW_HEIGHT, 0.9),
						collisionSize = Vector3.new(WINDOW_WIDTH, WINDOW_HEIGHT, 0.6),
						cframe = CFrame.new(Vector3.new(at.X, height, at.Z)) * CFrame.Angles(0, yaw, 0),
						canCollide = false,
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
		color = Palette.color(Palette.house.porch),
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
	Build.part({
		name = "GarageFrame",
		--[[
			The trim sits in the gap between the siding and the doors.

			At 0.5 deep on the wall plane it was buried behind the proudest
			siding course, which striped straight through it. Pushed out to
			clear the siding it went too far the other way and stood in
			front of the doors, hiding both bays behind one teal slab. The
			siding's proudest face is 0.6 out and the doors' is 1.1 out, so
			the trim's face goes at 0.75 — visible as a surround, with the
			doors still standing proud of it.
		]]
		size = Vector3.new(garageWidth + 2, garageHeight + 1.5, 1.0),
		cframe = CFrame.new(garageX, (garageHeight + 0.5) * 0.5, frontZ - 0.25),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = garage,
	})
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

	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			Build.mesh({
				prop = "Column",
				name = "CanopyColumn",
				size = Vector3.new(2.4, canopyH, 2.4),
				cframe = CFrame.new(
					canopyCentre + Vector3.new(sx * (canopyW * 0.5 - 7), canopyH * 0.5, sz * (canopyD * 0.5 - 5))
				),
				color = trim,
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
	Build.mesh({
		prop = "Door",
		name = "ShopBackDoor",
		size = Vector3.new(6.5, 9.2, 0.9),
		-- Centred, because at a quarter of the width it stood underneath
		-- the left-hand window.
		cframe = CFrame.new(shopCentre.X, 1 + 4.6, backZ + 0.35),
		color = dark,
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
		cframe = CFrame.new(centre + Vector3.new(0, 0.5, 0)),
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

	Build.mesh({
		prop = "Shed",
		name = "Shell",
		size = Vector3.new(width + 4, height + 4, depth + 4),
		-- No collision on the shell: the walls the player can actually bump
		-- into stay as thin slabs, so the open front is genuinely open and
		-- nobody gets caught on a roof overhang.
		collisionSize = Vector3.new(1, 1, 1),
		cframe = CFrame.new(centre + Vector3.new(0, (height + 4) * 0.5, 0)),
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
	]]
	local displays = {
		{ label = "Upgrade Bag", prop = "Sack", rainbow = false, color = Palette.rgb(96, 206, 140), offset = -10, lift = 2.8 },
		{ label = "Infinite Bag", prop = "Sack", rainbow = true, color = Palette.ui.tips, offset = 0, lift = 5.2 },
		{ label = "Leaf Blower", prop = "LeafBlower", rainbow = false, color = Palette.rgb(120, 168, 220), offset = 10, lift = 2.8 },
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
		local sign = Build.billboard(item, UDim2.fromScale(8, 2.6), display.lift, 90)
		if display.rainbow then
			Build.rainbowText(sign, display.label, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), 1.2)
		else
			Build.label(sign, display.label, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), 1.2)
		end
	end

	local gui = Build.billboard(counter, UDim2.fromScale(13, 3.6), 14, 280)
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
				-- Beside the gate rather than on top of it, on the approach side.
				cframe = basis * CFrame.new(8, 6, -2),
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
			local face = Build.part({
				name = "Face",
				size = Vector3.new(0.2, 0.2, 0.2),
				-- Measured against the mesh rather than assumed: the plank
				-- hangs a little off the post's centre, and the marker sits
				-- half a stud proud of the wood so the writing clears it.
				cframe = post.CFrame * CFrame.new(0.6, 0, -1.6),
				color = Color3.fromRGB(255, 255, 255),
				material = Enum.Material.SmoothPlastic,
				transparency = 1,
				canCollide = false,
				parent = post,
			})
			face.CastShadow = false

			-- Narrower than the plank looks, because the marker stands a
			-- stud and a half nearer than the post and a billboard sized in
			-- studs grows as it comes towards you.
			local board = Build.billboard(face, UDim2.fromScale(4.9, 1.7), 0, 140)
			local label = Build.label(board, section.name, UDim2.fromScale(1, 1), UDim2.new(), 1.1)
			-- Paint on pale wood, not a label floating over a bush: the white
			-- and its black stroke belong to the things that hang in the air.
			label.TextColor3 = Color3.fromRGB(78, 52, 30)
			label.TextStrokeTransparency = 1

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
local function buildCashGates(world: Types.WorldDef, parent: Folder): { [string]: Model }
	local gates: { [string]: Model } = {}
	local folder = Build.folder("CashGates", parent)

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
			color = Palette.color(Palette.fence.rail),
			parent = gate,
		})

		for side = -1, 1, 2 do
			Build.mesh({
			prop = "Column",
				name = "Post",
				size = Vector3.new(2, 12, 2),
				cframe = basis * CFrame.new(side * 6, 5, 0),
				color = Palette.color(Palette.fence.rail),
				parent = gate,
			})
		end

		local door = Build.mesh({
			prop = "Gate",
			name = "Door",
			size = Vector3.new(12, 11, 1.8),
			collisionSize = Vector3.new(10, 10, 1),
			cframe = basis * CFrame.new(0, 5, 0),
			parent = gate,
		})

		local gui = Build.billboard(door, UDim2.fromOffset(160, 70), 4, 90)
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

--- Width of a flight of steps, and of the gap left in a wall for one.
local STAIR_WIDTH = 10
local DOOR_WIDTH = 14
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
			local needsWayIn = kind == "room" or elevation ~= 0
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
				Structures.room(context, section, 16, elevation < 0, opening)
			elseif kind == "pool" then
				Structures.pool(context, section)
			elseif kind == "maze" then
				Structures.maze(context, section)
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

		Structures.clutter(context, section, section.clutter or 0)
	end
end

--------------------------------------------------------------------
-- The exit
--------------------------------------------------------------------

local exitPart: BasePart? = nil

--- Builds the grate, shut. It opens when the last section is clear.
local function buildExit(world: Types.WorldDef, parent: Folder)
	local at = WorldService.tilePointFlat(world.exit.x, world.exit.z)

	local frame = Build.part({
		name = "ExitFrame",
		size = Vector3.new(14, 16, 2),
		cframe = CFrame.new(at + Vector3.new(0, 8, 0)),
		color = Palette.color(Palette.house.brickDark),
		material = Enum.Material.Brick,
		parent = parent,
	})

	local grate = Build.mesh({
		prop = "Grate",
		name = "ExitGrate",
		size = Vector3.new(11, 13, 2),
		collisionSize = Vector3.new(11, 13, 1),
		cframe = CFrame.new(at + Vector3.new(0, 6.5, -0.8)),
		parent = parent,
	})
	grate:SetAttribute("Shut", true)

	-- Above the gate's raised position, not the block's top: opened, the gate
	-- rises ten studs and a sign hung at eleven was read through its bars.
	local gui = Build.billboard(frame, UDim2.fromScale(9, 3), 18, 220)
	Build.label(gui, "WAY OUT", UDim2.fromScale(1, 0.55), UDim2.fromScale(0, 0), 2)
	Build.label(gui, "Locked", UDim2.fromScale(1, 0.4), UDim2.fromScale(0, 0.58), 1.1)

	exitPart = grate
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

	local frame = grate.Parent and grate.Parent:FindFirstChild("ExitFrame")
	if frame and frame:IsA("BasePart") then
		local gui = frame:FindFirstChildOfClass("BillboardGui")
		if gui then
			local second = gui:FindFirstChild("Label", true)
			for _, label in gui:GetChildren() do
				if label:IsA("TextLabel") and label ~= second then
					label.Text = label.Text == "Locked" and "Open — leave to finish" or label.Text
				end
			end
		end
	end

	local prompt = Build.prompt(doorway, "Leave", "Way Out", 14)
	prompt.HoldDuration = 0.6
	prompt.Triggered:Connect(function(player: Player)
		exitSignal:Fire(player)
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
	local COVER_FOOTPRINT = Vector3.new(3.2, 2.6, 3.2)
	local function covered(x: number, y: number, z: number): boolean
		for _, part in workspace:GetPartBoundsInBox(CFrame.new(x, y + 1.5, z), COVER_FOOTPRINT, params) do
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
	table.clear(WorldService.buriedTiles)

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
	buildHouse(world, parent)
	WorldService.shedPart = buildShed(world, parent)
	WorldService.trailerPart = buildTrailer(world, parent)
	WorldService.sectionSigns = buildSectionSigns(world, parent)
	cashGates = buildCashGates(world, parent)
	buildUpgradeStations(world, parent)
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
		Build.hedge(scenery, WorldService.tilePointFlat(72, 8), WorldService.tilePointFlat(72, 54), 13, 7)
		Build.hedge(scenery, WorldService.tilePointFlat(24, 78), WorldService.tilePointFlat(72, 78), 13, 7)

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
	else
		local lot = world.style == "lot"
		Build.fence(parent, 0, 0, width, depth, 6, Palette.color(Palette.fence.rail), 14, lot)
		if lot then
			buildGasStation(world, parent)
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
		-- An open section has no door: the purchase consumes it.
		local gate = cashGates[sectionId]
		if gate then
			cashGates[sectionId] = nil
			gate:Destroy()
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
