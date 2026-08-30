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
local Palette = require(Shared.Config.Palette)
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
			color = Palette.color(Palette.ground.lawnDark),
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
local function buildHouse(property: Types.PropertyDef, parent: Folder)
	local rect = property.houseRect
	if not rect then
		return
	end

	local house = Build.folder("House", parent)
	local centre = WorldService.tilePointFlat(rect.x + rect.w * 0.5, rect.z + rect.d * 0.5)
	local width, depth = rect.w * TILE, rect.d * TILE
	local wallHeight = ROOF_HEIGHT - 4

	-- Brick foundation the siding sits on.
	Build.part({
		name = "Foundation",
		size = Vector3.new(width + 1.5, 4, depth + 1.5),
		cframe = CFrame.new(centre + Vector3.new(0, 2, 0)),
		color = Palette.color(Palette.house.brick),
		material = Enum.Material.Brick,
		parent = house,
	})

	-- Solid core, so the shell is never see-through at a corner.
	Build.part({
		name = "Core",
		size = Vector3.new(width - 1, wallHeight, depth - 1),
		cframe = CFrame.new(centre + Vector3.new(0, 4 + wallHeight * 0.5, 0)),
		color = Palette.color(Palette.house.sidingShade),
		material = Enum.Material.WoodPlanks,
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
	Build.part({
		name = "Roof",
		size = Vector3.new(width + 5, 2.4, depth + 5),
		cframe = CFrame.new(centre + Vector3.new(0, 4 + wallHeight + 3, 0)),
		color = Palette.color(Palette.house.roof),
		material = Enum.Material.Slate,
		parent = house,
	})

	local frontZ = centre.Z - depth * 0.5

	-- Windows down the front, with teal surrounds.
	for _, ratio in { -0.32, 0.3 } do
		local at = Vector3.new(centre.X + width * ratio, 12, frontZ - 0.7)
		Build.part({
			name = "WindowFrame",
			size = Vector3.new(9, 9, 0.6),
			cframe = CFrame.new(at),
			color = Palette.color(Palette.house.trim),
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = house,
		})
		Build.part({
			name = "Window",
			size = Vector3.new(7.4, 7.4, 0.4),
			cframe = CFrame.new(at - Vector3.new(0, 0, 0.3)),
			color = Palette.color(Palette.house.window),
			material = Enum.Material.Glass,
			transparency = 0.25,
			canCollide = false,
			parent = house,
		})
	end

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
		Build.part({
			name = "Column",
			size = Vector3.new(2.2, 13, 2.2),
			cframe = CFrame.new(x, 10.8, porchZ - porchDepth * 0.5 + 1.4),
			color = Palette.color(Palette.house.column),
			material = Enum.Material.WoodPlanks,
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

	-- Rail: top bar plus balusters, down the open side of the porch.
	local railZ = porchZ - porchDepth * 0.5 + 0.6
	Build.part({
		name = "RailTop",
		size = Vector3.new(porchWidth - 4, 0.7, 0.8),
		cframe = CFrame.new(porchX, 8, railZ),
		color = Palette.color(Palette.house.porchRail),
		material = Enum.Material.Wood,
		parent = porch,
	})
	for index = 0, 9 do
		Build.part({
			name = "Baluster",
			size = Vector3.new(0.5, 3.6, 0.5),
			cframe = CFrame.new(
				porchX - (porchWidth - 5) * 0.5 + (porchWidth - 5) * index / 9,
				6.1,
				railZ
			),
			color = Palette.color(Palette.house.porchRail),
			material = Enum.Material.Wood,
			canCollide = false,
			parent = porch,
		})
	end

	-- Steps down to the path.
	for step = 0, 2 do
		Build.part({
			name = "Step",
			size = Vector3.new(porchWidth * 0.5, 1.3, 3),
			cframe = CFrame.new(porchX, 3.3 - step * 1.2, porchZ - porchDepth * 0.5 - 1.6 - step * 2.6),
			color = Palette.color(Palette.house.porch),
			material = Enum.Material.WoodPlanks,
			parent = porch,
		})
	end

	Build.part({
		name = "Door",
		size = Vector3.new(6.5, 11, 0.6),
		cframe = CFrame.new(porchX, 9.5, frontZ - 0.4),
		color = Palette.color(Palette.house.door),
		material = Enum.Material.Wood,
		canCollide = false,
		parent = house,
	})

	--------------------------------------------------------------------
	-- Attached garage door
	--------------------------------------------------------------------

	local garageX = centre.X + width * 0.28
	local garage = Build.folder("GarageFront", house)
	Build.part({
		name = "GarageDoor",
		size = Vector3.new(width * 0.34, 13, 0.8),
		cframe = CFrame.new(garageX, 10.5, frontZ - 0.5),
		color = Palette.color(Palette.house.garage),
		material = Enum.Material.SmoothPlastic,
		parent = garage,
	})
	-- The horizontal panel lines that make a flat slab read as a garage door.
	for line = 0, 5 do
		Build.part({
			name = "Panel",
			size = Vector3.new(width * 0.34, 0.35, 0.3),
			cframe = CFrame.new(garageX, 5 + line * 2.2, frontZ - 0.95),
			color = Palette.color(Palette.house.garageLine),
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			castShadow = false,
			parent = garage,
		})
	end
	Build.part({
		name = "GarageFrame",
		size = Vector3.new(width * 0.34 + 2, 15, 0.5),
		cframe = CFrame.new(garageX, 10, frontZ - 0.2),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = garage,
	})
end

local function buildShed(property: Types.PropertyDef, parent: Folder): BasePart
	local centre = WorldService.tilePointFlat(property.shed.x, property.shed.z)
	local shed = Build.folder("Shed", parent)

	local walls = Build.box("Walls", centre, Vector3.new(18, 13, 16), Palette.color(Palette.props.shed), Enum.Material.WoodPlanks, shed)
	Build.part({
		name = "Roof",
		size = Vector3.new(21, 2, 19),
		cframe = CFrame.new(centre + Vector3.new(0, 14, 0)),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.Slate,
		parent = shed,
	})

	local counter = Build.part({
		name = "Counter",
		size = Vector3.new(14, 5, 3),
		cframe = CFrame.new(centre + Vector3.new(0, 2.5, -9)),
		color = Palette.color(Palette.house.porch),
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

	local bed = Build.box("Bed", centre, Vector3.new(24, 4, 12), Palette.color(Palette.props.bin), Enum.Material.DiamondPlate, trailer)
	for _, offset in { Vector3.new(-12, 3.5, 0), Vector3.new(12, 3.5, 0) } do
		Build.part({
			name = "Side",
			size = Vector3.new(0.8, 5, 12),
			cframe = CFrame.new(centre + offset + Vector3.new(0, 2, 0)),
			color = Palette.color(Palette.props.binLid),
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
				color = Palette.color(Palette.fence.rail),
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
					color = Palette.color(Palette.house.roof),
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
						color = Palette.color(Palette.house.trim),
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
						color = Palette.color(Palette.house.trim),
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

	if property.style == "house" then
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

		-- A flagstone path from the kerb up to the porch, and a paved driveway.
		local pathCentre = WorldService.tilePointFlat(48, 20)
		Build.flagstone(parent, pathCentre + Vector3.new(0, 0.25, 0), Vector2.new(20, 96), 5, rng)
		local driveCentre = WorldService.tilePointFlat(13, 19)
		Build.flagstone(parent, driveCentre + Vector3.new(0, 0.25, 0), Vector2.new(68, 84), 6, rng)
	else
		Build.fence(parent, 0, 0, width, depth, 6, Palette.color(Palette.fence.rail), 14)
	end

	local spawnAt = WorldService.tilePointFlat(property.spawn.x, property.spawn.z)
	local spawnPart = Build.part({
		name = "SpawnPad",
		size = Vector3.new(20, 0.4, 20),
		cframe = CFrame.new(spawnAt + Vector3.new(0, 0.2, 0)),
		color = Palette.color(Palette.ground.path),
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
