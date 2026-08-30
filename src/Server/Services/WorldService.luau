--!strict
--[[
	WorldService — generates a property and owns its authoritative tile state.

	The tile state is a `buffer`, one byte per tile, and no grass Instance is
	ever created on the server. Everything else — ground, house, shed, trailer,
	fences, zone signs — is built once per round from the tables in Properties,
	so there is no hand-built map to keep in step with the config.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkCodec = require(Shared.ChunkCodec)
local Cutting = require(Shared.Cutting)
local GameConfig = require(Shared.Config.GameConfig)
local Grid = require(Shared.Grid)
local Properties = require(Shared.Config.Properties)
local Types = require(Shared.Types)
local Build = require(script.Parent.Parent.Lib.Build)
local Structures = require(script.Parent.Parent.Lib.Structures)

local WorldService = {}

local TILE = GameConfig.TILE_SIZE
--- Wall height of a house, which is what the rooftop zone sits on.
local ROOF_HEIGHT = 24

export type ZoneState = {
	def: Types.ZoneDef,
	--- Tile indices belonging to this zone that started with debris.
	totalUnits: number,
	remainingUnits: number,
	--- World-space centre of the zone, for signs and camera hints.
	centre: Vector3,
}

WorldService.grid = nil :: Grid.Grid?
WorldService.tiles = nil :: buffer?
WorldService.property = nil :: Types.PropertyDef?
--- Zone id per tile index, or "" for ground that belongs to no zone.
WorldService.tileZone = nil :: { string }?
WorldService.zones = {} :: { [string]: ZoneState }
WorldService.totalUnits = 0
WorldService.remainingUnits = 0

local loadedSignal = Instance.new("BindableEvent")
--- Fires with the property definition once a new world is ready.
WorldService.Loaded = loadedSignal.Event

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
	local property = WorldService.property
	if not property then
		return 0
	end
	return Properties.elevationAt(property, tx, tz)
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

--- Ground-plane position, ignoring any zone elevation. Used when placing the
--- structures that create those elevations in the first place.
function WorldService.tilePointFlat(tx: number, tz: number): Vector3
	local grid = assert(WorldService.grid, "world not loaded")
	local x, z = Grid.tileToWorld(grid, tx, tz)
	return Vector3.new(x, GameConfig.GROUND_Y, z)
end

function WorldService.zoneIdAt(index: number): string
	local tileZone = WorldService.tileZone
	if not tileZone then
		return ""
	end
	return tileZone[index] or ""
end

--------------------------------------------------------------------
-- Generation
--------------------------------------------------------------------

--- Picks a debris entry from a zone's weighted fill list.
local function pickFill(zone: Types.ZoneDef): Types.FillEntry?
	local total = 0
	for _, entry in zone.fill do
		total += entry.weight
	end
	if total <= 0 then
		return nil
	end

	local roll = rng:NextNumber() * total
	for _, entry in zone.fill do
		roll -= entry.weight
		if roll <= 0 then
			return entry
		end
	end
	return zone.fill[#zone.fill]
end

local function seedTiles(property: Types.PropertyDef, grid: Grid.Grid, tiles: buffer)
	local tileZone = table.create(Grid.tileCount(grid), "")
	WorldService.zones = {}
	WorldService.totalUnits = 0

	for _, zone in property.zones do
		local r = zone.rect
		local state: ZoneState = {
			def = zone,
			totalUnits = 0,
			remainingUnits = 0,
			centre = WorldService.tilePointToWorld(r.x + r.w * 0.5, r.z + r.d * 0.5),
		}

		for tz = r.z, math.min(r.z + r.d - 1, grid.depth - 1) do
			for tx = r.x, math.min(r.x + r.w - 1, grid.width - 1) do
				local index = Grid.toIndex(grid, tx, tz)
				tileZone[index] = zone.id

				if rng:NextNumber() <= zone.density then
					local entry = pickFill(zone)
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
		WorldService.zones[zone.id] = state
		WorldService.totalUnits += state.totalUnits
	end

	WorldService.tileZone = tileZone
	WorldService.remainingUnits = WorldService.totalUnits
end

local function buildGround(property: Types.PropertyDef, grid: Grid.Grid, parent: Folder)
	local width = grid.width * TILE
	local depth = grid.depth * TILE

	-- Anything below ground needs the lawn opened over it, or the room is buried
	-- and the player walks across its ceiling without ever finding the way in.
	local holes: { Types.Rect } = {}
	for _, zone in property.zones do
		if (zone.elevation or 0) < 0 then
			table.insert(holes, zone.rect)
		end
	end

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
			color = toColor(property.baseGround),
			material = Enum.Material.Grass,
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
			color = Color3.fromRGB(96, 118, 74),
			material = Enum.Material.Grass,
			castShadow = false,
			parent = parent,
		})
	end

	-- The road along the south edge, with the trailer parked at the curb.
	Build.part({
		name = "Road",
		size = Vector3.new(width + 240, 0.6, 26),
		cframe = CFrame.new(width * 0.5, GameConfig.GROUND_Y + 0.05, -16),
		color = Color3.fromRGB(62, 62, 66),
		material = Enum.Material.Asphalt,
		castShadow = false,
		parent = parent,
	})
end

local function buildHouse(property: Types.PropertyDef, parent: Folder)
	local rect = property.houseRect
	if not rect then
		return
	end

	local centre = WorldService.tilePointFlat(rect.x + rect.w * 0.5, rect.z + rect.d * 0.5)
	local size = Vector3.new(rect.w * TILE, ROOF_HEIGHT, rect.d * TILE)

	local house = Build.folder("House", parent)
	Build.box("Walls", centre, size, Color3.fromRGB(226, 219, 202), Enum.Material.Concrete, house)
	Build.part({
		name = "Roof",
		size = Vector3.new(size.X + 4, 3, size.Z + 4),
		cframe = CFrame.new(centre + Vector3.new(0, size.Y + 1.5, 0)),
		color = Color3.fromRGB(97, 66, 54),
		material = Enum.Material.Slate,
		parent = house,
	})
	Build.part({
		name = "Door",
		size = Vector3.new(7, 11, 0.6),
		cframe = CFrame.new(centre + Vector3.new(0, 5.5, -size.Z * 0.5)),
		color = Color3.fromRGB(88, 60, 44),
		material = Enum.Material.Wood,
		canCollide = false,
		parent = house,
	})
end

local function buildShed(property: Types.PropertyDef, parent: Folder): BasePart
	local centre = WorldService.tilePointFlat(property.shed.x, property.shed.z)
	local shed = Build.folder("Shed", parent)

	local walls = Build.box("Walls", centre, Vector3.new(18, 13, 16), Color3.fromRGB(140, 92, 62), Enum.Material.Wood, shed)
	Build.part({
		name = "Roof",
		size = Vector3.new(21, 2, 19),
		cframe = CFrame.new(centre + Vector3.new(0, 14, 0)),
		color = Color3.fromRGB(74, 52, 40),
		material = Enum.Material.Slate,
		parent = shed,
	})

	local counter = Build.part({
		name = "Counter",
		size = Vector3.new(14, 5, 3),
		cframe = CFrame.new(centre + Vector3.new(0, 2.5, -9)),
		color = Color3.fromRGB(168, 116, 78),
		material = Enum.Material.WoodPlanks,
		parent = shed,
	})

	local gui = Build.billboard(walls, UDim2.fromScale(11, 3.4), 11, 260)
	Build.label(gui, "THE SHED", UDim2.fromScale(1, 0.55), UDim2.fromScale(0, 0), 2.2)
	Build.label(gui, "Tools & Upgrades", UDim2.fromScale(1, 0.4), UDim2.fromScale(0, 0.58), 1.2)

	walls.Name = "ShedWalls"
	counter.Name = "ShedCounter"
	return counter
end

local function buildTrailer(property: Types.PropertyDef, parent: Folder): BasePart
	local centre = WorldService.tilePointFlat(property.trailer.x, property.trailer.z)
	local trailer = Build.folder("Trailer", parent)

	local bed = Build.box("Bed", centre, Vector3.new(24, 4, 12), Color3.fromRGB(72, 78, 88), Enum.Material.DiamondPlate, trailer)
	for _, offset in { Vector3.new(-12, 3.5, 0), Vector3.new(12, 3.5, 0) } do
		Build.part({
			name = "Side",
			size = Vector3.new(0.8, 5, 12),
			cframe = CFrame.new(centre + offset + Vector3.new(0, 2, 0)),
			color = Color3.fromRGB(58, 64, 74),
			material = Enum.Material.DiamondPlate,
			parent = trailer,
		})
	end

	local gui = Build.billboard(bed, UDim2.fromScale(12, 3.2), 8, 300)
	Build.label(gui, "TRAILER", UDim2.fromScale(1, 0.55), UDim2.fromScale(0, 0), 2.2)
	Build.label(gui, "Dump your bag here", UDim2.fromScale(1, 0.4), UDim2.fromScale(0, 0.58), 1.2)

	bed.Name = "TrailerBed"
	return bed
end

--[[
	One sign per paid zone.

	Zones unlock per player, so there is no physical barrier — a shared collision
	wall could not be open for one player and shut for another. The sign carries
	the price and a prompt, the client tints locked ground, and the server simply
	refuses to cut a tile in a zone the player has not bought.
]]
local function buildZoneSigns(property: Types.PropertyDef, parent: Folder): { [string]: BasePart }
	local signs: { [string]: BasePart } = {}
	local folder = Build.folder("ZoneSigns", parent)

	for _, zone in property.zones do
		-- A rooftop is earned and a garage is found, so neither gets a price tag.
		-- Signs also stand on the ground plane rather than the zone's own floor,
		-- so a basement's sign is at the top of its stairs and not sealed inside.
		if zone.cost > 0 and Properties.unlockKind(zone) == "cash" then
			local r = zone.rect
			-- Stand the sign at the edge of the zone nearest the road.
			local at = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z)

			local post = Build.part({
				name = zone.id,
				size = Vector3.new(1, 12, 1),
				cframe = CFrame.new(at + Vector3.new(0, 6, -2)),
				color = Color3.fromRGB(120, 84, 56),
				material = Enum.Material.Wood,
				canCollide = false,
				parent = folder,
			})
			post:SetAttribute("ZoneId", zone.id)
			signs[zone.id] = post
		end
	end

	return signs
