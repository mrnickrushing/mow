--!strict
--[[
	WorldService — generates a world and owns its authoritative tile state.

	The tile state is a `buffer`, one byte per tile, and no grass Instance is
	ever created on the server. Everything else — ground, house, shed, trailer,
	fences, section signs — is built once per round from the tables in Worlds,
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
local Upgrades = require(Shared.Config.Upgrades)
local Worlds = require(Shared.Config.Worlds)
local Types = require(Shared.Types)
local Build = require(script.Parent.Parent.Lib.Build)
local ReplicationService = require(script.Parent.ReplicationService)
local Structures = require(script.Parent.Parent.Lib.Structures)

local WorldService = {}

local TILE = GameConfig.TILE_SIZE
--- Wall height of a house, which is what the rooftop section sits on.
local ROOF_HEIGHT = 24

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
WorldService.sections = {} :: { [string]: SectionState }
WorldService.totalUnits = 0
WorldService.remainingUnits = 0

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

		for tz = r.z, math.min(r.z + r.d - 1, grid.depth - 1) do
			for tx = r.x, math.min(r.x + r.w - 1, grid.width - 1) do
				local index = Grid.toIndex(grid, tx, tz)
				tileSection[index] = section.id

				if rng:NextNumber() <= section.density then
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
			color = toColor(world.baseGround),
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
local function buildHouse(world: Types.WorldDef, parent: Folder)
	local rect = world.houseRect
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

	Build.part({
		name = "Floor",
		size = Vector3.new(width, 1, depth),
		cframe = CFrame.new(centre + Vector3.new(0, 0.5, 0)),
		color = Palette.color(Palette.ground.stoneDark),
		material = Enum.Material.Concrete,
		parent = shed,
	})

	-- Three walls and an open front, so you can see the stock from the lawn.
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
			parent = shed,
		})
	end

	-- Plank ceiling, laid across so the grain shows.
	local planks = 12
	for index = 0, planks - 1 do
		Build.part({
			name = "Plank",
			size = Vector3.new(width / planks - 0.15, 1, depth),
			cframe = CFrame.new(centre + Vector3.new(-width * 0.5 + width * (index + 0.5) / planks, height, 0)),
			color = Palette.color(if index % 2 == 0 then Palette.fence.picket else Palette.fence.picketShade),
			material = Enum.Material.WoodPlanks,
			parent = shed,
		})
	end

	-- Counter run along the back and one side.
	local counter = Build.part({
		name = "ShedCounter",
		size = Vector3.new(width - 4, 6, 5),
		cframe = CFrame.new(centre + Vector3.new(0, 3, depth * 0.5 - 4)),
		color = Palette.color(Palette.house.porch),
		material = Enum.Material.WoodPlanks,
		parent = shed,
	})
	Build.part({
		name = "CounterTop",
		size = Vector3.new(width - 3.4, 0.7, 5.6),
		cframe = CFrame.new(centre + Vector3.new(0, 6.3, depth * 0.5 - 4)),
		color = Palette.color(Palette.fence.picket),
		material = Enum.Material.WoodPlanks,
		parent = shed,
	})
	-- Drawer fronts with handles, which is what makes it read as cabinetry.
	for index = 0, 4 do
		local x = -width * 0.5 + 4 + index * 5.4
		Build.part({
			name = "Drawer",
			size = Vector3.new(4.4, 4.4, 0.4),
			cframe = CFrame.new(centre + Vector3.new(x, 3.2, depth * 0.5 - 6.6)),
			color = Palette.color(Palette.rgb(120, 78, 48)),
			material = Enum.Material.WoodPlanks,
			canCollide = false,
			parent = shed,
		})
		Build.part({
			name = "Handle",
			size = Vector3.new(2.6, 0.4, 0.3),
			cframe = CFrame.new(centre + Vector3.new(x, 4.4, depth * 0.5 - 6.9)),
			color = Palette.color(Palette.rgb(186, 186, 190)),
			material = Enum.Material.Metal,
			canCollide = false,
			parent = shed,
		})
	end

	-- Pegboard on the side wall with tools hung on it.
	Build.part({
		name = "Pegboard",
		size = Vector3.new(0.5, 10, depth - 8),
		cframe = CFrame.new(centre + Vector3.new(width * 0.5 - 1.2, 9, 0)),
		color = Palette.color(Palette.rgb(206, 186, 146)),
		material = Enum.Material.Pebble,
		canCollide = false,
		parent = shed,
	})
	for index = 0, 2 do
		Build.part({
			name = "HungTool",
			size = Vector3.new(1.2, 1.6, 6),
			cframe = CFrame.new(centre + Vector3.new(width * 0.5 - 2.2, 11 - index * 3.4, -4 + index * 4)),
			color = Palette.color(if index == 1 then Palette.ui.accent else Palette.rgb(64, 66, 70)),
			material = Enum.Material.Metal,
			canCollide = false,
			parent = shed,
		})
	end

	-- Hanging lantern, the warm point of light in the room.
	local lantern = Build.part({
		name = "Lantern",
		size = Vector3.new(2.4, 3, 2.4),
		cframe = CFrame.new(centre + Vector3.new(0, height - 4, -2)),
		color = Palette.color(Palette.ui.tips),
		material = Enum.Material.Neon,
		canCollide = false,
		parent = shed,
	})
	local glow = Instance.new("PointLight")
	glow.Color = Palette.color(Palette.ui.tips)
	glow.Range = 26
	glow.Brightness = 2
	glow.Parent = lantern

	-- Floating stock above the counter, with loud labels.
	local displays = {
		{ label = "Upgrade Bag", rainbow = false, color = Palette.rgb(96, 206, 140), offset = -8.5 },
		{ label = "Infinite Bag", rainbow = true, color = Palette.ui.tips, offset = 0 },
		{ label = "Leaf Blower", rainbow = false, color = Palette.rgb(120, 168, 220), offset = 8.5 },
	}
	for _, display in displays do
		local item = Build.part({
			name = display.label,
			size = Vector3.new(4, 4, 4),
			cframe = CFrame.new(centre + Vector3.new(display.offset, 9.5, depth * 0.5 - 4)),
			color = Palette.color(display.color),
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = shed,
		})
		local sign = Build.billboard(item, UDim2.fromScale(9, 3), 4, 90)
		if display.rainbow then
			Build.rainbowText(sign, display.label, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), 1.5)
		else
			Build.label(sign, display.label, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), 1.5)
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
	One sign per paid section.

	Zones unlock per player, so there is no physical barrier — a shared collision
	wall could not be open for one player and shut for another. The sign carries
	the price and a prompt, the client tints locked ground, and the server simply
	refuses to cut a tile in a section the player has not bought.
]]
local function buildSectionSigns(world: Types.WorldDef, parent: Folder): { [string]: BasePart }
	local signs: { [string]: BasePart } = {}
	local folder = Build.folder("ZoneSigns", parent)

	for _, section in world.sections do
		-- A rooftop is earned and a garage is found, so neither gets a price tag.
		-- Signs also stand on the ground plane rather than the section's own floor,
		-- so a basement's sign is at the top of its stairs and not sealed inside.
		if section.cost > 0 and Worlds.unlockKind(section) == "cash" then
			local r = section.rect
			-- Stand the sign at the edge of the section nearest the road.
			local at = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z)

			local post = Build.part({
				name = section.id,
				size = Vector3.new(1, 12, 1),
				cframe = CFrame.new(at + Vector3.new(0, 6, -2)),
				color = Palette.color(Palette.fence.rail),
				material = Enum.Material.Wood,
				canCollide = false,
				parent = folder,
			})
			post:SetAttribute("ZoneId", section.id)
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
	local spacing = 7
	local startX = -(count - 1) * spacing * 0.5

	for index, def in Upgrades.list do
		local at = centre + Vector3.new(startX + (index - 1) * spacing, 0, -16)

		Build.part({
			name = "Post",
			size = Vector3.new(0.8, 5, 0.8),
			cframe = CFrame.new(at + Vector3.new(0, 2.5, 0)),
			color = Palette.color(Palette.fence.rail),
			material = Enum.Material.Wood,
			parent = folder,
		})

		local board = Build.part({
			name = def.id,
			size = Vector3.new(6, 3.4, 0.6),
			cframe = CFrame.new(at + Vector3.new(0, 6, 0)),
			color = Palette.color(Palette.fence.picket),
			material = Enum.Material.WoodPlanks,
			parent = folder,
		})
		board:SetAttribute("UpgradeId", def.id)

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

		local r = section.rect
		local at = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z)

		local gate = Instance.new("Model")
		gate.Name = section.id
		gate:SetAttribute("SectionId", section.id)
		gate.Parent = folder

		-- A blue door in a wooden arch. Opening simply removes the model, so
		-- the door does not need hinges — only presence.
		Build.part({
			name = "Arch",
			size = Vector3.new(14, 2, 2),
			cframe = CFrame.new(at + Vector3.new(0, 11, 0)),
			color = Palette.color(Palette.fence.rail),
			material = Enum.Material.Wood,
			parent = gate,
		})

		for side = -1, 1, 2 do
			Build.part({
				name = "Post",
				size = Vector3.new(2, 12, 2),
				cframe = CFrame.new(at + Vector3.new(side * 6, 5, 0)),
				color = Palette.color(Palette.fence.rail),
				material = Enum.Material.Wood,
				parent = gate,
			})
		end

		local door = Build.part({
			name = "Door",
			size = Vector3.new(10, 10, 1),
			cframe = CFrame.new(at + Vector3.new(0, 5, 0)),
			color = Color3.fromRGB(96, 122, 196),
			material = Enum.Material.WoodPlanks,
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

local cashGates: { [string]: Model } = {}

local function buildSectionStructures(world: Types.WorldDef, parent: Folder)
	local context: Structures.Context = {
		parent = parent,
		flat = function(tx: number, tz: number): Vector3
			return WorldService.tilePointFlat(tx, tz)
		end,
		tileSize = TILE,
		groundY = GameConfig.GROUND_Y,
		rng = rng,
	}

	local detailed = world.style == "house"

	for _, section in world.sections do
		local kind = section.kind or "open"
		local elevation = section.elevation or 0

		if detailed then
			if kind == "room" then
				Structures.room(context, section, 16, elevation < 0)
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
				local r = section.rect
				local bottom = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z - 2)
				local top = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z) + Vector3.new(0, elevation, 0)
				Structures.stairs(context, bottom, top, 10, 14, parent)
			elseif elevation < 0 then
				local r = section.rect
				local top = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z - 1)
				local bottom = WorldService.tilePointFlat(r.x + r.w * 0.5, r.z + 3) + Vector3.new(0, elevation, 0)
				Structures.stairs(context, top, bottom, 10, 12, parent)
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

	local grate = Build.part({
		name = "ExitGrate",
		size = Vector3.new(11, 13, 1),
		cframe = CFrame.new(at + Vector3.new(0, 6.5, -0.8)),
		color = Palette.color(Palette.rgb(96, 100, 104)),
		material = Enum.Material.DiamondPlate,
		parent = parent,
	})
	grate:SetAttribute("Shut", true)

	local gui = Build.billboard(frame, UDim2.fromScale(9, 3), 11, 220)
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

	grate.Transparency = 0.75
	grate.CanCollide = false
	grate.Color = Palette.color(Palette.ui.cash)
	grate.Material = Enum.Material.Neon

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

	local prompt = Build.prompt(grate, "Leave", "Way Out", 14)
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

	seedTiles(world, grid, tiles)

	-- The replicator is handed the buffer it is to stream, rather than reaching
	-- back here for it. Done after seeding so the totals it reports to joiners
	-- are the finished ones.
	ReplicationService.attach(grid, tiles, {
		propertyId = world.id,
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

		-- The court wall and hedges that border the reference's side yard.
		local scenery = Build.folder("Scenery", parent)
		-- Just outside the pool deck rather than on it, so the wall never
		-- stands on tiles the player still has to clear.
		Build.chainLinkWall(
			scenery,
			WorldService.tilePointFlat(2, 50),
			WorldService.tilePointFlat(2, 78),
			7,
			12
		)
		Build.hedge(scenery, WorldService.tilePointFlat(72, 8), WorldService.tilePointFlat(72, 54), 13, 7)
		Build.hedge(scenery, WorldService.tilePointFlat(24, 78), WorldService.tilePointFlat(72, 78), 13, 7)

		-- A flagstone path from the kerb up to the porch, and a paved driveway.
		local pathCentre = WorldService.tilePointFlat(48, 20)
		Build.flagstone(parent, pathCentre + Vector3.new(0, 0.25, 0), Vector2.new(20, 96), 5, rng)
		local driveCentre = WorldService.tilePointFlat(13, 19)
		Build.flagstone(parent, driveCentre + Vector3.new(0, 0.25, 0), Vector2.new(68, 84), 6, rng)
	else
		Build.fence(parent, 0, 0, width, depth, 6, Palette.color(Palette.fence.rail), 14)
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

	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "MowSpawn"
	spawnLocation.Size = Vector3.new(18, 0.2, 18)
	spawnLocation.CFrame = spawnPart.CFrame + Vector3.new(0, 0.4, 0)
	spawnLocation.Anchored = true
	spawnLocation.CanCollide = false
	spawnLocation.Transparency = 1
	spawnLocation.Neutral = true
	spawnLocation.Parent = parent

	loadedSignal:Fire(world)
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

function WorldService.setSectionOpen(sectionId: string, open: boolean)
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
end

--- Fraction of the world's debris that has been cleared, 0..1.
function WorldService.completion(): number
	if WorldService.totalUnits <= 0 then
		return 1
	end
	return 1 - WorldService.remainingUnits / WorldService.totalUnits
end

--[[
	Adds debris that does not live on a tile — trees and stumps — to the totals.

	Completion means the world is genuinely clear, so a standing oak has to
	count against it the same way uncut grass does.
]]
function WorldService.registerExtraUnits(sectionId: string, units: number)
	WorldService.totalUnits += units
	WorldService.remainingUnits += units
	ReplicationService.setTotalUnits(WorldService.totalUnits)
	local section = WorldService.sections[sectionId]
	if section then
		section.totalUnits += units
		section.remainingUnits += units
	end
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
	for tz = r.z, math.min(r.z + r.d - 1, grid.depth - 1) do
		for tx = r.x, math.min(r.x + r.w - 1, grid.width - 1) do
			local index = Grid.toIndex(grid, tx, tz)
			local byte = 0

			if rng:NextNumber() <= section.density then
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
