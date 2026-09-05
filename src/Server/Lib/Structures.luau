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
local Worlds = require(game:GetService("ReplicatedStorage").Shared.Config.Worlds)
local Build = require(script.Parent.Build)

local Structures = {}

export type Context = {
	parent: Instance,
	--- The world being built, for placement rules that read its layout.
	world: Types.WorldDef,
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
	--- Opaque unless asked otherwise, so a ring can be glazing as well as wall.
	transparency: number?,
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

	--[[
		A room's walls stand on the edge tiles of its rect.

		The scatter picked any tile in the rect, edges included, so a crate
		could be built standing inside a wall — measured across the three
		worlds, six of two hundred props were, every one of them in a `room`
		zone and every one on a boundary tile. They read as half a barrel
		poking out of a cellar wall.

		Trees solve this by asking the world what is already there, which they
		can do because they are planted after it is built. Clutter goes up
		during the build, when the wall beside it may not exist yet, so it
		keeps a tile clear instead — wherever the room is big enough to spare
		one.
	]]
	local walled = zone.kind == "room"
	local insetX = if walled and r.w > 2 then 1 else 0
	local insetZ = if walled and r.d > 2 then 1 else 0

	--[[
		No prop piles up in one section.

		Every clutter item was drawn uniformly from a set of four (rooms) or
		seven (yards), so a section with twenty items got a handful of each:
		measured over 72 section loads, one workshop had ten barrels, a
		basement eight crates, a back lot eight chairs and seven planters.
		Every section on the property had bins and boxes standing about in
		the grass like a collection. One bin reads as where the clippings
		go; the fifth reads as litter, and the eighth chair as a showroom.

		So each prop has a ceiling per section. Containers — bin, crate,
		barrel — and chairs are one each; a planter can pair up; bushes and
		rocks are natural in threes. A room never repeats anything, because
		rooms are small and hold four things well. When a prop reaches its
		ceiling it leaves the pool; when the pool is empty the scatter
		stops, which is what quietly retires the twenty-item counts.
	]]
	local YARD_CAP: { [string]: number } = { Bin = 1, Crate = 1, Barrel = 1, Chair = 1, Planter = 2, Bush = 3, Rock = 3 }
	local pool: { PropSpec } = table.clone(set)
	local placed: { [string]: number } = {}
	for _ = 1, count do
		if #pool == 0 then
			break
		end
		local spec = pool[context.rng:NextInteger(1, #pool)]
		placed[spec.prop] = (placed[spec.prop] or 0) + 1
		local cap = if walled then 1 else (YARD_CAP[spec.prop] or 1)
		if placed[spec.prop] >= cap then
			for k, entry in pool do
				if entry.prop == spec.prop then
					table.remove(pool, k)
					break
				end
			end
		end
		local tx, tz
		for _ = 1, 20 do
			tx = context.rng:NextInteger(r.x + insetX, r.x + r.w - 1 - insetX)
			tz = context.rng:NextInteger(r.z + insetZ, r.z + r.d - 1 - insetZ)
			local onWater = water ~= nil
				and tx >= water.x
				and tx < water.x + water.w
				and tz >= water.z
				and tz < water.z + water.d
			-- Off the paving for the same reason it stays off the water: a
			-- planter in the middle of the driveway sits like a crate on a
			-- pool.
			local flat = context.flat(tx, tz)
			if not onWater and not Worlds.onPaving(context.world, flat.X, flat.Z, 1) then
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
-- Settling clutter
--------------------------------------------------------------------

--[[
	How deep a prop may sit in something before it counts as buried.

	Relative to the prop's own smallest dimension, because a rock overlapping
	a hedge by three studs is most of the rock and a crate resting on a slab
	overlaps it by nothing at all. Measured across the three worlds this
	separates the four genuine cases from the hundred and fifty-six props that
	are simply touching what they stand on.
]]
local BURIED_FRACTION = 0.4
local BURIED_FLOOR = 0.5
--- Where to try instead, in studs, nearest first.
local NUDGES = { 3, 6, 9 }

--- A part's world-axis-aligned bounds, from the eight corners of its box, so
--- a block turned ninety degrees does not report its width as its depth.
local function worldBounds(part: BasePart): (Vector3, Vector3)
	local half = part.Size * 0.5
	local lo, hi = nil, nil
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local corner = part.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
				lo = if lo then lo:Min(corner) else corner
				hi = if hi then hi:Max(corner) else corner
			end
		end
	end
	return lo :: Vector3, hi :: Vector3
end

--- How far two axis-aligned boxes interpenetrate: the smallest of the three
--- axis overlaps.
local function penetration(aLo: Vector3, aHi: Vector3, bLo: Vector3, bHi: Vector3): number
	local ox = math.min(aHi.X, bHi.X) - math.max(aLo.X, bLo.X)
	local oy = math.min(aHi.Y, bHi.Y) - math.max(aLo.Y, bLo.Y)
	local oz = math.min(aHi.Z, bHi.Z) - math.max(aLo.Z, bLo.Z)
	if ox <= 0 or oy <= 0 or oz <= 0 then
		return 0
	end
	return math.min(ox, oy, oz)
end

--[[
	The deepest thing this prop is currently inside.

	Measured against what a thing *is*, not against each part of it. A hedge
	is thirty blocks in a row, and a bin standing across the join of two of
	them overlaps each block only a little along the line — the smallest axis
	— while being most of its width into the hedge. Per block that came out
	under the limit, and the pass this feeds walked past a bin and a chair
	that were more than half inside the back hedge, which is exactly the case
	it was written to catch. So the parts the prop touches are grouped by
	what they belong to, each group is one box, and the prop is measured
	against that box.
]]
local function deepest(prop: BasePart, ignore: Instance): number
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }
	params.MaxParts = 16
	local pLo, pHi = worldBounds(prop)
	local groups: { [Instance]: { lo: Vector3, hi: Vector3 } } = {}
	for _, other in workspace:GetPartsInPart(prop, params) do
		local key: Instance = other.Parent or other
		local lo, hi = worldBounds(other)
		local group = groups[key]
		if group then
			group.lo = group.lo:Min(lo)
			group.hi = group.hi:Max(hi)
		else
			groups[key] = { lo = lo, hi = hi }
		end
	end
	local worst = 0
	for _, group in groups do
		worst = math.max(worst, penetration(pLo, pHi, group.lo, group.hi))
	end
	return worst
end

--- Drops a prop onto whatever is under it, so a nudge never leaves it hanging.
local function reseat(prop: BasePart, ignore: Instance)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }
	local from = prop.Position + Vector3.new(0, 40, 0)
	local hit = workspace:Raycast(from, Vector3.new(0, -200, 0), params)
	if hit then
		prop.CFrame = CFrame.new(hit.Position + Vector3.new(0, prop.Size.Y * 0.5, 0))
			* (prop.CFrame - prop.CFrame.Position)
	end
end

--[[
	Moves any prop that ended up inside the scenery.

	The scatter avoids what it can be told about — the water in a pool, the
	paving, the tiles a room's walls stand on — but it runs during the build,
	and the comment on `clutter` above says why it cannot simply look: the
	wall beside it may not exist yet. So the maze hedges, the retaining wall
	round the pool court and the cellar stairs, all of which go up afterwards,
	were never in the conversation. Measured across the three worlds, four
	props of a hundred and sixty were standing inside one of them — a bin and
	a rock in the Long Maze's hedges, a crate in the pool court's retaining
	wall, a barrel inside the basement stairs.

	Asking afterwards is the same trick trees already use, and the same reason
	`clearBuriedTiles` runs last: once everything is built, the question has an
	answer. Nudging beats re-rolling because it keeps the scatter the designer
	tuned; a prop with nowhere to go is dropped rather than left in a wall.
]]
function Structures.settleClutter(parent: Instance)
	for _, folder in parent:GetChildren() do
		if not folder:IsA("Folder") or string.sub(folder.Name, 1, 8) ~= "Clutter_" then
			continue
		end
		for _, prop in folder:GetChildren() do
			if not prop:IsA("BasePart") then
				continue
			end
			local limit = math.max(BURIED_FLOOR, math.min(prop.Size.X, prop.Size.Y, prop.Size.Z) * BURIED_FRACTION)
			if deepest(prop, folder) <= limit then
				continue
			end

			local home = prop.CFrame
			local settled = false
			for _, radius in NUDGES do
				for step = 0, 7 do
					local angle = step * math.pi * 0.25
					prop.CFrame = home + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
					reseat(prop, folder)
					if deepest(prop, folder) <= limit then
						settled = true
						break
					end
				end
				if settled then
					break
				end
			end

			if not settled then
				prop:Destroy()
			end
		end
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
					transparency = options.transparency,
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
	--[[
		Lifted a hair, because two floors at the same height is not a floor.

		A room at ground level laid its slab with a top face at exactly y = 0,
		and the ground plates under it end at exactly y = 0 as well. Two
		coplanar surfaces give the renderer no way to decide which is in front,
		so it picks differently from one frame to the next and the garage floor
		visibly shimmers as you walk over it — reported as "the floor of the
		garage glitches", which is exactly what it is.

		Two hundredths of a stud settles it and is far below anything a
		character can feel underfoot. A sunken room is already well clear of
		the ground and does not need it.
	]]
	local lift = if sunken then 0 else 0.02
	Build.part({
		name = "Floor",
		size = Vector3.new(width, 2, depth),
		cframe = CFrame.new(centre - Vector3.new(0, 1 - lift, 0)),
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
		--[[
			A roof with eaves, and a fascia under them.

			The ceiling used to stop one stud past the walls, which on the
			Gas Station's wash bay meant a hundred-and-eighty stud run of
			bare concrete with a lid on it — the largest blank surface in
			the game once the shop got its back door. The house gets its
			roofline from overhanging eaves and a room gets one the same
			way: the shadow the overhang casts is what stops a long wall
			reading as a sheet.
		]]
		local OVERHANG, FASCIA = 2.5, 2.6
		Build.part({
			name = "Ceiling",
			size = Vector3.new(width + OVERHANG * 2, 1.5, depth + OVERHANG * 2),
			cframe = CFrame.new(centre + Vector3.new(0, wallHeight, 0)),
			color = Palette.color(Palette.house.roof),
			material = Enum.Material.Slate,
			parent = folder,
		})
		local fasciaY = wallHeight - 0.75 - FASCIA * 0.5
		for _, sz in { -1, 1 } do
			Build.part({
				name = "Eaves",
				size = Vector3.new(width + OVERHANG * 2, FASCIA, 1.4),
				cframe = CFrame.new(
					centre + Vector3.new(0, fasciaY, sz * (depth * 0.5 + OVERHANG - 0.7))
				),
				-- The roof's own colour: a fascia belongs to the roof, and the
				-- trim teal that suits a house is a stranger on a filling
				-- station's wash bay.
				color = Palette.color(Palette.house.roof),
				material = Enum.Material.SmoothPlastic,
				canCollide = false,
				parent = folder,
			})
		end
		for _, sx in { -1, 1 } do
			Build.part({
				name = "Eaves",
				size = Vector3.new(1.4, FASCIA, depth + OVERHANG * 2),
				cframe = CFrame.new(
					centre + Vector3.new(sx * (width * 0.5 + OVERHANG - 0.7), fasciaY, 0)
				),
				-- The roof's own colour: a fascia belongs to the roof, and the
				-- trim teal that suits a house is a stranger on a filling
				-- station's wash bay.
				color = Palette.color(Palette.house.roof),
				material = Enum.Material.SmoothPlastic,
				canCollide = false,
				parent = folder,
			})
		end

		--[[
			Lamps, because a roofed room is a box the sun cannot reach.

			Every roofed section played in the dark: the walls and ceiling
			seal out the daylight, nothing inside emitted any, and the
			player was left mowing a floor they could not see. One warm
			fixture per rough fourteen-tile bay reads as worklights strung
			from the ceiling and keeps the part count honest.

			The spacing is set by what a light costs, not by what looks
			even: at one per eight tiles the Mansion's orangery hung
			twenty-four of them and gave back a sixth of the frame rate,
			which is not a trade worth making on the tablet this is played
			on. Fewer fixtures with the range to reach between them light
			the same floor for a third of the lights.
		]]
		local lampsX = math.max(math.floor(width / 42), 1)
		local lampsZ = math.max(math.floor(depth / 42), 1)
		for ix = 1, lampsX do
			for iz = 1, lampsZ do
				local at = centre
					+ Vector3.new(
						width * (ix / (lampsX + 1) - 0.5),
						wallHeight - 1.2,
						depth * (iz / (lampsZ + 1) - 0.5)
					)
				local lamp = Build.part({
					name = "Lamp",
					size = Vector3.new(2.4, 0.4, 2.4),
					cframe = CFrame.new(at),
					color = Color3.fromRGB(255, 236, 200),
					material = Enum.Material.Neon,
					canCollide = false,
					castShadow = false,
					parent = folder,
				})
				local light = Instance.new("PointLight")
				light.Color = Color3.fromRGB(255, 226, 180)
				light.Brightness = 1.1
				light.Range = 58
				light.Shadows = false
				light.Parent = lamp
			end
		end
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
function Structures.stairs(_context: Context, from: Vector3, to: Vector3, width: number, parent: Instance)
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

	-- A solid stringer under the whole flight. Bare treads float in the air
	-- with daylight between them, which reads as scaffolding from any low
	-- angle; a wedge filling the space underneath turns the flight into one
	-- carved block the treads are cut from. The taper (-Z) points downhill.
	local rise = math.abs(delta.Y)
	if rise > 1 then
		local lowY = math.min(from.Y, to.Y)
		local centre = (from + to) * 0.5
		local downhill = if delta.Y > 0 then -direction else direction
		local wedge = Instance.new("WedgePart")
		wedge.Name = "StairStringer"
		wedge.Anchored = true
		wedge.Size = Vector3.new(width, rise, run)
		wedge.CFrame = CFrame.lookAt(
			Vector3.new(centre.X, lowY + rise * 0.5, centre.Z),
			Vector3.new(centre.X, lowY + rise * 0.5, centre.Z) + downhill
		)
		wedge.Material = Enum.Material.Concrete
		local tint = Palette.color(Palette.ground.path)
		wedge.Color = Color3.new(tint.R * 0.88, tint.G * 0.88, tint.B * 0.88)
		wedge.Parent = parent
	end

	for index = 1, steps do
		local tread = from
			+ direction * (stepRun * (index - 0.5))
			+ Vector3.new(0, stepRise * index, 0)
		local at = tread - Vector3.new(0, thickness * 0.5, 0)
		Build.mesh({
			prop = "StepBlock",
			name = "Step",
			-- Painted stone for the same reason the porch steps are: the
			-- model's own texture is a pale blue that reads as bare plastic.
			untextured = true,
			color = Palette.color(Palette.ground.path),
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

--------------------------------------------------------------------
-- The estate's own sections
--------------------------------------------------------------------

--[[
	Three kinds of place that exist only on The Mansion.

	The first property is a lawn, a garage, a roof, a pool, a maze and a
	cellar, and until now the second one was the same six things with longer
	names — a "Grand Lawn" is an open section, an "Orangery" is a room, "The
	Cellars" is a sunken room. Reported as the second property looking
	identical to the first, which it structurally was.

	A court, a terrace and a glasshouse are not dressings on those: each is a
	surface you have never mown on before, with its own way in and its own
	reason to be somewhere.
]]

--[[
	A tennis court: tarmac, painted lines, a net, and a mesh surround.

	The debris still lies on the section's tiles exactly as it does on grass,
	so nothing about clearing it changes — what changes is that you are doing
	it on a hard blue court between two fences, which looks nothing like a
	lawn and reads from the far side of the estate.
]]
function Structures.court(context: Context, zone: Types.ZoneDef)
	local tile = context.tileSize
	local folder = Build.folder(`Court_{zone.id}`, context.parent)
	local r = zone.rect
	local centre = context.flat(r.x + r.w * 0.5, r.z + r.d * 0.5)
	local width, depth = r.w * tile, r.d * tile

	--[[
		The playing surface, finishing exactly at ground level.

		Debris is drawn on the section's own floor — ground level for anything
		unelevated — so a surface whose top face sits even half a stud proud of
		that buries every leaf on the court inside the tarmac. Half the section
		would be invisible and still counted, which is the fault that already
		cost a player two sections of the first property. The top face is at
		`groundY`, and the apron sits a shade below it so the edge still reads
		as a kerb.

		A shade proud of it rather than flush: the lawn slab's own top face is
		at `groundY` too, and two surfaces at the same height flicker against
		each other across the whole court. Six hundredths is under the leaves
		lying on it and enough to win the depth test.
	]]
	Build.part({
		name = "CourtSurface",
		size = Vector3.new(width, 1.2, depth),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY - 0.54, 0)),
		color = Palette.color(Palette.court.tarmac),
		material = Enum.Material.Asphalt,
		parent = folder,
	})
	Build.part({
		name = "CourtApron",
		size = Vector3.new(width + 5, 0.9, depth + 5),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY - 0.42, 0)),
		color = Palette.color(Palette.court.apron),
		material = Enum.Material.Asphalt,
		parent = folder,
	})

	--[[
		The painted lines, which are the whole reason this reads as a court.

		Laid as thin white slabs a hair above the tarmac: the tramlines down
		each side, the baselines across each end, and the service box through
		the middle. Proportional to the section rather than to a real court,
		because the section is whatever the world says it is.
	]]
	local LINE = 0.9
	local inset = 6
	local function line(cx: number, cz: number, w: number, d: number)
		Build.part({
			name = "CourtLine",
			size = Vector3.new(w, 0.25, d),
			cframe = CFrame.new(centre + Vector3.new(cx, context.groundY + 0.2, cz)),
			color = Palette.color(Palette.court.line),
			material = Enum.Material.SmoothPlastic,
			castShadow = false,
			canCollide = false,
			parent = folder,
		})
	end
	local playW, playD = width - inset * 2, depth - inset * 2
	line(0, -playD * 0.5, playW, LINE)
	line(0, playD * 0.5, playW, LINE)
	line(-playW * 0.5, 0, LINE, playD)
	line(playW * 0.5, 0, LINE, playD)
	line(-playW * 0.5 + 7, 0, LINE, playD)
	line(playW * 0.5 - 7, 0, LINE, playD)
	line(0, -playD * 0.25, playW - 14, LINE)
	line(0, playD * 0.25, playW - 14, LINE)
	line(0, 0, LINE, playD * 0.5)

	--- The net, across the short axis, with a post at each end.
	local netAlongX = width >= depth
	local netLength = if netAlongX then width - inset else depth - inset
	Build.part({
		name = "Net",
		size = if netAlongX then Vector3.new(netLength, 5, 0.6) else Vector3.new(0.6, 5, netLength),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY + 2.5, 0)),
		color = Palette.color(Palette.court.net),
		material = Enum.Material.Fabric,
		transparency = 0.35,
		canCollide = false,
		parent = folder,
	})
	Build.part({
		name = "NetTape",
		size = if netAlongX then Vector3.new(netLength, 0.8, 0.8) else Vector3.new(0.8, 0.8, netLength),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY + 5.1, 0)),
		color = Palette.color(Palette.court.line),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = folder,
	})
	for _, side in { -1, 1 } do
		local at = if netAlongX
			then Vector3.new(side * netLength * 0.5, 0, 0)
			else Vector3.new(0, 0, side * netLength * 0.5)
		Build.part({
			name = "NetPost",
			size = Vector3.new(1.4, 6.5, 1.4),
			cframe = CFrame.new(centre + at + Vector3.new(0, context.groundY + 3.25, 0)),
			color = Palette.color(Palette.estate.iron),
			material = Enum.Material.Metal,
			parent = folder,
		})
	end

	--[[
		The surround: posts and mesh, open on the side the player walks in.

		Left open rather than gated, because a court is not a gated section —
		it is somewhere on the estate you walk onto. The mesh is a thin
		translucent panel between real posts, which is what chain-link reads
		as at any distance worth drawing it from.
	]]
	local FENCE_H = 20
	local halfW, halfD = width * 0.5 + 2.5, depth * 0.5 + 2.5
	local sides = {
		{ from = Vector3.new(-halfW, 0, -halfD), to = Vector3.new(halfW, 0, -halfD) },
		{ from = Vector3.new(-halfW, 0, halfD), to = Vector3.new(halfW, 0, halfD) },
		{ from = Vector3.new(-halfW, 0, -halfD), to = Vector3.new(-halfW, 0, halfD) },
	}
	for _, run in sides do
		local delta = run.to - run.from
		local length = delta.Magnitude
		local mid = centre + run.from + delta * 0.5
		local alongX = math.abs(delta.X) > math.abs(delta.Z)
		Build.part({
			name = "CourtMesh",
			size = if alongX then Vector3.new(length, FENCE_H, 0.4) else Vector3.new(0.4, FENCE_H, length),
			cframe = CFrame.new(mid + Vector3.new(0, context.groundY + FENCE_H * 0.5, 0)),
			color = Palette.color(Palette.court.mesh),
			material = Enum.Material.DiamondPlate,
			transparency = 0.55,
			parent = folder,
		})
		local posts = math.max(math.floor(length / 22), 1)
		for index = 0, posts do
			local at = centre + run.from + delta.Unit * (length * index / posts)
			Build.part({
				name = "CourtPost",
				size = Vector3.new(1.3, FENCE_H + 1, 1.3),
				cframe = CFrame.new(at + Vector3.new(0, context.groundY + (FENCE_H + 1) * 0.5, 0)),
				color = Palette.color(Palette.estate.iron),
				material = Enum.Material.Metal,
				parent = folder,
			})
		end
	end

	return folder