end

--[[
	Builds everything a zone needs beyond its tiles.

	Rooms get walls, the pool gets water, the maze gets hedges, and every zone
	gets its share of clutter. Only `house` properties get the full treatment;
	the big open lots stay open, which is where the wide-deck mowers earn their
	price.
]]
local function buildZoneStructures(property: Types.PropertyDef, parent: Folder)
	local context: Structures.Context = {
		parent = parent,
		flat = function(tx: number, tz: number): Vector3
			return WorldService.tilePointFlat(tx, tz)
		end,
		tileSize = TILE,
		groundY = GameConfig.GROUND_Y,
		rng = rng,
	}

	local detailed = property.style == "house"

	for _, zone in property.zones do
		local kind = zone.kind or "open"
		local elevation = zone.elevation or 0

		if detailed then
			if kind == "room" then
				Structures.room(context, zone, 16, elevation < 0)
			elseif kind == "pool" then
				Structures.pool(context, zone)
			elseif kind == "maze" then
				Structures.maze(context, zone)
			elseif kind == "roof" then
				-- The roof slab is the floor the rooftop's debris rests on.
				local r = zone.rect
				local centre = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z + r.d * 0.5)
				Build.part({
					name = "RoofDeck",
					size = Vector3.new(r.w * TILE + 4, 2, r.d * TILE + 4),
					cframe = CFrame.new(centre + Vector3.new(0, elevation - 1, 0)),
					color = Color3.fromRGB(97, 66, 54),
					material = Enum.Material.Slate,
					parent = parent,
				})
				-- A parapet, so a player on the roof does not simply walk off it.
				for _, side in
					{
						Vector3.new(0, 0, -(r.d * TILE) * 0.5),
						Vector3.new(0, 0, (r.d * TILE) * 0.5),
					}
				do
					Build.part({
						name = "Parapet",
						size = Vector3.new(r.w * TILE + 4, 4, 1.5),
						cframe = CFrame.new(centre + side + Vector3.new(0, elevation + 2, 0)),
						color = Color3.fromRGB(86, 58, 48),
						material = Enum.Material.Slate,
						parent = parent,
					})
				end
				for _, side in
					{
						Vector3.new(-(r.w * TILE) * 0.5, 0, 0),
						Vector3.new((r.w * TILE) * 0.5, 0, 0),
					}
				do
					Build.part({
						name = "Parapet",
						size = Vector3.new(1.5, 4, r.d * TILE + 4),
						cframe = CFrame.new(centre + side + Vector3.new(0, elevation + 2, 0)),
						color = Color3.fromRGB(86, 58, 48),
						material = Enum.Material.Slate,
						parent = parent,
					})
				end
			end

			-- Stairs into anything not on the lawn.
			if elevation > 0 then
				local r = zone.rect
				local bottom = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z - 2)
				local top = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z) + Vector3.new(0, elevation, 0)
				Structures.stairs(context, bottom, top, 10, 14, parent)
			elseif elevation < 0 then
				local r = zone.rect
				local top = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z - 1)
				local bottom = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z + 3) + Vector3.new(0, elevation, 0)
				Structures.stairs(context, top, bottom, 10, 12, parent)
			end
		end

		Structures.clutter(context, zone, zone.clutter or 0)
	end
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

