--!strict
--[[
	Structures — the built parts of a detailed residential property.

	Rooms, the pool, the hedge maze, the porch stairs onto the roof, the
	stairwell down to the cellar, and the clutter that debris hides against.

	That last one is not decoration. A completion bar over an empty field makes
	the final few percent a tedious sweep; the same bar over a yard full of bins,
	planters and patio furniture makes it a hunt. Clutter is the mechanic.
]]

local Palette = require(game:GetService("ReplicatedStorage").Shared.Config.Palette)
local Types = require(game:GetService("ReplicatedStorage").Shared.Types)
local Build = require(script.Parent.Build)

local Structures = {}

export type Context = {
	parent: Instance,
	--- Tile-space to world position on the flat ground plane.
	flat: (number, number) -> Vector3,
	tileSize: number,
	groundY: number,
	rng: Random,
}

--[[
	A gap left in a ring of walls.

	`normal` is the outward direction of the side the gap sits in, `offset` how
	far along that side the gap's centre is from the side's centre, and `width`
	how wide it is.
]]
export type Opening = {
	normal: Vector3,
	width: number,
	offset: number?,
}

type RingSide = {
	normal: Vector3,
	offset: Vector3,
	span: number,
	alongX: boolean,
}

export type WallRingOptions = {
	name: string,
	--- Centre of the enclosed floor, at the height the walls stand on.
	centre: Vector3,
	width: number,
	depth: number,
	height: number,
	thickness: number,
	color: Color3,
	material: Enum.Material,
	parent: Instance,
	opening: Opening?,
}

--------------------------------------------------------------------
-- Rectangle subtraction, for cutting holes in the ground
--------------------------------------------------------------------

--[[
	Subtracts `hole` from `rect`, returning the pieces that remain.

	Used to build the lawn as slabs around a sunken cellar rather than as one
	sheet the player would have to fall through.
]]
function Structures.subtractRect(rect: Types.Rect, hole: Types.Rect): { Types.Rect }
	local x1, z1 = rect.x, rect.z
	local x2, z2 = rect.x + rect.w, rect.z + rect.d
	local hx1, hz1 = math.max(hole.x, x1), math.max(hole.z, z1)
	local hx2, hz2 = math.min(hole.x + hole.w, x2), math.min(hole.z + hole.d, z2)

	-- No overlap: the rectangle survives whole.
	if hx1 >= hx2 or hz1 >= hz2 then
		return { rect }
	end

	local pieces: { Types.Rect } = {}
	local function add(ax: number, az: number, aw: number, ad: number)
		if aw > 0 and ad > 0 then
			table.insert(pieces, { x = ax, z = az, w = aw, d = ad })
		end
	end

	add(x1, z1, x2 - x1, hz1 - z1) -- north strip
	add(x1, hz2, x2 - x1, z2 - hz2) -- south strip
	add(x1, hz1, hx1 - x1, hz2 - hz1) -- west strip
	add(hx2, hz1, x2 - hx2, hz2 - hz1) -- east strip
	return pieces
end

--- Subtracts every hole from a starting rectangle.
function Structures.subtractAll(rect: Types.Rect, holes: { Types.Rect }): { Types.Rect }
	local pieces: { Types.Rect } = { rect }
	for _, hole in holes do
		local next_: { Types.Rect } = {}
		for _, piece in pieces do
			for _, remainder in Structures.subtractRect(piece, hole) do
				table.insert(next_, remainder)
			end
		end
		pieces = next_
	end
	return pieces
end

--------------------------------------------------------------------
-- Clutter
--------------------------------------------------------------------

--- A prop in the catalogue and how big to build it.
type PropSpec = { prop: string, size: Vector3 }

local YARD_PROPS: { PropSpec } = {
	{ prop = "Bin", size = Vector3.new(4, 6.5, 4) },
	{ prop = "Planter", size = Vector3.new(5, 4.5, 5) },
	{ prop = "Crate", size = Vector3.new(5, 3.4, 4.5) },
	{ prop = "Chair", size = Vector3.new(4, 5, 4) },
	{ prop = "Barrel", size = Vector3.new(4, 5.5, 4) },
	{ prop = "Bush", size = Vector3.new(6, 6, 6) },
	{ prop = "Rock", size = Vector3.new(4, 3, 4) },
}

local ROOM_PROPS: { PropSpec } = {
	{ prop = "Crate", size = Vector3.new(5, 3.4, 4.5) },
	{ prop = "Barrel", size = Vector3.new(4, 6, 4) },
	{ prop = "Bin", size = Vector3.new(4, 6, 4) },
	{ prop = "Rock", size = Vector3.new(4, 3, 4) },
}