end

--[[
	A raised stone terrace, with a balustrade round it and steps off it.

	`Structures.room` walls a section in and roofs it. A terrace is the
	opposite: it is open to the sky and open to the view, and what makes it a
	place is that it stands above the lawn. The stairs the section builder
	adds for any raised section arrive at its edge, so the balustrade leaves
	the same gap the doorway of a room would.
]]
function Structures.terrace(context: Context, zone: Types.ZoneDef, opening: Opening?)
	local tile = context.tileSize
	local folder = Build.folder(`Terrace_{zone.id}`, context.parent)
	local r = zone.rect
	local centre = context.flat(r.x + r.w * 0.5, r.z + r.d * 0.5)
	local width, depth = r.w * tile, r.d * tile
	local lift = zone.elevation or 0

	--[[
		The deck, finishing exactly at the elevation the section is drawn at.

		Debris is placed on `GROUND_Y + elevation`, so a deck whose top face
		is even half a stud above that buries the whole section inside its own
		floor. `RoofDeck` gets this right by building down from the elevation
		rather than around it, and so does this.
	]]
	local DECK = 1.4
	local deckTop = context.groundY + lift
	Build.part({
		name = "TerraceMass",
		size = Vector3.new(width + 4, lift + 0.1, depth + 4),
		cframe = CFrame.new(
			centre + Vector3.new(0, (deckTop - DECK + context.groundY - 1.5) * 0.5, 0)
		),
		color = Palette.color(Palette.estate.stoneShade),
		material = Enum.Material.Sandstone,
		parent = folder,
	})
	Build.part({
		name = "TerraceDeck",
		size = Vector3.new(width + 4, DECK, depth + 4),
		cframe = CFrame.new(centre + Vector3.new(0, deckTop - DECK * 0.5, 0)),
		color = Palette.color(Palette.estate.stone),
		material = Enum.Material.Sandstone,
		parent = folder,
	})

	--- A balustrade all the way round, broken where the steps come up.
	Structures.parapet(context, zone, 1, opening)
	local halfW, halfD = (width + 4) * 0.5, (depth + 4) * 0.5
	local runs = {
		{ from = Vector3.new(-halfW, 0, -halfD), to = Vector3.new(halfW, 0, -halfD) },
		{ from = Vector3.new(-halfW, 0, halfD), to = Vector3.new(halfW, 0, halfD) },
		{ from = Vector3.new(-halfW, 0, -halfD), to = Vector3.new(-halfW, 0, halfD) },
		{ from = Vector3.new(halfW, 0, -halfD), to = Vector3.new(halfW, 0, halfD) },
	}
	for _, run in runs do
		local delta = run.to - run.from
		local length = delta.Magnitude
		local along = delta.Unit
		local count = math.max(math.floor(length / 6), 1)
		for index = 0, count do
			local at = centre + run.from + along * (length * index / count)
			-- The gap the stairs arrive through, left alone.
			local skip = false
			if opening then
				local toEdge = at - centre
				if toEdge:Dot(opening.normal) > 0 then
					local across = Vector3.new(-opening.normal.Z, 0, opening.normal.X)
					if math.abs(toEdge:Dot(across) - (opening.offset or 0)) < opening.width * 0.6 then
						skip = true
					end
				end
			end
			if not skip then
				Build.part({
					name = "Baluster",
					size = Vector3.new(1.5, 4.5, 1.5),
					cframe = CFrame.new(at + Vector3.new(0, context.groundY + lift + 2.6, 0)),
					color = Palette.color(Palette.estate.quoin),
					material = Enum.Material.Sandstone,
					parent = folder,
				})
			end
		end
		-- The rail along the top of them.
		local alongX = math.abs(delta.X) > math.abs(delta.Z)
		Build.part({
			name = "BalustradeRail",
			size = if alongX then Vector3.new(length, 1, 2.4) else Vector3.new(2.4, 1, length),
			cframe = CFrame.new(
				centre + run.from + delta * 0.5 + Vector3.new(0, context.groundY + lift + 5.2, 0)
			),
			color = Palette.color(Palette.estate.quoin),
			material = Enum.Material.Sandstone,
			canCollide = false,
			parent = folder,
		})
	end

	return folder