WorldService.shedPart = nil :: BasePart?
WorldService.trailerPart = nil :: BasePart?
WorldService.zoneSigns = {} :: { [string]: BasePart }

--- Tears down the previous world and generates `propertyId`.
function WorldService.load(propertyId: string)
	local property = Properties.expect(propertyId)

	if container then
		container:Destroy()
	end
	container = Build.folder("MowWorld", Workspace)
	local parent = container :: Folder

	local grid = Grid.new(property.gridWidth, property.gridDepth)
	local tiles = buffer.create(Grid.tileCount(grid))

	WorldService.grid = grid
	WorldService.tiles = tiles
	WorldService.property = property

	seedTiles(property, grid, tiles)
	buildGround(property, grid, parent)
	buildHouse(property, parent)
	WorldService.shedPart = buildShed(property, parent)
	WorldService.trailerPart = buildTrailer(property, parent)
	WorldService.zoneSigns = buildZoneSigns(property, parent)
	buildZoneStructures(property, parent)

	-- Fence the outer boundary so the lot reads as a property, not a plane.
	local width = grid.width * TILE
	local depth = grid.depth * TILE
	Build.fence(parent, 0, 0, width, depth, 6, Color3.fromRGB(150, 132, 104), 14)

	local spawnAt = WorldService.tilePointFlat(property.spawn.x, property.spawn.z)
	local spawnPart = Build.part({
		name = "SpawnPad",
		size = Vector3.new(20, 0.4, 20),
		cframe = CFrame.new(spawnAt + Vector3.new(0, 0.2, 0)),
		color = Color3.fromRGB(206, 198, 172),
		material = Enum.Material.Concrete,
		castShadow = false,
		parent = parent,
	})

	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "MowSpawn"
	spawnLocation.Size = Vector3.new(18, 0.2, 18)
	spawnLocation.CFrame = spawnPart.CFrame + Vector3.new(0, 0.4, 0)
	spawnLocation.Anchored = true
	spawnLocation.CanCollide = false
	spawnLocation.Transparency = 1
	spawnLocation.Neutral = true
	spawnLocation.Parent = parent

	loadedSignal:Fire(property)