--[[
	Scatters props across a zone.

	Props sit on the zone's own floor and do not collide, so they never wall a
	player off from a tile they still have to clear — they only make it harder
	to spot, which is the whole point.
]]
function Structures.clutter(context: Context, zone: Types.ZoneDef, count: number)
	if count <= 0 then
		return
	end

	local elevation = zone.elevation or 0
	local set = if zone.kind == "room" then ROOM_PROPS else YARD_PROPS
	local folder = Build.folder(`Clutter_{zone.id}`, context.parent)
	local r = zone.rect

	--[[
		A pool section's clutter stays on the deck.

		The scatter used to pick any tile in the rect, and the middle of a pool
		section's rect is water — so crates and chairs sat on the surface of
		the pool like it was ice. The same rectangle the ground builder cuts
		the basin with is the one the scatter now avoids.
	]]
	local water: Types.Rect? = if zone.kind == "pool" then Structures.poolRect(zone) else nil

	for _ = 1, count do
		local spec = set[context.rng:NextInteger(1, #set)]
		local tx, tz
		for _ = 1, 20 do
			tx = context.rng:NextInteger(r.x, r.x + r.w - 1)
			tz = context.rng:NextInteger(r.z, r.z + r.d - 1)
			if
				not water
				or tx < water.x
				or tx >= water.x + water.w
				or tz < water.z
				or tz >= water.z + water.d
			then
				break
			end
		end
		local at = context.flat(tx, tz) + Vector3.new(0, elevation, 0)

		Build.mesh({
			prop = spec.prop,
			size = spec.size,
			cframe = CFrame.new(at + Vector3.new(0, spec.size.Y * 0.5, 0))
				* CFrame.Angles(0, context.rng:NextNumber() * math.pi * 2, 0),
			canCollide = false,
			parent = folder,
		})
	end
end

--------------------------------------------------------------------
-- Rooms
--------------------------------------------------------------------

--[[
	Walls a zone in.

	A cellar is built as a sunken open-topped room rather than a sealed box with
	a ceiling: the player can see down into it, walk in via the stairs, and the
	renderer never has to hide a roof to make the inside visible.
]]
--[[
	Four walls around a rectangle, with at most one gap in them.

	The gap is the whole point. A cellar walled in on all four sides is a sealed
	box however good the stairs leading to it are, and a rooftop ringed by an
	unbroken parapet is one you can only fall off. Both were built that way,
	which left the basement — the last section on the critical path — with no
	way in, and so no world could be finished.
]]
function Structures.wallRing(options: WallRingOptions)
	local centre = options.centre
	local halfWidth, halfDepth = options.width * 0.5, options.depth * 0.5
	local opening = options.opening

	local sides: { RingSide } = {
		{ normal = Vector3.new(0, 0, -1), offset = Vector3.new(0, 0, -halfDepth), span = options.width, alongX = true },
		{ normal = Vector3.new(0, 0, 1), offset = Vector3.new(0, 0, halfDepth), span = options.width, alongX = true },
		{ normal = Vector3.new(-1, 0, 0), offset = Vector3.new(-halfWidth, 0, 0), span = options.depth, alongX = false },
		{ normal = Vector3.new(1, 0, 0), offset = Vector3.new(halfWidth, 0, 0), span = options.depth, alongX = false },
	}

	for _, side in sides do
		-- Where this side is broken, measured along its own length from its
		-- centre. An empty span leaves the wall whole.
		local gapLow, gapHigh = 0, 0
		if opening and side.normal:Dot(opening.normal) > 0.9 then
			local half = math.max(math.min(opening.width, side.span - 4), 0) * 0.5
			local reach = side.span * 0.5 - half
			local at = math.clamp(opening.offset or 0, -reach, reach)
			gapLow, gapHigh = at - half, at + half
		end

		local runs: { { number } } = if gapHigh > gapLow
			then { { -side.span * 0.5, gapLow }, { gapHigh, side.span * 0.5 } }
			else { { -side.span * 0.5, side.span * 0.5 } }

		for _, run in runs do
			local low, high = run[1], run[2]
			local length = high - low
			if length > 0.1 then
				local mid = (low + high) * 0.5
				--[[
					One plain part per run, in the caller's material.

					These were panels of the brick model, tinted — and the
					model's own paint is a mossy blue-green with hard contrast
					between bricks, which a tint can shift but never quiet. It
					is why the wash bay read as a chequerboard from across the
					lot. Every caller already names the material it wants
					(brick, concrete, slate); now the wall is actually made of
					it, and the panelling is unnecessary because materials
					tile.
				]]
				local at = (low + high) * 0.5
				local size = if side.alongX
					then Vector3.new(length, options.height, options.thickness)
					else Vector3.new(options.thickness, options.height, length)
				local slide = if side.alongX then Vector3.new(at, 0, 0) else Vector3.new(0, 0, at)
				Build.part({
					name = options.name,
					size = size,
					cframe = CFrame.new(
						centre + side.offset + slide + Vector3.new(0, options.height * 0.5, 0)
					),
					color = options.color,
					material = options.material,
					parent = options.parent,
				})
			end
		end
	end
end

--[[
	The low wall around a rooftop, with a gap where its stairs arrive.

	It sits on the deck, which overhangs the section by two studs on every side,
	so the gap lines up with a flight that climbs to the deck's edge rather than
	to the section's.
]]
function Structures.parapet(context: Context, zone: Types.ZoneDef, height: number, opening: Opening?)
	local r = zone.rect
	local tile = context.tileSize
	local elevation = zone.elevation or 0
	local centre = context.flat(r.x + r.w * 0.5, r.z + r.d * 0.5) + Vector3.new(0, elevation, 0)

	Structures.wallRing({
		name = "Parapet",
		centre = centre,
		width = r.w * tile + 4,
		depth = r.d * tile + 4,
		height = height,
		thickness = 1.5,
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.Slate,
		parent = context.parent,
		opening = opening,
	})
end

function Structures.room(context: Context, zone: Types.ZoneDef, wallHeight: number, sunken: boolean, opening: Opening?)
	local r = zone.rect
	local elevation = zone.elevation or 0
	local tile = context.tileSize
	local folder = Build.folder(`Room_{zone.id}`, context.parent)

	local centre = context.flat(r.x + r.w * 0.5, r.z + r.d * 0.5) + Vector3.new(0, elevation, 0)
	local width, depth = r.w * tile, r.d * tile

	--[[
		A floor is a surface, so it gets a material rather than a model.

		The concrete panel model is about a stud and a half across. Scaled to an
		eighty by fifty-six stud cellar it stopped being concrete and became one
		enormous smeared slab, because a mesh texture stretches rather than
		repeating. Roblox's concrete tiles at any size.
	]]
	Build.part({
		name = "Floor",
		size = Vector3.new(width, 2, depth),
		cframe = CFrame.new(centre - Vector3.new(0, 1, 0)),
		color = Palette.color(Palette.ground.stoneDark),
		material = Enum.Material.Concrete,
		parent = folder,
	})

	local wallColor = if sunken
		then Palette.color(Palette.house.brickDark)
		else Palette.color(Palette.house.siding)
	Structures.wallRing({
		name = "Wall",
		centre = centre,
		width = width,
		depth = depth,
		height = wallHeight,
		thickness = 1.5,
		color = wallColor,
		material = Enum.Material.Concrete,
		parent = folder,
		opening = opening,
	})

	-- An above-ground room gets a roof; a sunken one stays open so you can see in.
	if not sunken then
		-- Slate rather than the shingle model, which at this size was a coarse
		-- green chequerboard rather than a roof.
		Build.part({
			name = "Ceiling",
			size = Vector3.new(width + 2, 1.5, depth + 2),
			cframe = CFrame.new(centre + Vector3.new(0, wallHeight, 0)),
			color = Palette.color(Palette.house.roof),
			material = Enum.Material.Slate,
			parent = folder,
		})
	end

	return folder
end

--- How far one step lifts you. Low enough to walk up without jumping.
local STEP_RISE = 1.5

--[[
	A flight of steps from `from` down or up to `to`.

	The step count comes from the climb rather than being handed in. A fixed
	fourteen steps over a fixed eight-stud run turned the roof's twenty-four
	studs of height into 1.7-stud risers only 0.6 studs deep, which is a ladder
	with no tread to stand on — the character jammed halfway up every time. One
	step per 1.5 studs of climb keeps a flight walkable whatever it has to
	climb, so long as the caller gives it a run to spread over.

	Each step is placed by its tread rather than its centre, so the top tread
	lands exactly on `to` and meets the floor it arrives at flush.
]]
function Structures.stairs(context: Context, from: Vector3, to: Vector3, width: number, parent: Instance)
	local delta = to - from
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local run = flat.Magnitude
	if run < 0.1 then
		return
	end

	local steps = math.max(2, math.ceil(math.abs(delta.Y) / STEP_RISE))
	local direction = flat.Unit
	local stepRun = run / steps
	local stepRise = delta.Y / steps
	local thickness = math.max(math.abs(stepRise), 0.6) + 0.6

	for index = 1, steps do
		local tread = from
			+ direction * (stepRun * (index - 0.5))
			+ Vector3.new(0, stepRise * index, 0)
		local at = tread - Vector3.new(0, thickness * 0.5, 0)
		Build.mesh({
			prop = "StepBlock",
			name = "Step",
			size = Vector3.new(width, thickness, stepRun + 0.4),
			cframe = CFrame.lookAt(at, at + direction),
			parent = parent,
		})
	end
end

--------------------------------------------------------------------
-- Pool
--------------------------------------------------------------------

--- A sunken pool in the middle of a deck zone, with water you can see.
--- How far a pool is inset from its zone's edge, leaving deck to clean.
local POOL_INSET = 4

--[[
	The tiles a pool's water covers.

	Shared with the ground builder and the tile filler: the lawn needs a hole
	cut here or the pool is buried under it, and the grass must not be sown
	here or it floats on the water.
]]
function Structures.poolRect(zone: Types.ZoneDef): Types.Rect
	local r = zone.rect
	return {
		x = r.x + POOL_INSET,
		z = r.z + POOL_INSET,
		w = math.max(r.w - POOL_INSET * 2, 4),
		d = math.max(r.d - POOL_INSET * 2, 4),
	}
end

function Structures.pool(context: Context, zone: Types.ZoneDef)
	local tile = context.tileSize
	local folder = Build.folder(`Pool_{zone.id}`, context.parent)

	local r = zone.rect
	local basin = Structures.poolRect(zone)
	local width = basin.w * tile
	local depth = basin.d * tile
	local centre = context.flat(r.x + r.w * 0.5, r.z + r.d * 0.5)

	--[[
		A pan, not a block.

		The basin was one solid eight-stud box with the water part inside it, so
		the pool was a slab of concrete with its water sealed in the middle
		where nobody could see it, let alone swim in it. A floor and four walls
		leave a hole with water in it, which is what a pool is.
	]]
	local depthBelow = 6
	local rim = 1.5
	local floorY = -depthBelow - 0.5

	Build.part({
		name = "PoolFloor",
		size = Vector3.new(width + rim * 2, 1, depth + rim * 2),
		cframe = CFrame.new(centre + Vector3.new(0, floorY, 0)),
		color = Palette.color(Palette.ground.path),
		material = Enum.Material.Concrete,
		parent = folder,
	})

	Structures.wallRing({
		name = "PoolWall",
		centre = centre + Vector3.new(0, -depthBelow, 0),
		width = width + rim * 2,
		depth = depth + rim * 2,
		height = depthBelow,
		thickness = rim,
		color = Palette.color(Palette.ground.path),
		material = Enum.Material.Concrete,
		parent = folder,
	})

	-- Sitting just below the lip, so the surface reads as water in a hole
	-- rather than as a sheet laid over the lawn.
	local water = Build.part({
		name = "Water",
		size = Vector3.new(width, depthBelow - 0.6, depth),
		cframe = CFrame.new(centre + Vector3.new(0, -(depthBelow - 0.6) * 0.5 - 0.6, 0)),
		color = Palette.color(Palette.props.pool),
		material = Enum.Material.Glass,
		transparency = 0.35,
		canCollide = false,
		parent = folder,
	})
	water.Reflectance = 0.2

	return folder
end

--------------------------------------------------------------------
-- Hedge maze
--------------------------------------------------------------------

--[[
	A simple maze of hedge walls.

	Rows of hedge with staggered gaps, rather than a generated perfect maze: it
	reads as a maze from inside, costs a handful of parts, and never traps a
	player in a dead end they have to walk all the way back out of.
]]
function Structures.maze(context: Context, zone: Types.ZoneDef)
	local r = zone.rect
	local tile = context.tileSize
	local folder = Build.folder(`Maze_{zone.id}`, context.parent)

	local rows = math.max(math.floor(r.d / 4), 1)
	for row = 1, rows - 1 do
		local tz = r.z + math.floor(r.d * row / rows)
		-- Two gaps per row, offset each time, so the route weaves.
		local gapA = r.x + ((row * 5) % math.max(r.w - 6, 1)) + 1
		local gapB = r.x + ((row * 11) % math.max(r.w - 6, 1)) + 1

		local tx = r.x
		while tx < r.x + r.w do
			local inGap = (tx >= gapA and tx < gapA + 3) or (tx >= gapB and tx < gapB + 3)
			if not inGap then
				local at = context.flat(tx, tz)
				Build.mesh({
					prop = "Hedge",
					name = "Hedge",
					size = Vector3.new(tile + 1, 9, tile * 0.9 + 1),
					collisionSize = Vector3.new(tile, 9, tile * 0.9),
					cframe = CFrame.new(at + Vector3.new(0, 4.5, 0)),
					parent = folder,
				})
			end
			tx += 1
		end
	end

	return folder
end

return Structures
