--!strict
--[[
	Structures — the built parts of a detailed residential property.

	Rooms, the pool, the hedge maze, the porch stairs onto the roof, the
	stairwell down to the cellar, and the clutter that debris hides against.

	That last one is not decoration. A completion bar over an empty field makes
	the final few percent a tedious sweep; the same bar over a yard full of bins,
	planters and patio furniture makes it a hunt. Clutter is the mechanic.
]]

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

type PropSpec = { name: string, size: Vector3, color: Color3, material: Enum.Material }

local YARD_PROPS: { PropSpec } = {
	{ name = "Bin", size = Vector3.new(4, 6, 4), color = Color3.fromRGB(58, 78, 62), material = Enum.Material.Plastic },
	{ name = "Planter", size = Vector3.new(6, 3, 6), color = Color3.fromRGB(142, 92, 66), material = Enum.Material.Slate },
	{ name = "Crate", size = Vector3.new(5, 5, 5), color = Color3.fromRGB(158, 120, 74), material = Enum.Material.WoodPlanks },
	{ name = "Chair", size = Vector3.new(4, 4, 4), color = Color3.fromRGB(216, 214, 206), material = Enum.Material.Plastic },
	{ name = "Barrel", size = Vector3.new(4, 5.5, 4), color = Color3.fromRGB(96, 104, 112), material = Enum.Material.Metal },
	{ name = "Bush", size = Vector3.new(7, 5, 7), color = Color3.fromRGB(44, 96, 44), material = Enum.Material.Grass },
}

local ROOM_PROPS: { PropSpec } = {
	{ name = "Box", size = Vector3.new(5, 5, 5), color = Color3.fromRGB(168, 138, 96), material = Enum.Material.Cardboard },
	{ name = "Shelf", size = Vector3.new(3, 10, 8), color = Color3.fromRGB(120, 88, 60), material = Enum.Material.Wood },
	{ name = "Toolbox", size = Vector3.new(5, 3, 3), color = Color3.fromRGB(180, 62, 54), material = Enum.Material.Metal },
	{ name = "Drum", size = Vector3.new(4, 6, 4), color = Color3.fromRGB(72, 92, 108), material = Enum.Material.Metal },
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

	for _ = 1, count do
		local spec = set[context.rng:NextInteger(1, #set)]
		local tx = context.rng:NextInteger(r.x, r.x + r.w - 1)
		local tz = context.rng:NextInteger(r.z, r.z + r.d - 1)
		local at = context.flat(tx, tz) + Vector3.new(0, elevation, 0)

		Build.part({
			name = spec.name,
			size = spec.size,
			cframe = CFrame.new(at + Vector3.new(0, spec.size.Y * 0.5, 0))
				* CFrame.Angles(0, context.rng:NextNumber() * math.pi * 2, 0),
			color = spec.color,
			material = spec.material,
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
function Structures.room(context: Context, zone: Types.ZoneDef, wallHeight: number, sunken: boolean)
	local r = zone.rect
	local elevation = zone.elevation or 0
	local tile = context.tileSize
	local folder = Build.folder(`Room_{zone.id}`, context.parent)

	local centre = context.flat(r.x + r.w * 0.5, r.z + r.d * 0.5) + Vector3.new(0, elevation, 0)
	local width, depth = r.w * tile, r.d * tile

	Build.part({
		name = "Floor",
		size = Vector3.new(width, 2, depth),
		cframe = CFrame.new(centre - Vector3.new(0, 1, 0)),
		color = Color3.fromRGB(104, 100, 96),
		material = Enum.Material.Concrete,
		parent = folder,
	})

	local wallColor = if sunken then Color3.fromRGB(88, 84, 80) else Color3.fromRGB(196, 190, 178)
	local sides = {
		{ Vector3.new(0, 0, -depth * 0.5), Vector3.new(width, wallHeight, 1.5) },
		{ Vector3.new(0, 0, depth * 0.5), Vector3.new(width, wallHeight, 1.5) },
		{ Vector3.new(-width * 0.5, 0, 0), Vector3.new(1.5, wallHeight, depth) },
		{ Vector3.new(width * 0.5, 0, 0), Vector3.new(1.5, wallHeight, depth) },
	}
	for _, side in sides do
		Build.part({
			name = "Wall",
			size = side[2],
			cframe = CFrame.new(centre + side[1] + Vector3.new(0, wallHeight * 0.5, 0)),
			color = wallColor,
			material = Enum.Material.Concrete,
			parent = folder,
		})
	end

	-- An above-ground room gets a roof; a sunken one stays open so you can see in.
	if not sunken then
		Build.part({
			name = "Ceiling",
			size = Vector3.new(width + 2, 1.5, depth + 2),
			cframe = CFrame.new(centre + Vector3.new(0, wallHeight, 0)),
			color = Color3.fromRGB(84, 78, 72),
			material = Enum.Material.Slate,
			parent = folder,
		})
	end

	return folder
end

--- A flight of steps from `from` down or up to `to`.
function Structures.stairs(context: Context, from: Vector3, to: Vector3, width: number, steps: number, parent: Instance)
	local delta = to - from
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local run = flat.Magnitude
	if run < 0.1 or steps <= 0 then
		return
	end

	local direction = flat.Unit
	local stepRun = run / steps
	local stepRise = delta.Y / steps

	for index = 1, steps do
		local at = from + direction * (stepRun * (index - 0.5)) + Vector3.new(0, stepRise * index, 0)
		Build.part({
			name = "Step",
			size = Vector3.new(width, math.max(math.abs(stepRise), 0.6) + 0.6, stepRun + 0.4),
			cframe = CFrame.lookAt(at, at + direction),
			color = Color3.fromRGB(176, 170, 158),
			material = Enum.Material.Concrete,
			parent = parent,
		})
	end
end

--------------------------------------------------------------------
-- Pool
--------------------------------------------------------------------

--- A sunken pool in the middle of a deck zone, with water you can see.
function Structures.pool(context: Context, zone: Types.ZoneDef)
	local r = zone.rect
	local tile = context.tileSize
	local folder = Build.folder(`Pool_{zone.id}`, context.parent)

	-- Inset from the zone edge so there is deck left to actually clean.
	local inset = 4
	local width = math.max(r.w - inset * 2, 4) * tile
	local depth = math.max(r.d - inset * 2, 4) * tile
	local centre = context.flat(r.x + r.w * 0.5, r.z + r.d * 0.5)

	Build.part({
		name = "PoolBasin",
		size = Vector3.new(width + 3, 8, depth + 3),
		cframe = CFrame.new(centre - Vector3.new(0, 4.2, 0)),
		color = Color3.fromRGB(226, 232, 236),
		material = Enum.Material.Concrete,
		parent = folder,
	})

	local water = Build.part({
		name = "Water",
		size = Vector3.new(width, 6, depth),
		cframe = CFrame.new(centre - Vector3.new(0, 3.4, 0)),
		color = Color3.fromRGB(72, 158, 206),
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
				Build.part({
					name = "Hedge",
					size = Vector3.new(tile, 9, tile * 0.9),
					cframe = CFrame.new(at + Vector3.new(0, 4.5, 0)),
					color = Color3.fromRGB(38, 88, 40),
					material = Enum.Material.Grass,
					parent = folder,
				})
			end
			tx += 1
		end
	end

	return folder
end

return Structures