end

function WorldService.isLoaded(): boolean
	return WorldService.grid ~= nil
end

--- Fraction of the property's debris that has been cleared, 0..1.
function WorldService.completion(): number
	if WorldService.totalUnits <= 0 then
		return 1
	end
	return 1 - WorldService.remainingUnits / WorldService.totalUnits
end

--[[
	Adds debris that does not live on a tile — trees and stumps — to the totals.

	Completion means the property is genuinely clear, so a standing oak has to
	count against it the same way uncut grass does.
]]
function WorldService.registerExtraUnits(zoneId: string, units: number)
	WorldService.totalUnits += units
	WorldService.remainingUnits += units
	local zone = WorldService.zones[zoneId]
	if zone then
		zone.totalUnits += units
		zone.remainingUnits += units
	end
end

--- The zone whose rect contains a tile-space point, or "" for open ground.
function WorldService.zoneIdAtTile(tx: number, tz: number): string
	local grid = WorldService.grid
	if not grid or not Grid.inBounds(grid, tx, tz) then
		return ""
	end
	return WorldService.zoneIdAt(Grid.toIndex(grid, tx, tz))
end

--- Records that `units` were removed from `zoneId`, keeping totals in step.
function WorldService.consumeUnits(zoneId: string, units: number)
	WorldService.remainingUnits = math.max(WorldService.remainingUnits - units, 0)
	local zone = WorldService.zones[zoneId]
	if zone then
		zone.remainingUnits = math.max(zone.remainingUnits - units, 0)
	end
end

function WorldService.container(): Folder?
	return container
end

return WorldService