end

--[[
	A glasshouse: iron frame, glazed walls, a ridge lantern down the middle.

	The Orangery was a `room` — the same four opaque walls and flat ceiling
	the garage and the cellars are built from, in the same stone. An orangery
	is the one building on an estate you can see through, and that is the
	entire point of it: the section is lit, the debris inside is visible from
	the lawn, and it looks like nothing else on either property.
]]
function Structures.glasshouse(context: Context, zone: Types.ZoneDef, opening: Opening?)
	local tile = context.tileSize
	local folder = Build.folder(`Glasshouse_{zone.id}`, context.parent)
	local r = zone.rect
	local centre = context.flat(r.x + r.w * 0.5, r.z + r.d * 0.5)
	local width, depth = r.w * tile, r.d * tile
	local HEIGHT = 26

	Build.part({
		name = "Floor",
		size = Vector3.new(width + 4, 2, depth + 4),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY - 1, 0)),
		color = Palette.color(Palette.ground.stoneDark),
		material = Enum.Material.Slate,
		parent = folder,
	})

	--- A low stone dwarf wall, which is what a glasshouse stands on.
	Structures.wallRing({
		name = "DwarfWall",
		centre = centre + Vector3.new(0, context.groundY, 0),
		width = width + 4,
		depth = depth + 4,
		height = 5,
		thickness = 2,
		color = Palette.color(Palette.estate.stone),
		material = Enum.Material.Sandstone,
		parent = folder,
		opening = opening,
	})
	--- The glazing above it, in one translucent ring.
	Structures.wallRing({
		name = "Glazing",
		centre = centre + Vector3.new(0, context.groundY + 5, 0),
		width = width + 4,
		depth = depth + 4,
		height = HEIGHT - 5,
		thickness = 0.8,
		color = Palette.color(Palette.estate.glass),
		material = Enum.Material.Glass,
		transparency = 0.62,
		parent = folder,
		opening = opening,
	})

	--- The iron mullions between the panes, which is what stops the glazing
	--- reading as a sheet of coloured air.
	local halfW, halfD = (width + 4) * 0.5, (depth + 4) * 0.5
	for _, run in {
		{ from = Vector3.new(-halfW, 0, -halfD), to = Vector3.new(halfW, 0, -halfD) },
		{ from = Vector3.new(-halfW, 0, halfD), to = Vector3.new(halfW, 0, halfD) },
		{ from = Vector3.new(-halfW, 0, -halfD), to = Vector3.new(-halfW, 0, halfD) },
		{ from = Vector3.new(halfW, 0, -halfD), to = Vector3.new(halfW, 0, halfD) },
	} do
		local delta = run.to - run.from
		local length = delta.Magnitude
		local along = delta.Unit
		local count = math.max(math.floor(length / 9), 1)
		for index = 0, count do
			local at = centre + run.from + along * (length * index / count)
			Build.part({
				name = "Mullion",
				size = Vector3.new(1, HEIGHT - 5, 1),
				cframe = CFrame.new(at + Vector3.new(0, context.groundY + 5 + (HEIGHT - 5) * 0.5, 0)),
				color = Palette.color(Palette.estate.iron),
				material = Enum.Material.Metal,
				canCollide = false,
				parent = folder,
			})
		end
	end

	--- Eaves, and the lantern along the ridge.
	Build.part({
		name = "Eaves",
		size = Vector3.new(width + 8, 1.6, depth + 8),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY + HEIGHT, 0)),
		color = Palette.color(Palette.estate.iron),
		material = Enum.Material.Metal,
		parent = folder,
	})
	Build.part({
		name = "Glasshouse",
		size = Vector3.new(width, 1, depth),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY + HEIGHT + 1.3, 0)),
		color = Palette.color(Palette.estate.glass),
		material = Enum.Material.SmoothPlastic,
		transparency = 0.72,
		parent = folder,
	})
	local ridgeAlongX = width >= depth
	Build.part({
		name = "Lantern",
		size = if ridgeAlongX then Vector3.new(width * 0.55, 6, 14) else Vector3.new(14, 6, depth * 0.55),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY + HEIGHT + 4.3, 0)),
		color = Palette.color(Palette.estate.glass),
		material = Enum.Material.SmoothPlastic,
		transparency = 0.62,
		parent = folder,
	})
	Build.part({
		name = "LanternCap",
		size = if ridgeAlongX then Vector3.new(width * 0.58, 1.2, 16) else Vector3.new(16, 1.2, depth * 0.58),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY + HEIGHT + 7.5, 0)),
		color = Palette.color(Palette.estate.iron),
		material = Enum.Material.Metal,
		parent = folder,
	})

	return folder
end

return Structures
