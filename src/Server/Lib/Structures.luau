--!strict
--[[
	Structures — the built parts of a detailed residential property.

	Rooms, the pool, the hedge maze, the porch stairs onto the roof, the
	stairwell down to the cellar, and the clutter that debris hides against.

	That last one is not decoration. A completion bar over an empty field makes
	the final few percent a tedious sweep; the same bar over a yard full of bins,
	planters and patio furniture makes it a hunt. Clutter is the mechanic.
]]

local TweenService = game:GetService("TweenService")

local Palette = require(game:GetService("ReplicatedStorage").Shared.Config.Palette)
local Types = require(game:GetService("ReplicatedStorage").Shared.Types)
local Worlds = require(game:GetService("ReplicatedStorage").Shared.Config.Worlds)
local Build = require(script.Parent.Build)

local Structures = {}

--[[
	How far a built floor stands above the ground it is laid on.

	Small enough to be invisible and to leave the debris resting on it looking
	as though it is resting on it, large enough to win the depth test against
	the lawn slab underneath — which tops out at exactly `GROUND_Y`, the same
	height a room's floor was being built at.
]]
local FLOOR_LIFT = 0.06

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
	--- Glazing throws no shadow; a wall does.
	castShadow: boolean?,
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

--[[
	What is lying about, per property.

	Every yard on every property was scattered from the one list above: a
	wheelie bin, a plastic garden chair, a terracotta planter, a packing
	crate, an oil drum, a shrub and a stone. That is a suburban back garden's
	contents, and it was being strewn across an estate's parterres and a
	filling station's back lot alike — a garden chair on the forecourt, a
	planter in the storage yard, a wheelie bin on the lawn of a house with a
	carriage drive.

	The scatter, the caps and the placement are all unchanged. Only the
	contents differ, which is the whole of what makes a lot look like a lot.
]]
local ESTATE_PROPS: { PropSpec } = {
	{ prop = "Planter", size = Vector3.new(5, 4.5, 5) },
	{ prop = "Bush", size = Vector3.new(6, 6, 6) },
	{ prop = "Rock", size = Vector3.new(4, 3, 4) },
	{ prop = "Lantern", size = Vector3.new(3.4, 7, 3) },
	{ prop = "Log", size = Vector3.new(6, 3, 3) },
}

local LOT_PROPS: { PropSpec } = {
	{ prop = "Barrel", size = Vector3.new(4, 5.5, 4) },
	{ prop = "Crate", size = Vector3.new(5, 3.4, 4.5) },
	{ prop = "Bin", size = Vector3.new(4, 6.5, 4) },
	{ prop = "Sack", size = Vector3.new(4, 4, 4) },
	{ prop = "Rock", size = Vector3.new(4, 3, 4) },
}

--[[
	A churchyard's yard set.

	Stone, fallen wood and the odd urn — the things that accumulate in a
	place nobody has tidied — plus lanterns, which are the only reason you can
	see anything after dark.
]]
local CHURCHYARD_PROPS: { PropSpec } = {
	{ prop = "Rock", size = Vector3.new(4, 3, 4) },
	{ prop = "Log", size = Vector3.new(6, 3, 3) },
	{ prop = "Planter", size = Vector3.new(5, 4.5, 5) },
	{ prop = "Lantern", size = Vector3.new(3.4, 7, 3) },
	{ prop = "Bush", size = Vector3.new(6, 6, 6) },
}

--- The yard set for a property's style, falling back to the house's.
Structures.clutterSets = {
	house = YARD_PROPS,
	estate = ESTATE_PROPS,
	lot = LOT_PROPS,
	churchyard = CHURCHYARD_PROPS,
}

local ROOM_PROPS: { PropSpec } = {
	{ prop = "Crate", size = Vector3.new(5, 3.4, 4.5) },
	{ prop = "Barrel", size = Vector3.new(4, 6, 4) },
	{ prop = "Bin", size = Vector3.new(4, 6, 4) },
	{ prop = "Rock", size = Vector3.new(4, 3, 4) },
}

--[[
	And what is lying about inside one, per property.

	Crates, drums and a wheeled bin are the four things in any room anywhere,
	which is right for a garage, a wash bay and a workshop and wrong for the
	undercroft of a chapel: a blue plastic wheelie bin standing among the
	loculi is most of what made the crypt read as somebody's basement. Fallen
	masonry, a rotten beam and a lantern are what is down there instead.
]]
local CRYPT_PROPS: { PropSpec } = {
	{ prop = "Rock", size = Vector3.new(4, 3, 4) },
	{ prop = "Log", size = Vector3.new(6, 3, 3) },
	{ prop = "Lantern", size = Vector3.new(3.4, 7, 3) },
}

--[[
	And what is lying about under a country house.

	The same fault one property along: the cellars of an estate came out with
	a blue plastic wheelie bin standing in them, next to a wall of leather
	books and a fire somebody had lit. Whatever else is down there, it is not
	the bins. Crates and casks and a sack of something, and a lantern to find
	them by.
]]
local CELLAR_PROPS: { PropSpec } = {
	{ prop = "Crate", size = Vector3.new(5, 3.4, 4.5) },
	{ prop = "Barrel", size = Vector3.new(4, 6, 4) },
	{ prop = "Sack", size = Vector3.new(4, 2.6, 3) },
	{ prop = "Lantern", size = Vector3.new(3.4, 7, 3) },
}

--- The indoor set for a property's style, falling back to the common one.
Structures.roomSets = {
	churchyard = CRYPT_PROPS,
	estate = CELLAR_PROPS,
}

--[[
	And what is lying about on a roof.

	A rooftop drew from the yard set, which has bushes, rocks and logs in it,
	so The House's roof deck had a shrub growing out of it and a boulder
	sitting next to it — twenty-nine studs up, on slate. Nothing that needs
	soil, and nothing anybody would have carried up there for no reason: what
	is on a flat roof is the things somebody left after working on it.
]]
local ROOF_PROPS: { PropSpec } = {
	{ prop = "Crate", size = Vector3.new(5, 3.4, 4.5) },
	{ prop = "Barrel", size = Vector3.new(4, 5.5, 4) },
	{ prop = "Bin", size = Vector3.new(4, 6.5, 4) },
	{ prop = "Sack", size = Vector3.new(4, 2.6, 3) },
	{ prop = "Planter", size = Vector3.new(5, 4.5, 5) },
}

--[[
	Scatters props across a zone.

	Props sit on the zone's own floor and do not collide, so they never wall a
	player off from a tile they still have to clear — they only make it harder
	to spot, which is the whole point.
]]
function Structures.clutter(
	context: Context,
	zone: Types.ZoneDef,
	count: number,
	yard: { PropSpec }?,
	room: { PropSpec }?
)
	if count <= 0 then
		return
	end

	local elevation = zone.elevation or 0
	-- A room's four things are crates and drums whatever the property is;
	-- what is scattered outdoors is where a lot shows its character.
	local kind = zone.kind or "open"
	local set = if kind == "room"
		then (room or ROOM_PROPS)
		elseif kind == "roof" then ROOF_PROPS
		else (yard or YARD_PROPS)
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
	local YARD_CAP: { [string]: number } =
		{ Bin = 1, Crate = 1, Barrel = 1, Chair = 1, Sack = 2, Lantern = 2, Log = 2, Planter = 2, Bush = 3, Rock = 3 }

	--[[
		How often a room may repeat a prop, which is a question about its size.

		The rule above was one of each, on the stated grounds that "rooms are
		small and hold four things well". That is true of a cellar and false of
		the Gas Station's workshop, which is seventy-two tiles by thirty-four —
		four times the floor of the crypt and the largest room in the game. Four
		objects in it is nothing, and "there is nothing there" is exactly how it
		was reported.

		So the ceiling follows the floor instead of assuming it. One repeat per
		ten thousand square studs: a cellar stays at one of each and reads as it
		always did, and the workshop is allowed four, which is the difference
		between a hall with a crate in it and a hall somebody works in.
	]]
	local roomArea = r.w * context.tileSize * r.d * context.tileSize
	local roomCap = math.clamp(math.ceil(roomArea / 10000), 1, 5)

	local pool: { PropSpec } = table.clone(set)
	local placed: { [string]: number } = {}
	--[[
		One thing per tile.

		The tile was picked at random twenty times looking only for somewhere
		that was not water and not paving, so two props could and did land on
		the same square: a churchyard bush standing inside another churchyard
		bush, which is one bush with a shading fault rather than two of
		anything. Remembering what has been used costs a table.
	]]
	local taken: { [string]: boolean } = {}
	for _ = 1, count do
		if #pool == 0 then
			break
		end
		local spec = pool[context.rng:NextInteger(1, #pool)]
		placed[spec.prop] = (placed[spec.prop] or 0) + 1
		local cap = if walled then roomCap else (YARD_CAP[spec.prop] or 1)
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
			if
				not onWater
				and not taken[`{tx},{tz}`]
				and not Worlds.onPaving(context.world, flat.X, flat.Z, 1)
			then
				break
			end
		end
		taken[`{tx},{tz}`] = true
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

	--[[
		The ends butt into the sides; they do not run through them.

		Every side ran its full span, so at each of the four corners two walls
		occupied the same block of space with their top faces on exactly the
		same plane — and two faces on one plane is the depth test guessing,
		which is a corner that flickers as you walk past it. Four rooms, two
		pools, a glasshouse and every parapet in the game are built from this,
		so it flickered on all of them.

		The two ends keep their full span, because a corner has to be solid;
		the two sides stop half a thickness short at each end, which is
		exactly where the ends' inner faces are. Nothing opens up and nothing
		overlaps.
	]]
	local shortened = options.depth - options.thickness
	local sides: { RingSide } = {
		{ normal = Vector3.new(0, 0, -1), offset = Vector3.new(0, 0, -halfDepth), span = options.width, alongX = true },
		{ normal = Vector3.new(0, 0, 1), offset = Vector3.new(0, 0, halfDepth), span = options.width, alongX = true },
		{ normal = Vector3.new(-1, 0, 0), offset = Vector3.new(-halfWidth, 0, 0), span = shortened, alongX = false },
		{ normal = Vector3.new(1, 0, 0), offset = Vector3.new(halfWidth, 0, 0), span = shortened, alongX = false },
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
					castShadow = options.castShadow,
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
--- `colour` defaults to The House's trim, which is what a rooftop parapet on
--- that house is. Anywhere else it has to be told, or it arrives in teal.
function Structures.parapet(
	context: Context,
	zone: Types.ZoneDef,
	height: number,
	opening: Opening?,
	colour: Color3?
)
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
		color = colour or Palette.color(Palette.house.trim),
		material = Enum.Material.Slate,
		parent = context.parent,
		opening = opening,
	})
end

--[[
	What a room is built out of, which is not the same on every property.

	Every room in the game was a House room: cream lap siding above ground,
	dark red brick below, and a brown shingle roof. That is the first
	property's palette and it was hardcoded here, so the Mansion's cellars
	came out as the same red-brick pit as The House's basement — on the
	property whose entire complaint was that it looked like the first one —
	and the filling station's wash bay was built out of house siding on a
	forecourt done in cream and red.

	The builder is shared; the colours no longer are.
]]
export type RoomSkin = {
	wall: Color3,
	wallSunken: Color3,
	roof: Color3,
	--- The band round the eaves, where a property has one. Defaults to the
	--- roof's own colour, which is what a house wants: the stripe is a filling
	--- station's idea, and a whole roof painted in it is a red slab.
	fascia: Color3?,
	floor: Color3?,
	--[[
		What the room is, when it is something in particular.

		The skin says what a room is *made of*, and for a wash bay or a garage
		that is the whole answer. A chapel is not: four granite walls and a
		lid is a warehouse whatever colour it is painted, and the section is
		called The Chapel. Set, the builder puts an altar, its candles, the
		windows and a few pews in — the same way a sunken room gets its
		shelves and its fireplace.
	]]
	fitting: ("chapel" | "washbay" | "garage")?,
	--[[
		And what a *sunken* room of this property is.

		The one below a house is a cellar and gets shelves and a fire, which is
		what was asked for and what the crypt under the churchyard keeps. The
		one below a filling station is its workshop, and a workshop full of
		hardback books with a hearth burning in the corner is not a workshop —
		it is the cellar furniture arriving somewhere it was never meant to go,
		which is the same fault the room skins and the exit masonry had.
	]]
	underground: ("cellar" | "workshop" | "crypt")?,
}

--[[
	A stack of tyres, stood at the foot frame's origin.

	Both the workshop and the garage want one and both had built their own:
	nine studs across and butted a tenth of a stud apart, four of them read
	as a single black drum eleven studs tall with no seam anywhere on it to
	say what it was. A tyre is smaller than a person and a stack of them is
	a stack — narrower, a real gap between each so the shadow lines show,
	two shades of rubber so the bands separate, and each sitting a little
	off the one below the way nobody ever stacks them straight.

	A cylinder has no hole in it, so the top one gets a wheel dropped into
	it: something that is not rubber, standing a fifth of a stud proud of
	the tread, which is what gives the black column a centre to look at.
]]
local TYRE_OFFSET = { 0, 0.5, -0.35, 0.25 }

local function tyreStack(foot: CFrame, parent: Instance)
	local top = 0
	for tyre = 0, 3 do
		top = 1.05 + tyre * 2.1
		Build.part({
			name = "TyreStack",
			shape = Enum.PartType.Cylinder,
			size = Vector3.new(1.8, 6.2, 6.2),
			cframe = foot
				* CFrame.new(
					TYRE_OFFSET[tyre + 1],
					top,
					TYRE_OFFSET[(tyre + 2) % 4 + 1]
				)
				* CFrame.Angles(0, 0, math.rad(90)),
			color = if tyre % 2 == 0
				then Color3.fromRGB(34, 34, 38)
				else Color3.fromRGB(46, 46, 51),
			material = Enum.Material.Rubber,
			parent = parent,
		})
	end
	Build.part({
		name = "TyreHub",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(1.1, 3.4, 3.4),
		cframe = foot
			* CFrame.new(TYRE_OFFSET[4], top + 0.55, TYRE_OFFSET[2])
			* CFrame.Angles(0, 0, math.rad(90)),
		color = Color3.fromRGB(150, 154, 160),
		material = Enum.Material.Metal,
		canCollide = false,
		parent = parent,
	})
end

--[[
	An urn on a plinth, stood at the foot frame's origin.

	Both the crypt and the drive up to The Mansion wanted one, and both had
	built the same thing: a ball on a box. A sphere balanced on a plain post
	is a cannonball on a pedestal — no foot, no rim, nothing to say which way
	up it is, and on the drive the ball was wider than the plinth holding it
	up.

	Five parts, all proportional to the plinth so one builder does a
	four-stud garden urn and a three-stud cinerary one: a base and a cap on
	the pedestal, because a pedestal with no mouldings is a post; then the
	foot it stands on, the belly, and the lip round the top.
]]
export type UrnSpec = {
	foot: CFrame,
	--- Across the pedestal. Everything else is a fraction of it.
	plinth: number,
	--- Pedestal, mouldings and lip.
	body: Color3,
	bodyMaterial: Enum.Material,
	--- Foot and belly, so the vessel reads as a different stone.
	stone: Color3,
	stoneMaterial: Enum.Material,
	parent: Instance,
}

function Structures.urn(spec: UrnSpec)
	local p = spec.plinth
	local tall = p * 1.5
	Build.part({
		name = "UrnPlinth",
		size = Vector3.new(p, tall, p),
		cframe = spec.foot * CFrame.new(0, tall * 0.5, 0),
		color = spec.body,
		material = spec.bodyMaterial,
		parent = spec.parent,
	})
	for _, y in { p * 0.11, tall - p * 0.1 } do
		Build.part({
			name = "UrnMoulding",
			size = Vector3.new(p * 1.15, p * 0.22, p * 1.15),
			cframe = spec.foot * CFrame.new(0, y, 0),
			color = spec.body,
			material = spec.bodyMaterial,
			parent = spec.parent,
		})
	end
	Build.part({
		name = "UrnFoot",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(p * 0.42, p * 0.4, p * 0.4),
		cframe = spec.foot
			* CFrame.new(0, tall + p * 0.12, 0)
			* CFrame.Angles(0, 0, math.rad(90)),
		color = spec.stone,
		material = spec.stoneMaterial,
		parent = spec.parent,
	})
	Build.part({
		name = "Urn",
		shape = Enum.PartType.Ball,
		size = Vector3.new(p * 0.85, p * 0.85, p * 0.85),
		cframe = spec.foot * CFrame.new(0, tall + p * 0.65, 0),
		color = spec.stone,
		material = spec.stoneMaterial,
		parent = spec.parent,
	})
	Build.part({
		name = "UrnLip",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(p * 0.2, p * 0.75, p * 0.75),
		cframe = spec.foot
			* CFrame.new(0, tall + p * 1.03, 0)
			* CFrame.Angles(0, 0, math.rad(90)),
		color = spec.body,
		material = spec.bodyMaterial,
		parent = spec.parent,
	})
end

function Structures.room(
	context: Context,
	zone: Types.ZoneDef,
	wallHeight: number,
	sunken: boolean,
	opening: Opening?,
	skin: RoomSkin?
)
	local dressing: RoomSkin = skin
		or {
			wall = Palette.color(Palette.house.siding),
			wallSunken = Palette.color(Palette.house.brickDark),
			roof = Palette.color(Palette.house.roof),
		}
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
		--[[
			A shade proud of the ground, not flush with it.

			The lawn slab's own top face is at `GROUND_Y`, and a room built at
			ground level put its floor there too — two surfaces at exactly the
			same height across the whole of a room, which flicker against each
			other and show through one another in patches. Photographed in the
			Orangery: a floor that was dark soil in one place, grass in
			another, and changed as the player walked. A sunken room is far
			enough below to be safe, but it costs nothing to lift both.
		]]
		cframe = CFrame.new(centre - Vector3.new(0, 1 - lift - FLOOR_LIFT, 0)),
		color = dressing.floor or Palette.color(Palette.ground.stoneDark),
		material = Enum.Material.Concrete,
		parent = folder,
	})

	--[[
		A sunken room's walls reach the lawn, not sixteen studs of the way.

		The height passed in is a room's height, and a cellar's is however
		deep it is dug — with a fixed sixteen against an eighteen stud drop
		the wall stopped two studs short of the surface and left a slot all
		the way round, daylight and a view of the grass coming in over the top
		of every wall. Once there is a ceiling on it that slot is the one
		thing saying "pit" rather than "room".
	]]
	--[[
		A shade under the lawn, not flush with it.

		Reaching exactly ground level put the top face of every sunken wall
		and pier on the same plane as the lawn around it, which is two
		surfaces at the same height flickering against each other — the
		downward sweep found it on eight of the sampled points along the
		crypt. Three tenths of a stud lower is still under the ground slab,
		which runs four studs deep, so nothing opens up; it just stops the
		two faces fighting.
	]]
	local rise = if sunken then math.abs(elevation) - 0.3 else wallHeight
	local wallColor = if sunken then dressing.wallSunken else dressing.wall
	Structures.wallRing({
		name = "Wall",
		centre = centre,
		width = width,
		depth = depth,
		height = rise,
		thickness = 1.5,
		color = wallColor,
		material = Enum.Material.Concrete,
		parent = folder,
		opening = opening,
	})

	--[[
		A cellar has a ceiling, and a hole in it where the stairs come down.

		This was left open at the top on the reasoning that you have to see
		the floor to know what is still on it. What that produced was a
		rectangle of brick with a tan floor at the bottom — a pit, reported as
		"it just looks like a hole in the ground" — and the thing that makes a
		cellar a cellar is precisely that it is under something.

		So it gets a real ceiling with a stairwell cut in it, which is how you
		see in and how the daylight gets down. Four slabs around the opening
		rather than one with a hole, because a part cannot have a hole in it.

		Piers down the walls at intervals, because that is how anything
		holding a house up is built and it stops fifty studs of brick reading
		as a sheet. And lamps in a grid under the ceiling, because a roofed
		cellar is dark and because a cellar is somewhere that was wired.

		None of it touches the floor or the tiles on it: the ceiling is named
		`Ceiling`, which the buried-tile sweep already knows never buries
		anything, and everything else sits at the top of a sixteen stud wall.
	]]
	if sunken then
		--[[
			Where the stairs come through, in the room's own axes.

			The flight lands `STAIRWELL_RUN` studs in from the wall it comes
			through; the ceiling stops short of that so the whole flight is
			under open sky rather than emerging from beneath a lid.
		]]
		local STAIRWELL_RUN = 38
		local half = math.max(math.min((opening and opening.width or 0), math.huge), 0) * 0.5
		local alongX = opening ~= nil and math.abs(opening.normal.Z) > 0.5
		local at = if opening then (opening.offset or 0) else 0
		local wellLowX, wellHighX, wellLowZ, wellHighZ
		if not opening then
			wellLowX, wellHighX, wellLowZ, wellHighZ = 0, 0, 0, 0
		elseif alongX then
			local far = opening.normal.Z > 0
			wellLowX, wellHighX = at - half, at + half
			wellLowZ = if far then depth * 0.5 - STAIRWELL_RUN else -depth * 0.5
			wellHighZ = if far then depth * 0.5 else -depth * 0.5 + STAIRWELL_RUN
		else
			local far = opening.normal.X > 0
			wellLowZ, wellHighZ = at - half, at + half
			wellLowX = if far then width * 0.5 - STAIRWELL_RUN else -width * 0.5
			wellHighX = if far then width * 0.5 else -width * 0.5 + STAIRWELL_RUN
		end

		--[[
			Tucked just under the lawn, and wider than the room.

			The hole cut in the ground is the section's rect and the walls
			stand on the tile centres inside it, so the two are a couple of
			studs out of step — a ceiling sized to the walls left a strip of
			open sky along one edge, which from the floor is a green line
			round the top of the room. Four studs of overhang on every side
			puts the edge of the slab under solid ground instead of trying to
			meet it, and a fifth of a stud of clearance under the surface
			keeps the two from flickering against each other.

			It is also as thick as the ground is deep. A thin slab left the
			cut face of the lawn — four studs of it, and grass-green — on show
			all the way round the room above the ceiling line, which is the
			green stripe that kept coming back. The ceiling now fills that
			depth, so what you see where the wall ends is the ceiling and not
			the underside of the garden.
		]]
		local CEILING_DEEP = 4.6
		local ceilingY = rise - 2.5
		local function slab(lowX: number, highX: number, lowZ: number, highZ: number)
			if highX - lowX < 0.5 or highZ - lowZ < 0.5 then
				return
			end
			Build.part({
				name = "Ceiling",
				size = Vector3.new(highX - lowX, CEILING_DEEP, highZ - lowZ),
				cframe = CFrame.new(
					centre + Vector3.new((lowX + highX) * 0.5, ceilingY, (lowZ + highZ) * 0.5)
				),
				color = dressing.roof,
				material = Enum.Material.Concrete,
				parent = folder,
			})
		end

		local halfW, halfD = width * 0.5 + 4, depth * 0.5 + 4
		if not opening then
			slab(-halfW, halfW, -halfD, halfD)
		else
			-- The four pieces around the stairwell.
			slab(-halfW, halfW, -halfD, wellLowZ)
			slab(-halfW, halfW, wellHighZ, halfD)
			slab(-halfW, wellLowX, wellLowZ, wellHighZ)
			slab(wellHighX, halfW, wellLowZ, wellHighZ)
		end

		--- Piers, spaced along whichever way the wall runs. They stop a third
		--- of a stud short of the wall head so the two top faces are not on
		--- the same plane, which flickered where a pier met its wall.
		local PIER = 22
		local pierRise = rise - 0.35
		for _, side in {
			{ along = "x", span = width, at = Vector3.new(0, 0, -depth * 0.5), size = Vector3.new(4, pierRise, 2.4) },
			{ along = "x", span = width, at = Vector3.new(0, 0, depth * 0.5), size = Vector3.new(4, pierRise, 2.4) },
			{ along = "z", span = depth, at = Vector3.new(-width * 0.5, 0, 0), size = Vector3.new(2.4, pierRise, 4) },
			{ along = "z", span = depth, at = Vector3.new(width * 0.5, 0, 0), size = Vector3.new(2.4, pierRise, 4) },
		} do
			local count = math.max(math.floor(side.span / PIER), 1)
			for index = 1, count - 1 do
				local slide = -side.span * 0.5 + side.span * (index / count)
				local offset = if side.along == "x"
					then Vector3.new(slide, 0, 0)
					else Vector3.new(0, 0, slide)
				Build.part({
					name = "Pier",
					size = side.size,
					cframe = CFrame.new(centre + side.at + offset + Vector3.new(0, pierRise * 0.5, 0)),
					color = dressing.wall,
					material = Enum.Material.Concrete,
					canCollide = false,
					parent = folder,
				})
			end
		end

		--[[
			What is down here besides the leaves.

			A cellar with nothing in it is a room, not a cellar. The two walls
			the stairs and the way out do not use get the furniture: shelves
			of books down one, and a fireplace on the other with something
			actually burning in it, which is the only warm light in the game
			that is not the sun.

			Solid, so the buried-tile sweep takes the strip of floor they
			stand on out of the section's total — you cannot mow inside a
			bookcase and the property should not count it.
		]]
		local alongZWalls = opening ~= nil and math.abs(opening.normal.Z) > 0.5
		--- The two walls nothing else is using, and which way they face.
		local freeWalls = if alongZWalls
			then {
				{ at = Vector3.new(-width * 0.5, 0, 0), facing = Vector3.new(1, 0, 0), span = depth },
				{ at = Vector3.new(width * 0.5, 0, 0), facing = Vector3.new(-1, 0, 0), span = depth },
			}
			else {
				{ at = Vector3.new(0, 0, -depth * 0.5), facing = Vector3.new(0, 0, 1), span = width },
				{ at = Vector3.new(0, 0, depth * 0.5), facing = Vector3.new(0, 0, -1), span = width },
			}

		local BOOK_COLOURS = {
			Color3.fromRGB(142, 46, 40),
			Color3.fromRGB(46, 78, 118),
			Color3.fromRGB(96, 84, 46),
			Color3.fromRGB(58, 92, 62),
			Color3.fromRGB(120, 74, 38),
		}
		local timber = Color3.fromRGB(74, 50, 34)

		--- One bookcase, stood against a wall and facing into the room.
		local function bookcase(base: CFrame)
			Build.part({
				name = "BookcaseBack",
				size = Vector3.new(14, 13, 1),
				cframe = base * CFrame.new(0, 6.5, 0),
				color = timber,
				material = Enum.Material.WoodPlanks,
				parent = folder,
			})
			for _, side in { -1, 1 } do
				Build.part({
					name = "BookcaseSide",
					size = Vector3.new(1, 13, 3.4),
					cframe = base * CFrame.new(side * 6.5, 6.5, -1.7),
					color = timber,
					material = Enum.Material.WoodPlanks,
					parent = folder,
				})
			end
			for shelf = 0, 3 do
				local y = 1 + shelf * 3.7
				Build.part({
					name = "Shelf",
					size = Vector3.new(14, 0.7, 3.4),
					cframe = base * CFrame.new(0, y, -1.7),
					color = timber,
					material = Enum.Material.WoodPlanks,
					parent = folder,
				})
				if shelf < 3 then
					--- Books, in runs of a colour, leaning where they thin out.
					for slot = 0, 8 do
						if (slot + shelf) % 4 ~= 3 then
							Build.part({
								name = "Books",
								size = Vector3.new(1.2, 2.4, 2.2),
								cframe = base
									* CFrame.new(-6 + slot * 1.5, y + 1.55, -1.7)
									* CFrame.Angles(0, 0, if (slot + shelf) % 7 == 2 then math.rad(11) else 0),
								color = BOOK_COLOURS[(slot + shelf * 3) % #BOOK_COLOURS + 1],
								material = Enum.Material.SmoothPlastic,
								canCollide = false,
								parent = folder,
							})
						end
					end
				end
			end
		end

		--- The fireplace, with a fire in it.
		local function fireplace(base: CFrame)
			local stone = dressing.wall
			Build.part({
				name = "Chimneybreast",
				size = Vector3.new(20, rise, 3),
				cframe = base * CFrame.new(0, rise * 0.5, -1.5),
				color = stone,
				material = Enum.Material.Brick,
				parent = folder,
			})
			-- The opening: black, with the fire sitting inside it.
			Build.part({
				name = "Firebox",
				size = Vector3.new(11, 8, 2.6),
				cframe = base * CFrame.new(0, 4.4, -2.6),
				color = Color3.fromRGB(12, 10, 10),
				material = Enum.Material.SmoothPlastic,
				parent = folder,
			})
			Build.part({
				name = "Hearth",
				size = Vector3.new(16, 0.8, 5),
				cframe = base * CFrame.new(0, 0.4, -3.4),
				color = Palette.color(Palette.ground.stone),
				material = Enum.Material.Slate,
				parent = folder,
			})
			Build.part({
				name = "Mantel",
				size = Vector3.new(19, 1.4, 4.4),
				cframe = base * CFrame.new(0, 9.4, -3),
				color = Palette.color(Palette.ground.stone),
				material = Enum.Material.Slate,
				parent = folder,
			})
			for log = -1, 1 do
				Build.part({
					name = "Firelog",
					size = Vector3.new(1.8, 1.8, 3.6),
					cframe = base * CFrame.new(log * 2.4, 1.5, -3) * CFrame.Angles(0, math.rad(log * 14), 0),
					color = Color3.fromRGB(58, 38, 26),
					material = Enum.Material.Wood,
					canCollide = false,
					parent = folder,
				})
			end
			local fire = Build.part({
				name = "Fire",
				size = Vector3.new(7, 3.4, 2.6),
				cframe = base * CFrame.new(0, 2.4, -3),
				color = Color3.fromRGB(255, 156, 52),
				material = Enum.Material.Neon,
				canCollide = false,
				parent = folder,
			})
			local glow = Instance.new("PointLight")
			glow.Color = Color3.fromRGB(255, 168, 82)
			glow.Range = 42
			glow.Brightness = 2.4
			glow.Parent = fire
		end

		--[[
			Shelves down one free wall, the fireplace centred on the other.

			Placed with `lookAt` rather than a yaw worked out by hand: both
			pieces are built along their own -Z, and the first attempt turned
			them by `atan2(facing.X, facing.Z)`, which is the angle that points
			them the other way — every bookcase stood with its shelves through
			the brick and the chimneybreast ended up two studs outside the
			room. `lookAt(at, at + facing)` cannot be got backwards.
		]]
		local shelfWall, fireWall = freeWalls[1], freeWalls[2]
		if dressing.underground == "crypt" then
			--[[
				A crypt is not a cellar with the lights on.

				It had the shelves and the fire, because that is what the room
				under a house gets and there was only one kind of room under
				anything. Reported, correctly, as looking like a basement: a
				library with a hearth in it is somebody's house, and this is
				the undercroft of a chapel with the parish's dead in it.

				So one wall is loculi — the stacked niches a crypt actually
				stores coffins in, some sealed with a pale slab and some
				standing open onto the same near-black the mausoleums use —
				and the other has a chest tomb against it with urns either
				side. Nothing burns down here.
			]]
			--- The same spacing the shelves used, because it is the same wall:
			--- one bay every thirty-four studs puts two along the crypt's
			--- seventy-two rather than one lost in the middle of it.
			local bays = math.max(math.floor(shelfWall.span / 34), 1)
			for index = 1, bays do
				local slide = -shelfWall.span * 0.5 + shelfWall.span * (index / (bays + 1))
				local offset = if alongZWalls then Vector3.new(0, 0, slide) else Vector3.new(slide, 0, 0)
				local at = centre + shelfWall.at + offset
				local base = CFrame.lookAt(at, at + shelfWall.facing)
				local BAY_W, BAY_H = 28, 12
				Build.part({
					name = "NicheVoid",
					size = Vector3.new(BAY_W, BAY_H, 2.4),
					cframe = base * CFrame.new(0, 1.4 + BAY_H * 0.5, -1),
					color = Color3.fromRGB(11, 10, 12),
					material = Enum.Material.SmoothPlastic,
					parent = folder,
				})
				--- The stonework that divides the recess into nine mouths.
				for column = -1, 1 do
					Build.part({
						name = "NicheMullion",
						size = Vector3.new(1.6, BAY_H, 2.8),
						cframe = base * CFrame.new(column * BAY_W / 3, 1.4 + BAY_H * 0.5, -1.1),
						color = dressing.wall,
						material = Enum.Material.Rock,
						parent = folder,
					})
				end
				for course = 0, 3 do
					Build.part({
						name = "NicheCourse",
						size = Vector3.new(BAY_W + 2, 1.4, 2.8),
						cframe = base * CFrame.new(0, 1.4 + course * (BAY_H / 3), -1.1),
						color = dressing.wall,
						material = Enum.Material.Rock,
						parent = folder,
					})
				end
				--- Some of them sealed, some of them not.
				local sealed = { { -1, 0 }, { 0, 2 }, { 1, 1 }, { -1, 2 } }
				for _, cell in sealed do
					Build.part({
						name = "NicheSlab",
						size = Vector3.new(BAY_W / 3 - 2.2, BAY_H / 3 - 1.8, 0.6),
						-- Set two tenths behind the front of the stonework, so
						-- a sealed mouth reads as filled rather than as a slab
						-- stuck on the wall — and so the two faces are not on
						-- the same plane.
						cframe = base
							* CFrame.new(
								cell[1] * BAY_W / 3 + BAY_W / 6,
								1.4 + cell[2] * (BAY_H / 3) + BAY_H / 6,
								-2.0
							),
						color = dressing.wallSunken,
						material = Enum.Material.Slate,
						parent = folder,
					})
				end
			end

			local tombAt = centre + fireWall.at
			local tombBase = CFrame.lookAt(tombAt, tombAt + fireWall.facing)
			--[[
				Lengthways along the wall, not out into the room.

				In this frame -Z is into the room, so a chest eighteen studs
				deep centred six in reaches three studs out through the wall
				behind it. It is eighteen long and nine deep instead, which is
				the shape a chest tomb is and leaves the floor in front of it
				clear.
			]]
			Build.part({
				name = "ChestTomb",
				size = Vector3.new(18, 4.4, 9),
				cframe = tombBase * CFrame.new(0, 2.2, -5.2),
				color = dressing.wall,
				material = Enum.Material.Rock,
				parent = folder,
			})
			Build.part({
				name = "TombLid",
				size = Vector3.new(19.6, 1.4, 10.6),
				cframe = tombBase * CFrame.new(0, 5.1, -5.2),
				color = dressing.wallSunken,
				material = Enum.Material.Slate,
				parent = folder,
			})
			--[[
				And two standing free on the floor.

				The chest against the wall is the parish's; these are the ones
				somebody paid for, and they are what a crypt is for. Out in the
				open floor rather than against the stonework, laid the same way
				as the wall tomb so the room has a direction, and far enough
				apart that a mower goes between them rather than round the pair.

				Solid, so the sweep takes the strip of floor they stand on out
				of the section's demand — the same bargain the shelves and the
				pews make.
			]]
			--[[
				In the wall's own frame local X runs along the wall and local
				Z into the room, so a box laid lengthways is long in X — the
				same way round as the chest against the wall. They are set
				apart across the room rather than along it, so they stand side
				by side in the middle of the floor instead of end to end.
			]]
			local acrossWall = if alongZWalls then Vector3.new(1, 0, 0) else Vector3.new(0, 0, 1)
			local acrossSpan = if alongZWalls then width else depth
			for _, side in { -1, 1 } do
				local at = centre + acrossWall * (side * acrossSpan * 0.18)
				local base = CFrame.lookAt(at, at + fireWall.facing)
				Build.part({
					name = "Sarcophagus",
					size = Vector3.new(17, 4.2, 8.6),
					cframe = base * CFrame.new(0, 2.1, 0),
					color = dressing.wall,
					material = Enum.Material.Rock,
					parent = folder,
				})
				Build.part({
					name = "SarcophagusLid",
					size = Vector3.new(18.4, 1.6, 10),
					cframe = base * CFrame.new(0, 5, 0),
					color = dressing.wallSunken,
					material = Enum.Material.Slate,
					parent = folder,
				})
			end

			for _, side in { -1, 1 } do
				Structures.urn({
					foot = tombBase * CFrame.new(side * 12, 0, -3.4),
					plinth = 3.4,
					body = dressing.wallSunken,
					bodyMaterial = Enum.Material.Slate,
					stone = dressing.wall,
					stoneMaterial = Enum.Material.Rock,
					parent = folder,
				})
			end
		elseif dressing.underground == "workshop" then
			--[[
				A bench down one wall and a rack of drums against the other.

				What stands here is the same idea as the shelves — the two
				walls nothing else is using, furnished so the room reads as
				somewhere rather than as a lid on a floor — but it is a
				filling station's undercroft, so it is benches, a pegboard of
				tools over them, oil drums and a stack of tyres.
			]]
			local BENCH_RUN = 26
			local runs = math.max(math.floor(shelfWall.span / 40), 1)
			for index = 1, runs do
				local slide = -shelfWall.span * 0.5 + shelfWall.span * (index / (runs + 1))
				local offset = if alongZWalls then Vector3.new(0, 0, slide) else Vector3.new(slide, 0, 0)
				local at = centre + shelfWall.at + offset
				local base = CFrame.lookAt(at, at + shelfWall.facing)
				Build.part({
					name = "BenchTop",
					size = Vector3.new(BENCH_RUN, 0.9, 5),
					cframe = base * CFrame.new(0, 4.6, -2.8),
					color = Color3.fromRGB(122, 96, 62),
					material = Enum.Material.WoodPlanks,
					parent = folder,
				})
				for _, side in { -1, 1 } do
					Build.part({
						name = "BenchLeg",
						size = Vector3.new(1.2, 4.6, 4),
						cframe = base * CFrame.new(side * (BENCH_RUN * 0.5 - 1.4), 2.3, -2.8),
						color = Color3.fromRGB(74, 78, 86),
						material = Enum.Material.Metal,
						parent = folder,
					})
				end
				-- A pegboard over the bench, with something hanging on it.
				Build.part({
					name = "Pegboard",
					size = Vector3.new(BENCH_RUN - 2, 9, 0.5),
					cframe = base * CFrame.new(0, 10.5, -0.6),
					color = Color3.fromRGB(92, 74, 52),
					material = Enum.Material.WoodPlanks,
					canCollide = false,
					parent = folder,
				})
				for tool = 1, 5 do
					Build.part({
						name = "HungTool",
						size = Vector3.new(0.7, 4.2, 0.4),
						cframe = base
							* CFrame.new(-BENCH_RUN * 0.4 + BENCH_RUN * 0.8 * (tool - 1) / 4, 10.5, -1.1),
						color = Color3.fromRGB(178, 182, 190),
						material = Enum.Material.Metal,
						canCollide = false,
						parent = folder,
					})
				end
			end

			local drumAt = centre + fireWall.at
			local drumBase = CFrame.lookAt(drumAt, drumAt + fireWall.facing)
			for index = -2, 2 do
				Build.part({
					name = "OilDrum",
					shape = Enum.PartType.Cylinder,
					size = Vector3.new(7, 4.4, 4.4),
					cframe = drumBase
						* CFrame.new(index * 7, 3.5, -3.4)
						* CFrame.Angles(0, 0, math.rad(90)),
					color = if index % 2 == 0
						then Color3.fromRGB(150, 60, 46)
						else Color3.fromRGB(64, 74, 92),
					material = Enum.Material.Metal,
					parent = folder,
				})
			end
			--- A stack of tyres beside them, which is what a workshop has.
			tyreStack(drumBase * CFrame.new(-24, 0, -4), folder)
		else
			local runs = math.max(math.floor(shelfWall.span / 34), 1)
			for index = 1, runs do
				local slide = -shelfWall.span * 0.5 + shelfWall.span * (index / (runs + 1))
				local offset = if alongZWalls then Vector3.new(0, 0, slide) else Vector3.new(slide, 0, 0)
				local at = centre + shelfWall.at + offset
				bookcase(CFrame.lookAt(at, at + shelfWall.facing))
			end
			local fireAt = centre + fireWall.at
			fireplace(CFrame.lookAt(fireAt, fireAt + fireWall.facing))
		end

		--[[
			Lamps under the ceiling, on a grid.

			Two on the walls lit a pit well enough because the sky was doing
			the work. Under a lid they are the only light there is, so there
			is one about every thirty studs and they reach far enough to
			overlap — a cellar you cannot see the far end of is a cellar you
			cannot mow.
		]]
		local LAMP_PITCH = 30
		local acrossX = math.max(math.floor(width / LAMP_PITCH), 1)
		local acrossZ = math.max(math.floor(depth / LAMP_PITCH), 1)
		for ix = 1, acrossX do
			for iz = 1, acrossZ do
				local at = centre
					+ Vector3.new(
						-width * 0.5 + width * ((ix - 0.5) / acrossX),
						rise - 2.6,
						-depth * 0.5 + depth * ((iz - 0.5) / acrossZ)
					)
				--[[
					A crypt is lit cold.

					The warm fixture is right for a cellar under a house and it
					is half of why this room read as one: granite walls and a
					stone floor under amber light come out the colour of
					plaster. The same lamps in a bluish white leave the stone
					looking like stone, and a shade dimmer because there is
					nothing down here anybody needs to read by.
				]]
				local crypt = dressing.underground == "crypt"
				local lamp = Build.part({
					name = "CellarLamp",
					size = Vector3.new(4.2, 0.8, 1.6),
					cframe = CFrame.new(at),
					color = if crypt
						then Color3.fromRGB(226, 234, 244)
						else Color3.fromRGB(255, 240, 205),
					material = Enum.Material.Neon,
					canCollide = false,
					parent = folder,
				})
				local glow = Instance.new("PointLight")
				-- Enough to read the floor by from anywhere in the room, and
				-- not so much that eight of them overlap into daylight: the
				-- first pass at this washed the whole cellar orange.
				glow.Color = if crypt
					then Color3.fromRGB(204, 216, 238)
					else Color3.fromRGB(255, 232, 186)
				glow.Range = 38
				glow.Brightness = if crypt then 0.92 else 1.15
				glow.Parent = lamp
			end
		end
	end

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
			color = dressing.roof,
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
				-- The roof's own colour unless the property has a band of its
				-- own: a fascia belongs to the roof, and the trim teal that
				-- suits a house is a stranger on a filling station's wash bay.
				color = dressing.fascia or dressing.roof,
				material = Enum.Material.SmoothPlastic,
				canCollide = false,
				parent = folder,
			})
		end
		--- The side runs stop where the front and back runs start. Run out to
		--- the full footprint they crossed at all four corners, two fascias
		--- deep with their faces on the same plane, and each corner flickered.
		for _, sx in { -1, 1 } do
			Build.part({
				name = "Eaves",
				size = Vector3.new(1.4, FASCIA, depth + OVERHANG * 2 - 2.8),
				cframe = CFrame.new(
					centre + Vector3.new(sx * (width * 0.5 + OVERHANG - 0.7), fasciaY, 0)
				),
				-- The roof's own colour unless the property has a band of its
				-- own: a fascia belongs to the roof, and the trim teal that
				-- suits a house is a stranger on a filling station's wash bay.
				color = dressing.fascia or dressing.roof,
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

		if dressing.fitting == "garage" then
			--[[
				What is in a garage, which is never a car.

				The fourth room on the list with a name on the sign and an
				empty floor under it. A domestic garage is the place the car
				is not: a bench down one side, a rack of shelves down the
				other with boxes on it, a stack of tyres in the corner and
				tins somebody meant to take to the tip.

				Boards above head height do not collide. A shelf at eight
				studs is over a player and under nothing the buried-tile sweep
				reaches, so a solid one would leave the tile under it sown and
				unstandable — the fault the wash bay's jet heads had.
			]]
			--[[
				Which way round a fitting goes is decided by the doorway, not
				by which side of the room is longer.

				Taking the longer side put the bench down the wall the door is
				in and stood thirty-four studs of workbench across the
				entrance. The two walls the way in does not use are the ones
				the furniture goes against — the same choice the cellar's
				bookcases already make, for the same reason.
			]]
			local alongX = opening == nil or math.abs(opening.normal.X) > 0.5
			local long = if alongX then width else depth
			local across = if alongX then depth else width
			local function place(down: number, side: number, y: number): Vector3
				return centre
					+ (if alongX then Vector3.new(down, y, side) else Vector3.new(side, y, down))
			end
			local timberDark = Color3.fromRGB(78, 56, 38)
			local steel = Color3.fromRGB(126, 130, 138)
			local wall = across * 0.5 - 4

			--- The bench, down one side.
			local BENCH = math.min(long * 0.5, 34)
			Build.part({
				name = "BenchTop",
				size = if alongX then Vector3.new(BENCH, 0.9, 5) else Vector3.new(5, 0.9, BENCH),
				cframe = CFrame.new(place(-long * 0.16, -wall + 2.6, 4.6)),
				color = Color3.fromRGB(122, 96, 62),
				material = Enum.Material.WoodPlanks,
				parent = folder,
			})
			for _, end_ in { -1, 1 } do
				Build.part({
					name = "BenchLeg",
					size = Vector3.new(1.2, 4.6, 4),
					cframe = CFrame.new(
						place(-long * 0.16 + end_ * (BENCH * 0.5 - 1.4), -wall + 2.6, 2.3)
					),
					color = steel,
					material = Enum.Material.Metal,
					parent = folder,
				})
			end
			--- Tins on it, because a garage bench always has tins on it.
			for tin = -1, 1 do
				Build.part({
					name = "PaintTin",
					shape = Enum.PartType.Cylinder,
					size = Vector3.new(2.4, 2, 2),
					cframe = CFrame.new(
						place(-long * 0.16 + tin * 5, -wall + 2.6, 6.2)
					) * CFrame.Angles(0, 0, math.rad(90)),
					color = if tin == 0
						then Color3.fromRGB(72, 108, 150)
						else Color3.fromRGB(168, 92, 60),
					material = Enum.Material.Metal,
					canCollide = false,
					parent = folder,
				})
			end

			--- Shelves down the other, with boxes on them.
			local RACK = math.min(long * 0.5, 30)
			--[[
				Four posts, not two panels.

				One upright the full four studs of the shelf's depth is not a
				post, it is a sheet of grey standing on end — twelve studs
				tall and four wide, it read as a partition wall with shelves
				bolted to it. A rack is a corner post at each end of each
				side, and the gap between the pair is what makes it a frame
				you can see through rather than a slab you cannot.

				Tall enough to hold the top shelf's boxes, too: at ten they
				stopped two studs under the highest carton and the boxes
				floated off the top of their own frame.
			]]
			for _, end_ in { -1, 1 } do
				for _, face in { -1, 1 } do
					Build.part({
						name = "RackUpright",
						size = if alongX
							then Vector3.new(1, 12.4, 1.2)
							else Vector3.new(1.2, 12.4, 1),
						cframe = CFrame.new(
							place(
								long * 0.16 + end_ * (RACK * 0.5),
								wall - 2 + face * 1.6,
								6.2
							)
						),
						color = steel,
						material = Enum.Material.Metal,
						parent = folder,
					})
				end
			end
			for level = 0, 2 do
				local y = 2.2 + level * 3.4
				Build.part({
					name = "RackShelf",
					size = if alongX then Vector3.new(RACK, 0.5, 4) else Vector3.new(4, 0.5, RACK),
					cframe = CFrame.new(place(long * 0.16, wall - 2, y)),
					color = timberDark,
					material = Enum.Material.WoodPlanks,
					canCollide = false,
					parent = folder,
				})
				for box = -1, 1 do
					Build.part({
						name = "RackBox",
						size = Vector3.new(4.4, 2.6, 3.2),
						cframe = CFrame.new(
							place(long * 0.16 + box * (RACK * 0.3), wall - 2, y + 1.5)
						),
						color = if (level + box) % 2 == 0
							then Color3.fromRGB(150, 118, 78)
							else Color3.fromRGB(126, 98, 64),
						material = Enum.Material.Cardboard,
						canCollide = false,
						parent = folder,
					})
				end
			end

			--- And a stack of tyres in the corner.
			tyreStack(CFrame.new(place(-long * 0.38, wall - 3, 0)), folder)
		elseif dressing.fitting == "washbay" then
			--[[
				What makes a concrete box a wash bay.

				The first pass at this put two dividers and three posts in a
				hundred and eight studs by a hundred and eighty-four and it was
				still, correctly, "just an empty room". What says wash bay is
				not the walls, it is the machinery: an arch you drive under with
				the brushes hanging off it, a channel in the floor for the water
				to go down, and a jet on a post you can actually see is a jet.

				Three lanes, divided the way a car goes through. Everything
				overhead is non-colliding — a gantry beam hangs at the height a
				player's head is, and a solid one would leave the tile under it
				sown and unreachable, which is how the jet heads broke the
				section the first time.
			]]
			--- Down the way a car comes in, not down the longer side: the
			--- lanes have to line up with the doorway or you drive across
			--- them. See the garage above.
			local alongX = opening == nil or math.abs(opening.normal.X) > 0.5
			local long = if alongX then width else depth
			local across = if alongX then depth else width
			local function place(down: number, side: number, y: number): Vector3
				return centre
					+ (if alongX then Vector3.new(down, y, side) else Vector3.new(side, y, down))
			end
			local steel = Color3.fromRGB(148, 152, 160)
			local hazard = Color3.fromRGB(226, 178, 46)

			--- Two dividers, splitting the floor into three lanes.
			local DIVIDE_LEN = long * 0.52
			for _, side in { -1, 1 } do
				local offset = side * across * 0.17
				Build.part({
					name = "BayDivider",
					size = if alongX
						then Vector3.new(DIVIDE_LEN, 6, 1.6)
						else Vector3.new(1.6, 6, DIVIDE_LEN),
					cframe = CFrame.new(place(0, offset, 3)),
					color = dressing.wallSunken,
					material = Enum.Material.Concrete,
					parent = folder,
				})
				Build.part({
					name = "BayStripe",
					size = if alongX
						then Vector3.new(DIVIDE_LEN, 0.5, 2.2)
						else Vector3.new(2.2, 0.5, DIVIDE_LEN),
					cframe = CFrame.new(place(0, offset, 6.25)),
					color = hazard,
					material = Enum.Material.SmoothPlastic,
					canCollide = false,
					parent = folder,
				})
			end

			local LANE = across * 0.34
			for _, side in { -1, 0, 1 } do
				local offset = side * LANE
				local half = across * 0.15

				--[[
					The gantry, which is the thing a wash bay is.

					Two uprights and a beam across, with a rank of brushes
					hanging off it low enough to reach a car roof. Set a third
					of the way down the lane so you can see under it from the
					door.
				]]
				local archAt = -long * 0.12
				for _, post in { -1, 1 } do
					Build.part({
						name = "ArchLeg",
						size = Vector3.new(1.4, 13, 1.4),
						cframe = CFrame.new(place(archAt, offset + post * half, 6.5)),
						color = steel,
						material = Enum.Material.Metal,
						parent = folder,
					})
				end
				Build.part({
					name = "ArchBeam",
					size = if alongX
						then Vector3.new(2, 1.6, half * 2 + 1.4)
						else Vector3.new(half * 2 + 1.4, 1.6, 2),
					cframe = CFrame.new(place(archAt, offset, 13.2)),
					color = hazard,
					material = Enum.Material.Metal,
					canCollide = false,
					parent = folder,
				})
				for brush = -2, 2 do
					Build.part({
						name = "WashBrush",
						shape = Enum.PartType.Cylinder,
						size = Vector3.new(5.6, 3.2, 3.2),
						cframe = CFrame.new(
							place(archAt, offset + brush * half * 0.4, 9.6)
						) * CFrame.Angles(0, 0, math.rad(90)),
						color = Color3.fromRGB(74, 108, 156),
						material = Enum.Material.Fabric,
						canCollide = false,
						parent = folder,
					})
				end

				--- The jet, on a post, at the head of the lane.
				local at = place(-long * 0.34, offset, 0)
				Build.part({
					name = "JetPost",
					size = Vector3.new(1.6, 11, 1.6),
					cframe = CFrame.new(at + Vector3.new(0, 5.5, 0)),
					color = steel,
					material = Enum.Material.Metal,
					parent = folder,
				})
				--- Non-colliding: it is wider than its post, so it overhangs
				--- the tile next door at head height, which is above the reach
				--- of the buried-tile sweep and inside the height of a player.
				Build.part({
					name = "JetBox",
					size = Vector3.new(3.4, 4.6, 2.6),
					cframe = CFrame.new(at + Vector3.new(0, 8, 0)),
					color = Color3.fromRGB(196, 62, 48),
					material = Enum.Material.SmoothPlastic,
					canCollide = false,
					parent = folder,
				})
				Build.part({
					name = "HoseCoil",
					shape = Enum.PartType.Cylinder,
					size = Vector3.new(1, 4.4, 4.4),
					cframe = CFrame.new(at + Vector3.new(0, 4.4, 0))
						* CFrame.Angles(0, 0, math.rad(90)),
					color = Color3.fromRGB(38, 40, 46),
					material = Enum.Material.SmoothPlastic,
					canCollide = false,
					parent = folder,
				})

				--- A channel down the middle of the lane rather than one round
				--- drain, because that is where the water actually goes.
				Build.part({
					name = "DrainChannel",
					size = if alongX
						then Vector3.new(long * 0.72, 0.3, 2.4)
						else Vector3.new(2.4, 0.3, long * 0.72),
					cframe = CFrame.new(place(0, offset, 0.1)),
					color = Color3.fromRGB(58, 60, 66),
					material = Enum.Material.DiamondPlate,
					canCollide = false,
					castShadow = false,
					parent = folder,
				})

				--- Bollards at the mouth, so the lane reads as a lane.
				for _, post in { -1, 1 } do
					Build.part({
						name = "Bollard",
						shape = Enum.PartType.Cylinder,
						size = Vector3.new(5, 2.2, 2.2),
						cframe = CFrame.new(place(-long * 0.42, offset + post * half, 2.5))
							* CFrame.Angles(0, 0, math.rad(90)),
						color = hazard,
						material = Enum.Material.SmoothPlastic,
						parent = folder,
					})
				end
			end

			--- And a board on the end wall, because every wash bay has one.
			Build.part({
				name = "BayBoard",
				size = if alongX then Vector3.new(2, 9, 26) else Vector3.new(26, 9, 2),
				cframe = CFrame.new(place(long * 0.46, 0, 10)),
				color = Color3.fromRGB(196, 62, 48),
				material = Enum.Material.SmoothPlastic,
				canCollide = false,
				parent = folder,
			})
			Build.part({
				name = "BayBoardFace",
				size = if alongX then Vector3.new(1, 6, 21) else Vector3.new(21, 6, 1),
				cframe = CFrame.new(place(long * 0.455, 0, 10)),
				color = Color3.fromRGB(240, 240, 236),
				material = Enum.Material.SmoothPlastic,
				canCollide = false,
				parent = folder,
			})
		elseif dressing.fitting == "chapel" then
			--[[
				What makes a granite box a chapel.

				The crypt below this property got shelves and a fire because a
				cellar with nothing in it is a room; the same is true one floor
				up, and more so, because this one has a name on the sign. It
				was four walls, a floor and three worklights.

				Everything here stands against the walls or down the sides,
				and the aisle between the pews is fourteen studs — wider than
				the widest deck in the game, so the room a wide mower needs is
				the room a congregation needs, which is convenient rather than
				a coincidence. The buried-tile sweep takes the strip of floor
				under each solid piece out of the section's total, so nothing
				here makes the property harder to finish than it reads.
			]]
			local stone = dressing.wallSunken
			local dark = dressing.roof
			--- The way the room runs, so the altar goes at the end furthest
			--- from the door rather than in front of it.
			local alongX = width >= depth
			local long = if alongX then width else depth
			local across = if alongX then depth else width
			local function place(down: number, side: number, y: number): Vector3
				return centre
					+ (if alongX then Vector3.new(down, y, side) else Vector3.new(side, y, down))
			end
			--- Which end the door is at, so the altar takes the other one.
			local doorSign = 1
			if opening then
				local n = if alongX then opening.normal.X else opening.normal.Z
				if n ~= 0 then
					doorSign = if n > 0 then -1 else 1
				end
			end
			local altarAt = -doorSign * (long * 0.5 - 12)

			-- A dais, the altar on it, and a candle at each corner.
			Build.part({
				name = "Dais",
				size = if alongX then Vector3.new(14, 1.2, 34) else Vector3.new(34, 1.2, 14),
				cframe = CFrame.new(place(altarAt, 0, 0.6)),
				color = stone,
				material = Enum.Material.Slate,
				parent = folder,
			})
			Build.part({
				name = "Altar",
				size = if alongX then Vector3.new(5, 5, 18) else Vector3.new(18, 5, 5),
				cframe = CFrame.new(place(altarAt, 0, 3.7)),
				color = dressing.wall,
				material = Enum.Material.Marble,
				parent = folder,
			})
			for _, side in { -1, 1 } do
				local candle = Build.part({
					name = "Candle",
					size = Vector3.new(0.9, 3.4, 0.9),
					cframe = CFrame.new(place(altarAt, side * 6.5, 7.9)),
					color = Color3.fromRGB(238, 230, 206),
					material = Enum.Material.Neon,
					canCollide = false,
					castShadow = false,
					parent = folder,
				})
				local flame = Instance.new("PointLight")
				flame.Color = Color3.fromRGB(255, 214, 150)
				flame.Range = 22
				flame.Brightness = 0.9
				flame.Shadows = false
				flame.Parent = candle
			end

			--[[
				Pews, in two banks with an aisle down the middle.

				Solid, because a pew you walk through is a decal. Backs on
				them, because a bench without one is a park bench and this is
				not a park.
			]]
			local AISLE = 14
			local PEW_PITCH = 9
			local pewLength = math.max((across - AISLE) * 0.5 - 8, 6)
			local pewOffset = AISLE * 0.5 + pewLength * 0.5
			local first = altarAt + doorSign * 26
			local rows = math.max(math.floor((long * 0.5 - 20) / PEW_PITCH), 1)
			for row = 0, rows - 1 do
				local down = first + doorSign * row * PEW_PITCH
				for _, side in { -1, 1 } do
					Build.part({
						name = "Pew",
						size = if alongX
							then Vector3.new(2.2, 2.4, pewLength)
							else Vector3.new(pewLength, 2.4, 2.2),
						cframe = CFrame.new(place(down, side * pewOffset, 1.2)),
						color = Color3.fromRGB(78, 54, 36),
						material = Enum.Material.WoodPlanks,
						parent = folder,
					})
					Build.part({
						name = "PewBack",
						size = if alongX
							then Vector3.new(0.8, 3, pewLength)
							else Vector3.new(pewLength, 3, 0.8),
						cframe = CFrame.new(
							place(down, side * pewOffset, 3.9)
								+ (if alongX then Vector3.new(-doorSign * 0.7, 0, 0) else Vector3.new(0, 0, -doorSign * 0.7))
						),
						color = Color3.fromRGB(66, 44, 30),
						material = Enum.Material.WoodPlanks,
						parent = folder,
					})
				end
			end

			--[[
				Windows down both long walls, lit from the inside.

				A chapel is its windows. These are set proud of the wall the
				way the property's others are, and each carries a light of its
				own — small, because there are six of them and the worklights
				overhead are already doing the work of seeing by. What these
				are for is the colour on the stone.
			]]
			--[[
				Not one over the door.

				The windows are spaced evenly down both long walls without
				asking where the way in is, so on a room whose door happens to
				land near a spacing mark the doorway came out with a lit
				window across it — reported as the door being covered by a
				window. The opening knows where it is and how wide; anything
				that would stand within half the doorway plus half a window of
				it is simply not built.
			]]
			local doorSide = 0
			local doorAt = 0
			if opening then
				local acrossNormal = if alongX then opening.normal.Z else opening.normal.X
				if math.abs(acrossNormal) > 0.5 then
					doorSide = if acrossNormal > 0 then 1 else -1
					doorAt = opening.offset or 0
				end
			end
			local perSide = math.max(math.floor(long / 40), 2)
			for _, side in { -1, 1 } do
				for index = 1, perSide do
					local down = long * (index / (perSide + 1) - 0.5)
					local clashes = side == doorSide
						and math.abs(down - doorAt) < (if opening then opening.width * 0.5 else 0) + 5
					if clashes then
						continue
					end
					--[[
						On the wall's own centre line, and thicker than it.

						Set just inside the inner face, the glass showed in the
						room and the surround — which stood proud of the outer
						face — covered it from the churchyard, so a chapel with
						six lit windows presented a hundred and thirty-six
						studs of blank grey to the walk you approach it along.
						The wall is a stud and a half thick; both pieces are
						centred on it and thicker than that, the glass thicker
						than the surround, so each face gets a lit pane with a
						stone border round it.
					]]
					local at = place(down, side * across * 0.5, wallHeight * 0.58)
					local window = Build.part({
						name = "ChapelGlass",
						size = if alongX
							then Vector3.new(6, 11, 3.2)
							else Vector3.new(3.2, 11, 6),
						cframe = CFrame.new(at),
						color = Color3.fromRGB(226, 176, 86),
						material = Enum.Material.Neon,
						canCollide = false,
						castShadow = false,
						parent = folder,
					})
					local lit = Instance.new("PointLight")
					lit.Color = Color3.fromRGB(255, 206, 138)
					lit.Range = 20
					lit.Brightness = 0.5
					lit.Shadows = false
					lit.Parent = window
					Build.part({
						name = "ChapelMullion",
						size = if alongX
							then Vector3.new(8, 13, 2.6)
							else Vector3.new(2.6, 13, 8),
						cframe = CFrame.new(at),
						color = dark,
						material = Enum.Material.Slate,
						canCollide = false,
						parent = folder,
					})
				end
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
		-- Sunk a third of a stud below where the treads land. Set flush, the
		-- wedge's slope runs exactly through the nosings and the two surfaces
		-- flicker along the whole flight; the treads are over a stud thick, so
		-- dropping the wedge still leaves nothing showing through.
		local seat = lowY + rise * 0.5 - 0.35
		wedge.CFrame = CFrame.lookAt(
			Vector3.new(centre.X, seat, centre.Z),
			Vector3.new(centre.X, seat, centre.Z) + downhill
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

	--- Six hundredths proud of the lawn, not flush with it: the coping's top
	--- face and the grass beside it were on one plane and fought for it.
	Structures.wallRing({
		name = "PoolWall",
		centre = centre + Vector3.new(0, -depthBelow + 0.06, 0),
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

	--[[
		A ladder and a board, which is what tells you it is a swimming pool.

		Six parts — a floor, four walls and a sheet of water — is a blue
		rectangle in the ground. It is the one thing on this property anybody
		would describe if you asked them what was in the garden, and it had
		nothing you could name in it.

		Both stand on the rim rather than in the water, and neither collides:
		the rim is walked on and mown, and a solid handrail at the edge of the
		basin is something to catch on for no gain.
	]]
	local lip = centre + Vector3.new(0, 0.2, 0)
	local halfW, halfD = width * 0.5, depth * 0.5
	local steel = Color3.fromRGB(196, 200, 208)

	--- The ladder, at the deep end's near corner.
	local ladderAt = lip + Vector3.new(halfW - 7, 0, halfD)
	for _, side in { -1, 1 } do
		Build.part({
			name = "PoolRail",
			shape = Enum.PartType.Cylinder,
			size = Vector3.new(7, 0.7, 0.7),
			cframe = CFrame.new(ladderAt + Vector3.new(side * 1.6, 3.4, 0))
				* CFrame.Angles(0, 0, math.rad(90)),
			color = steel,
			material = Enum.Material.Metal,
			canCollide = false,
			castShadow = false,
			parent = folder,
		})
	end
	Build.part({
		name = "PoolRailArc",
		size = Vector3.new(3.9, 0.7, 0.7),
		cframe = CFrame.new(ladderAt + Vector3.new(0, 6.9, 0)),
		color = steel,
		material = Enum.Material.Metal,
		canCollide = false,
		castShadow = false,
		parent = folder,
	})

	--- The board, cantilevered out over the shallow end.
	local boardAt = lip + Vector3.new(-halfW + 2, 0, 0)
	Build.part({
		name = "DivingPlinth",
		size = Vector3.new(3, 2.6, 5),
		cframe = CFrame.new(boardAt + Vector3.new(-1, 1.3, 0)),
		color = Palette.color(Palette.ground.stone),
		material = Enum.Material.Concrete,
		parent = folder,
	})
	Build.part({
		name = "DivingBoard",
		size = Vector3.new(11, 0.7, 4),
		cframe = CFrame.new(boardAt + Vector3.new(3.5, 2.8, 0)),
		color = Color3.fromRGB(238, 240, 236),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		castShadow = false,
		parent = folder,
	})

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
--[[
	A hedge maze, carved rather than striped.

	This built parallel rows across the section with two gaps punched in each
	one. From the ground that is a fence you walk round; from the air it is a
	nursery — twelve straight lines of hedge with nothing between them but
	more straight lines. Nothing in it turns, nothing in it ends, and the
	route through is "walk to the nearest gap" repeated until you are out.

	It is now a real maze: a grid of cells with a wall on every side, carved
	into a single connected route by a randomised depth-first walk. That is
	the standard method and it is the one that produces what a maze looks
	like — long corridors, corners, and dead ends you have to come back out
	of. Being a spanning tree, every cell is reachable from every other, so
	no debris can be walled off from the player.

	Corridors are three tiles across and the walls one thick, which is what
	keeps the section mowable: every tile under a hedge is next to a corridor,
	so it is still inside the reach of whatever the player is swinging.

	The perimeter is closed but for one gap a side, which is decoration on top
	of a guarantee — the carve already connects everything, so a single way in
	would do.
]]
--- How bright a tinted hedge is drawn against its own texture. Four fifths
--- rather than all of it, because yew is dark and a normalised tint is not.
local YEW_BRIGHTNESS = 0.62

--[[
	A churchyard's plots, which is the hardest ground in the game to mow.

	Every other section is open ground with things dropped on it. This one is
	an obstacle field, so a wide deck spends as much time lining up as cutting
	and the mowers that turn on the spot finally earn their price.

	The first cut of this was a solid grid at every third tile, and it came
	back as "too many headstones" — which it was, and worse, it was regular:
	four hundred identical stones in ranks reads as a car park with markers
	in it rather than as a burial ground.

	A real churchyard is laid out in blocks with walks between them, the
	plots inside a block are generously spaced, and a good third of them are
	either empty or hold nothing but a kerb. So: five plots to a block, a
	three tile walk between blocks, sixteen and twenty studs between stones,
	and a seeded roll deciding what stands on each — four shapes across two
	granites, some leaning, some sunk to a kerb, some nothing at all.

	The stones are solid, so the buried-tile sweep takes the tile each one
	stands on out of the section's total. You cannot mow through granite, and
	the property should not count it.
]]
function Structures.graves(context: Context, zone: Types.ZoneDef)
	local r = zone.rect
	local folder = Build.folder(`Graves_{zone.id}`, context.parent)
	local elevation = zone.elevation or 0

	--- Tiles between plots, and how many plots before a walk.
	local PITCH_X, PITCH_Z = 4, 5
	local BLOCK_X, BLOCK_Z = 5, 4
	local WALK = 3

	local granite = Palette.color(Palette.churchyard.granite)
	local darker = Palette.color(Palette.churchyard.graniteDark)
	local lichen = Palette.color(Palette.churchyard.lichen)
	--- Seeded off where the plot is, so a churchyard built twice is the same
	--- churchyard and two people on the same run see the same stones.
	local rng = Random.new(r.x * 7919 + r.z * 104729 + r.w * 15485863 + r.d)

	--[[
		Some blocks hold a family rather than a row of plots.

		A churchyard of nothing but headstones is flat: the eye has nothing to
		stop on and no sense of anybody here having been richer or older than
		anybody else. A mausoleum is the thing that fixes that — it is the one
		structure on the ground with a roof and a door, and at night it is a
		shape you notice from the far side of the property.

		A whole block is given over to one rather than squeezing it between
		plots: a block is five plots by four, about twenty studs square, which
		holds a fourteen-stud building with room to walk round it. The plots
		that would have stood there are simply not sown, so no stone ends up
		inside a wall.
	]]
	--[[
		Which blocks hold a mausoleum, counted first and then chosen.

		A roll per block as each one turned up read fine and was wrong here:
		this section has six blocks, so at three in ten apiece there is better
		than a one in nine chance of the property having none at all — and the
		seed is fixed, so that is not a rare run, it is either always or never.
		It was never. Walking the plots once without drawing anything gives the
		count up front, and a third of them rounded up is at least one whatever
		size the section is.

		The walk consumes no randomness, so the stones the second pass lays
		down are exactly the ones it would have laid without this.
	]]
	local blockCentre: { [string]: { sum: Vector3, count: number } } = {}
	local blockOrder: { string } = {}
	local mausoleumBlock: { [string]: boolean } = {}
	do
		local px = 0
		while true do
			local tx = r.x + 3 + px * PITCH_X + (px // BLOCK_X) * WALK
			if tx > r.x + r.w - 3 or px > 200 then
				break
			end
			local pz = 0
			while true do
				local tz = r.z + 3 + pz * PITCH_Z + (pz // BLOCK_Z) * WALK
				if tz > r.z + r.d - 4 or pz > 200 then
					break
				end
				local key = `{px // BLOCK_X},{pz // BLOCK_Z}`
				local entry = blockCentre[key]
				if not entry then
					entry = { sum = Vector3.zero, count = 0 }
					blockCentre[key] = entry
					table.insert(blockOrder, key)
				end
				entry.sum += context.flat(tx, tz) + Vector3.new(0, elevation, 0)
				entry.count += 1
				pz += 1
			end
			px += 1
		end

		local wanted = math.max(math.floor(#blockOrder / 3 + 0.5), 1)
		local pick = Random.new(r.x * 31 + r.z * 131 + r.w * 7 + r.d * 17)
		local pool = table.clone(blockOrder)
		for _ = 1, math.min(wanted, #pool) do
			local at = pick:NextInteger(1, #pool)
			mausoleumBlock[pool[at]] = true
			table.remove(pool, at)
		end
	end

	local ix = 0
	while true do
		local tx = r.x + 3 + ix * PITCH_X + (ix // BLOCK_X) * WALK
		if tx > r.x + r.w - 3 then
			break
		end
		local iz = 0
		while true do
			local tz = r.z + 3 + iz * PITCH_Z + (iz // BLOCK_Z) * WALK
			if tz > r.z + r.d - 4 then
				break
			end
			local blockKey = `{ix // BLOCK_X},{iz // BLOCK_Z}`
			iz += 1

			local roll = rng:NextNumber()
			local at = context.flat(tx, tz) + Vector3.new(0, elevation, 0)

			if mausoleumBlock[blockKey] then
				-- This block holds a mausoleum; nothing is sown in it.
				continue
			end
			local lean = if rng:NextNumber() < 0.28 then math.rad(rng:NextNumber(-11, 11)) else 0
			local turn = math.rad(rng:NextNumber(-8, 8))
			local stone = if rng:NextNumber() < 0.35 then lichen else granite

			--[[
				A third of the ground carries nothing.

				Empty plots are what stops a burial ground reading as a grid,
				and they are also the only places a wide deck can turn — which
				is the difference between this section being hard and being
				unfair.
			]]
			if roll < 0.04 then
				--[[
					A grave that is open, which is the one thing in a
					churchyard nobody walks past without looking.

					A pit rather than a hole: the ground is a four-stud slab
					and cutting it is not worth it, so this is a near-black
					floor sunk two studs with a kerb of spoil round three
					sides and the stone already standing at the head of it.
					From above it reads as open ground; from anywhere a player
					actually stands it reads as a grave waiting for somebody.
				]]
				Build.part({
					name = "OpenGrave",
					size = Vector3.new(4.4, 2, 6.6),
					cframe = CFrame.new(at + Vector3.new(0, -0.9, 1.4)) * CFrame.Angles(0, turn, 0),
					color = Color3.fromRGB(16, 14, 13),
					material = Enum.Material.Ground,
					parent = folder,
				})
				for _, edge in
					{
						Vector3.new(2.7, 0.5, 1.4),
						Vector3.new(-2.7, 0.5, 1.4),
						Vector3.new(0, 0.5, 5.1),
					}
				do
					Build.part({
						name = "GraveSpoil",
						size = if math.abs(edge.X) > 0.1
							then Vector3.new(1.4, 1, 7.4)
							else Vector3.new(5.6, 1, 1.4),
						cframe = CFrame.new(at + edge) * CFrame.Angles(0, turn, 0),
						color = Color3.fromRGB(62, 50, 38),
						material = Enum.Material.Ground,
						canCollide = false,
						parent = folder,
					})
				end
				Build.mesh({
					prop = "HeadstonePlain",
					name = "Headstone",
					color = stone,
					size = Vector3.new(3.2, 3.8, 1.1),
					collisionSize = Vector3.new(3.2, 3.8, 1.1),
					cframe = CFrame.new(at + Vector3.new(0, 1.9, -2.2))
						* CFrame.Angles(math.rad(-9), turn, 0),
					parent = folder,
				})
			elseif roll < 0.30 then
				-- Nothing here but grass.
			elseif roll < 0.42 then
				--- A kerbed plot whose stone is long gone.
				Build.part({
					name = "Plot",
					size = Vector3.new(4.2, 0.6, 6.4),
					cframe = CFrame.new(at + Vector3.new(0, 0.3, 1.6)) * CFrame.Angles(0, turn, 0),
					color = darker,
					material = Enum.Material.Slate,
					canCollide = false,
					castShadow = false,
					parent = folder,
				})
			elseif roll < 0.60 then
				Build.mesh({
					prop = "Headstone",
					name = "Headstone",
					size = Vector3.new(3.6, 5.4, 1.2),
					collisionSize = Vector3.new(3.6, 5.4, 1.2),
					cframe = CFrame.new(at + Vector3.new(0, 2.7, 0)) * CFrame.Angles(lean, turn, 0),
					parent = folder,
				})
			elseif roll < 0.78 then
				Build.mesh({
					prop = "HeadstonePlain",
					name = "Headstone",
					color = stone,
					size = Vector3.new(3.2, 3.8, 1.1),
					collisionSize = Vector3.new(3.2, 3.8, 1.1),
					cframe = CFrame.new(at + Vector3.new(0, 1.9, 0)) * CFrame.Angles(lean, turn, 0),
					parent = folder,
				})
			elseif roll < 0.92 then
				Build.mesh({
					prop = "GraveCross",
					name = "GraveCross",
					color = stone,
					size = Vector3.new(3.4, 6.2, 0.9),
					collisionSize = Vector3.new(1.4, 6.2, 0.9),
					cframe = CFrame.new(at + Vector3.new(0, 3.1, 0)) * CFrame.Angles(lean, turn, 0),
					parent = folder,
				})
			else
				--- The occasional family monument, which is what gives a
				--- churchyard a skyline.
				Build.mesh({
					prop = "Tombstone",
					name = "Monument",
					color = darker,
					size = Vector3.new(4.6, 11, 3.4),
					collisionSize = Vector3.new(4.6, 11, 3.4),
					cframe = CFrame.new(at + Vector3.new(0, 5.5, 0)) * CFrame.Angles(0, turn, 0),
					parent = folder,
				})
			end
			if iz > 200 then
				break
			end
		end
		ix += 1
		if ix > 200 then
			break
		end
	end

	--[[
		The mausoleums, one to a block that was set aside for one.

		Built rather than found, because nothing in the catalogue is a small
		stone building and a wrong one would be worse than none. It is a
		plinth, a body, a cornice, a stepped roof and an urn on top, with a
		doorway cut into the face that looks back towards the lawns — the way
		you come in — a pair of columns either side of it and iron across it.
		Behind the bars is the same near-black void the way out uses, because
		a door with a wall behind it is a decal.
	]]
	local iron = Palette.color(Palette.churchyard.iron)
	local function mausoleum(at: Vector3)
		--- Facing the lawns, which is the side of the property everyone
		--- arrives from, so the doors are not all round the back.
		local basis = CFrame.new(at) * CFrame.Angles(0, math.pi, 0)
		local W, BODY = 13, 11

		Build.part({
			name = "TombPlinth",
			size = Vector3.new(W + 3, 1.6, W + 3),
			cframe = basis * CFrame.new(0, 0.8, 0),
			color = darker,
			material = Enum.Material.Slate,
			parent = folder,
		})
		Build.part({
			name = "TombBody",
			size = Vector3.new(W, BODY, W),
			cframe = basis * CFrame.new(0, 1.6 + BODY * 0.5, 0),
			color = granite,
			material = Enum.Material.Rock,
			parent = folder,
		})
		Build.part({
			name = "TombCornice",
			size = Vector3.new(W + 2.4, 1.4, W + 2.4),
			cframe = basis * CFrame.new(0, 1.6 + BODY + 0.7, 0),
			color = darker,
			material = Enum.Material.Slate,
			parent = folder,
		})
		--- A stepped cap rather than a pitch: two courses read as a roof from
		--- the ground and cost two parts.
		for step = 0, 1 do
			Build.part({
				name = "TombRoof",
				size = Vector3.new(W - 1 - step * 4, 1.3, W - 1 - step * 4),
				cframe = basis * CFrame.new(0, 1.6 + BODY + 1.4 + 0.65 + step * 1.3, 0),
				color = darker,
				material = Enum.Material.Slate,
				parent = folder,
			})
		end
		Build.part({
			name = "TombUrn",
			shape = Enum.PartType.Ball,
			size = Vector3.new(3.4, 3.4, 3.4),
			cframe = basis * CFrame.new(0, 1.6 + BODY + 4.4, 0),
			color = lichen,
			material = Enum.Material.Rock,
			parent = folder,
		})

		--- The doorway: a void set into the face, barred, under a lintel.
		local face = W * 0.5
		Build.part({
			name = "TombVoid",
			size = Vector3.new(5.4, 8.4, 1),
			cframe = basis * CFrame.new(0, 1.6 + 4.2, -face + 0.4),
			color = Color3.fromRGB(9, 8, 10),
			material = Enum.Material.SmoothPlastic,
			parent = folder,
		})
		for bar = -2, 2 do
			Build.part({
				name = "TombBar",
				size = Vector3.new(0.4, 8, 0.4),
				cframe = basis * CFrame.new(bar * 1.2, 1.6 + 4, -face - 0.1),
				color = iron,
				material = Enum.Material.Metal,
				canCollide = false,
				parent = folder,
			})
		end
		Build.part({
			name = "TombLintel",
			size = Vector3.new(7.4, 1.2, 1.6),
			cframe = basis * CFrame.new(0, 1.6 + 8.8, -face - 0.1),
			color = darker,
			material = Enum.Material.Slate,
			parent = folder,
		})
		for side in { -1, 1 } do
			Build.part({
				name = "TombColumn",
				shape = Enum.PartType.Cylinder,
				size = Vector3.new(8.4, 2.2, 2.2),
				cframe = basis
					* CFrame.new(side * 4.2, 1.6 + 4.2, -face - 0.6)
					* CFrame.Angles(0, 0, math.rad(90)),
				color = granite,
				material = Enum.Material.Rock,
				parent = folder,
			})
		end
		--- Two steps up to the door, so it stands on something.
		for step = 0, 1 do
			Build.part({
				name = "TombStep",
				size = Vector3.new(9 - step * 1.6, 0.8, 2.4 - step * 0.6),
				cframe = basis * CFrame.new(0, 0.4 + step * 0.8, -face - 2.6 + step * 0.8),
				color = darker,
				material = Enum.Material.Slate,
				parent = folder,
			})
		end
	end

	for _, key in blockOrder do
		local entry = blockCentre[key]
		if mausoleumBlock[key] and entry and entry.count > 0 then
			mausoleum(entry.sum / entry.count)
		end
	end

	return folder
end

--[[
	What a maze is grown out of.

	`prop` is the catalogue entry a wall tile is built from, `tint` the colour
	it is asked for, and `height` how far over your head it stands. A tinted
	mesh is also darkened against its own texture, which is right for yew and
	wrong for corn — corn is already the colour it should be, and dragging it
	towards a tint only makes it muddy — so `shade` says whether to.
]]
export type MazeCrop = {
	prop: string,
	tint: Color3?,
	height: number?,
	shade: boolean?,
	--- A random turn on every tile, so a long row is not one plant cloned.
	spin: boolean?,
	--- Scarecrows to stand in the corridors. A corn maze has one; it is most
	--- of why a corn maze is frightening rather than agricultural.
	sentinels: number?,
}

function Structures.maze(context: Context, zone: Types.ZoneDef, crop: MazeCrop?)
	local r = zone.rect
	local tile = context.tileSize
	local folder = Build.folder(`Maze_{zone.id}`, context.parent)

	--- Three tiles of corridor and one of hedge.
	local PITCH = 4
	local cols = math.max(math.floor((r.w - 1) / PITCH), 1)
	local rows = math.max(math.floor((r.d - 1) / PITCH), 1)
	local grown: MazeCrop = crop or { prop = "Hedge", shade = true }
	local tint = grown.tint
	local wallHeight = grown.height or 9

	--[[
		Walls between cells, indexed by the cell on their low side.

		`down[cx][cz]` is the wall on the far z edge of cell (cx, cz), and
		`right[cx][cz]` the one on its far x edge, so the section's own two
		outer edges are `down[.][-1]` and `right[-1][.]`. Everything starts
		standing and the carve takes pieces out.
	]]
	local down: { { boolean } } = {}
	local right: { { boolean } } = {}
	for cx = -1, cols do
		down[cx] = {}
		right[cx] = {}
		for cz = -1, rows do
			down[cx][cz] = true
			right[cx][cz] = true
		end
	end

	--[[
		Seeded off where the maze is, so a property built twice is the same
		property. A maze that reshuffled on every join would make the route
		somebody just learned worthless, and it would not match the one their
		friend on the same run is walking.
	]]
	local rng = Random.new(r.x * 73856093 + r.z * 19349663 + r.w * 83492791 + r.d)

	local visited: { { boolean } } = {}
	for cx = 0, cols - 1 do
		visited[cx] = {}
	end

	local stack = { { 0, 0 } }
	visited[0][0] = true
	while #stack > 0 do
		local top = stack[#stack]
		local cx, cz = top[1], top[2]

		local open: { { number } } = {}
		if cx > 0 and not visited[cx - 1][cz] then
			table.insert(open, { cx - 1, cz })
		end
		if cx < cols - 1 and not visited[cx + 1][cz] then
			table.insert(open, { cx + 1, cz })
		end
		if cz > 0 and not visited[cx][cz - 1] then
			table.insert(open, { cx, cz - 1 })
		end
		if cz < rows - 1 and not visited[cx][cz + 1] then
			table.insert(open, { cx, cz + 1 })
		end

		if #open == 0 then
			table.remove(stack)
			continue
		end

		local pick = open[rng:NextInteger(1, #open)]
		local nx, nz = pick[1], pick[2]
		if nx > cx then
			right[cx][cz] = false
		elseif nx < cx then
			right[nx][cz] = false
		elseif nz > cz then
			down[cx][cz] = false
		else
			down[cx][nz] = false
		end
		visited[nx][nz] = true
		table.insert(stack, pick)
	end

	--[[
		Then the dead ends are opened out, so the maze can be run.

		A depth-first carve produces a perfect maze: exactly one route between
		any two cells, and every wrong turn a dead end you have to reverse out
		of. That is a fine puzzle and a bad lawn. Clearing one means visiting
		every corridor, and in a perfect maze that is retracing your steps over
		and over — reported as having to leave the maze and come back in by
		another way to reach the rest of it.

		Braiding is the usual answer: find every cell with only one way out and
		open a second. What is left has no dead ends at all, so every corridor
		is part of a loop and the whole section can be walked in a continuous
		run without doubling back.
	]]
	local function openSides(cx: number, cz: number): ({ { number } }, number)
		local shut, open = {}, 0
		local function look(isOpen: boolean, kind: string, ax: number, az: number)
			if isOpen then
				open += 1
			else
				table.insert(shut, { if kind == "down" then 0 else 1, ax, az })
			end
		end
		if cz > 0 then
			look(not down[cx][cz - 1], "down", cx, cz - 1)
		end
		if cz < rows - 1 then
			look(not down[cx][cz], "down", cx, cz)
		end
		if cx > 0 then
			look(not right[cx - 1][cz], "right", cx - 1, cz)
		end
		if cx < cols - 1 then
			look(not right[cx][cz], "right", cx, cz)
		end
		return shut, open
	end

	for cz = 0, rows - 1 do
		for cx = 0, cols - 1 do
			local shut, open = openSides(cx, cz)
			if open <= 1 and #shut > 0 then
				local pick = shut[rng:NextInteger(1, #shut)]
				if pick[1] == 0 then
					down[pick[2]][pick[3]] = false
				else
					right[pick[2]][pick[3]] = false
				end
			end
		end
	end

	--- One way in on each side, so the maze is not a sealed box to look at.
	down[rng:NextInteger(0, cols - 1)][-1] = false
	down[rng:NextInteger(0, cols - 1)][rows - 1] = false
	right[-1][rng:NextInteger(0, rows - 1)] = false
	right[cols - 1][rng:NextInteger(0, rows - 1)] = false

	--[[
		One hedge per tile rather than one per wall.

		A three-tile wall could be a single stretched part, but a `SpecialMesh`
		stretches its texture with it, so a long hedge comes out smeared. Tile
		by tile it repeats instead, which is what a clipped hedge does.
	]]
	local function hedge(tx: number, tz: number)
		if tx < r.x or tx >= r.x + r.w or tz < r.z or tz >= r.z + r.d then
			return
		end
		--[[
			A hedge is clipped square and corn is not.

			The hedge is grown a touch wider than its tile and slightly
			flattened, because a clipped hedge is a wall with a face. Corn
			stands in a round clump and every plant leans its own way, so it
			takes the tile square and a turn of its own — without the turn a
			corridor is the same plant printed forty times down its length,
			which reads as wallpaper rather than as a crop.
		]]
		local square = grown.spin == true
		local spin = if square then context.rng:NextNumber(0, math.pi * 2) else 0
		--[[
			No two neighbours exactly the same height.

			A hedge tile is grown a stud wider than its tile so the run reads
			as one wall rather than as beads on a string, which means every
			pair of neighbours overlaps by a stud — and at the same height
			their top faces are one plane inside that overlap. The whole top
			of every run in both mazes was two surfaces fighting for the same
			depth. A quarter of a stud of stagger, taken from where the tile
			is so it is the same on every server, is under what anybody would
			call a ragged hedge and over what the depth buffer can confuse.
		]]
		local stagger = (((tx * 7 + tz * 13) % 5) - 2) * 0.12
		local tall = wallHeight + stagger
		local part = Build.mesh({
			prop = grown.prop,
			name = grown.prop,
			size = if square
				then Vector3.new(tile + 1, tall, tile + 1)
				else Vector3.new(tile + 1, tall, tile * 0.9 + 1),
			--[[
				A turned tile sweeps a wider footprint than a square one.

				Collision turns with the part, so a four-by-three-and-a-half
				box at forty-five degrees reaches five and a half studs corner
				to corner. Left at the hedge's size that quietly narrowed every
				corridor and, because the buried-tile sweep clears whatever a
				solid thing stands over, cut a third of the section's work away
				with it — two thousand one hundred sown tiles down to one
				thousand three hundred. Pulled in to four fifths of a tile, a
				turned stalk covers about what an unturned hedge did, and you
				brush through the edge of the crop rather than the corridor
				being smaller than it looks.
			]]
			collisionSize = if square
				then Vector3.new(tile * 0.8, tall, tile * 0.8)
				else Vector3.new(tile, tall, tile * 0.9),
			cframe = CFrame.new(context.flat(tx, tz) + Vector3.new(0, tall * 0.5, 0))
				* CFrame.Angles(0, spin, 0),
			color = tint,
			parent = folder,
		})

		--[[
			Darkened on purpose, which a tint alone cannot do.

			`Build.mesh` normalises a tint to its brightest channel so that
			asking for a colour moves the hue and leaves the texture's own
			light and shade alone — right for a roof, wrong for yew, whose
			whole character is that it is nearly black. Normalised, the
			estate's maze came out the same bright garden green as The
			House's. Scaled to four fifths of the texture's brightness in the
			colour's strongest channel instead, it goes dark without going
			grey.
		]]
		local mesh = if tint and grown.shade then part:FindFirstChildOfClass("SpecialMesh") else nil
		if tint and grown.shade and mesh and mesh.TextureId ~= "" then
			local shade = tint :: Color3
			local strongest = math.max(shade.R, shade.G, shade.B, 0.001)
			mesh.VertexColor = Vector3.new(shade.R, shade.G, shade.B) * (YEW_BRIGHTNESS / strongest)
		end
	end

	for cx = -1, cols - 1 do
		for cz = -1, rows - 1 do
			-- The post where four walls could meet, which always stands.
			hedge(r.x + (cx + 1) * PITCH, r.z + (cz + 1) * PITCH)
			if cz >= 0 and cx >= 0 and down[cx][cz] then
				local tz = r.z + (cz + 1) * PITCH
				for step = 1, PITCH - 1 do
					hedge(r.x + cx * PITCH + step, tz)
				end
			end
			if cx >= 0 and cz >= 0 and right[cx][cz] then
				local tx = r.x + (cx + 1) * PITCH
				for step = 1, PITCH - 1 do
					hedge(tx, r.z + cz * PITCH + step)
				end
			end
		end
	end

	-- The two outer edges the loop above indexes from the other side.
	for cx = 0, cols - 1 do
		if down[cx][-1] then
			for step = 1, PITCH - 1 do
				hedge(r.x + cx * PITCH + step, r.z)
			end
		end
	end
	for cz = 0, rows - 1 do
		if right[-1][cz] then
			for step = 1, PITCH - 1 do
				hedge(r.x, r.z + cz * PITCH + step)
			end
		end
	end

	--[[
		Somebody standing in the corridor who is not going to move.

		Built rather than found: a scarecrow is a cross of two sticks with a
		sack on it, which is four parts and a hat, and nothing in the
		catalogue is one. It stands in the middle of a cell, so a player comes
		round a corner into it — a corridor is twelve studs across and this is
		two, so it is in the way of your eye and not of your mower.

		The eyes are the whole point. Two chips of neon in a sack head, lit
		just enough to carry down a dark row, is the difference between a
		scarecrow and a scare.
	]]
	local sentinels = grown.sentinels or 0
	if sentinels > 0 and cols > 0 and rows > 0 then
		local placed: { [string]: boolean } = {}
		for _ = 1, sentinels do
			local cx, cz
			for _ = 1, 20 do
				cx, cz = rng:NextInteger(0, cols - 1), rng:NextInteger(0, rows - 1)
				if not placed[`{cx},{cz}`] then
					break
				end
			end
			placed[`{cx},{cz}`] = true
			local tx = r.x + cx * PITCH + 2
			local tz = r.z + cz * PITCH + 2
			if tx < r.x + r.w and tz < r.z + r.d then
				local foot = context.flat(tx, tz) + Vector3.new(0, zone.elevation or 0, 0)
				local turn = CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
				local basis = CFrame.new(foot) * turn
				local POST = 12
				Build.part({
					name = "ScarecrowPost",
					size = Vector3.new(0.8, POST, 0.8),
					cframe = basis * CFrame.new(0, POST * 0.5, 0),
					color = Color3.fromRGB(64, 48, 34),
					material = Enum.Material.Wood,
					parent = folder,
				})
				Build.part({
					name = "ScarecrowArms",
					size = Vector3.new(10, 0.7, 0.7),
					cframe = basis * CFrame.new(0, POST - 3.4, 0),
					color = Color3.fromRGB(64, 48, 34),
					material = Enum.Material.Wood,
					canCollide = false,
					parent = folder,
				})
				Build.part({
					name = "ScarecrowBody",
					size = Vector3.new(3.6, 5, 2.4),
					cframe = basis * CFrame.new(0, POST - 4.4, 0),
					color = Color3.fromRGB(150, 128, 84),
					material = Enum.Material.Fabric,
					canCollide = false,
					parent = folder,
				})
				local head = Build.part({
					name = "ScarecrowHead",
					size = Vector3.new(2.8, 3, 2.6),
					cframe = basis * CFrame.new(0, POST - 0.4, 0),
					color = Color3.fromRGB(164, 142, 96),
					material = Enum.Material.Fabric,
					canCollide = false,
					parent = folder,
				})
				for _, side in { -1, 1 } do
					Build.part({
						name = "ScarecrowEye",
						size = Vector3.new(0.5, 0.5, 0.4),
						cframe = basis * CFrame.new(side * 0.65, POST - 0.1, -1.3),
						color = Color3.fromRGB(255, 140, 30),
						material = Enum.Material.Neon,
						canCollide = false,
						castShadow = false,
						parent = folder,
					})
				end
				local glow = Instance.new("PointLight")
				glow.Color = Color3.fromRGB(255, 150, 50)
				glow.Range = 11
				glow.Brightness = 0.5
				glow.Shadows = false
				glow.Parent = head
				Build.part({
					name = "ScarecrowHat",
					shape = Enum.PartType.Cylinder,
					size = Vector3.new(0.4, 5, 5),
					cframe = basis * CFrame.new(0, POST + 1.2, 0) * CFrame.Angles(0, 0, math.rad(90)),
					color = Color3.fromRGB(44, 36, 28),
					material = Enum.Material.Fabric,
					canCollide = false,
					parent = folder,
				})
				Build.part({
					name = "ScarecrowCrown",
					shape = Enum.PartType.Cylinder,
					size = Vector3.new(2, 3.4, 3.4),
					cframe = basis * CFrame.new(0, POST + 2.4, 0) * CFrame.Angles(0, 0, math.rad(90)),
					color = Color3.fromRGB(44, 36, 28),
					material = Enum.Material.Fabric,
					canCollide = false,
					parent = folder,
				})
			end
		end
	end

	return folder
end

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
	--[[
		The apron is a ring, not a slab under the court.

		It was a rectangle five studs larger than the court in both
		directions, which means it also ran underneath it — with its top face
		three hundredths of a stud below the court's own. Two surfaces that
		close flicker against each other, and this pair did it across the
		whole playing area: ninety-seven of a hundred and twenty sample points
		on the Mansion came back with the apron and the court within four
		hundredths of each other.

		There is no height that fixes it. The apron has to sit above the lawn
		to read as a kerb and below the court to read as an apron, and the
		court is only six hundredths above the lawn to begin with. So it stops
		going under the court: four bars round the outside, which is the only
		part of it that was ever visible.
	]]
	local APRON = 2.5
	for _, bar in {
		{ size = Vector3.new(width + APRON * 2, 0.9, APRON), at = Vector3.new(0, 0, -(depth + APRON) * 0.5) },
		{ size = Vector3.new(width + APRON * 2, 0.9, APRON), at = Vector3.new(0, 0, (depth + APRON) * 0.5) },
		{ size = Vector3.new(APRON, 0.9, depth), at = Vector3.new(-(width + APRON) * 0.5, 0, 0) },
		{ size = Vector3.new(APRON, 0.9, depth), at = Vector3.new((width + APRON) * 0.5, 0, 0) },
	} do
		Build.part({
			name = "CourtApron",
			size = bar.size,
			--[[
				Level with the tarmac, not three hundredths under it.

				The apron used to sit three hundredths above the lawn, which
				is inside the range where the depth test cannot separate two
				surfaces: the sweep caught it flickering against the grass at
				its own outer edge. It cannot go higher without the court
				going higher too, and the court cannot rise without burying
				the leaves lying on it — the fault the note above this is
				about. So it comes up to the court's own height instead. The
				ring never lies over the tarmac, so two surfaces at one height
				here are two surfaces that never meet, and against the lawn it
				now has the same six hundredths the court has always had.
			]]
			cframe = CFrame.new(centre + bar.at + Vector3.new(0, context.groundY - 0.39, 0)),
			color = Palette.color(Palette.court.apron),
			material = Enum.Material.Asphalt,
			parent = folder,
		})
	end

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

	--[[
		The net, across the way the court is played, with a post at each end.

		It picked its axis from whichever side of the section was longer and
		ran the net down that one — so on a court a hundred and four studs
		wide and a hundred and thirty-six deep it laid a hundred and thirty
		studs of net down the length of the court, dividing it end to end
		instead of side to side. Standing at the baseline you looked straight
		along a white tape running away from you to the far fence.

		The lines above have no such choice to make: the baselines are always
		the two z ends and the service line always runs up z, so the court is
		always played up z whatever shape the section is. The net is parallel
		to the baselines, which means it is always across x, and the two now
		agree. A few studs longer than the tramlines it crosses, because a
		net post stands outside the court, not on the line.
	]]
	local netLength = width - inset
	--[[
		Chest high, not head high.

		Five studs is exactly how tall a player is, so anybody standing at
		the net was hidden behind it and the court was divided by a wall
		rather than by a net. A tennis net comes to about the chest of the
		person serving over it.
	]]
	local NET_HEIGHT = 3.4
	Build.part({
		name = "Net",
		size = Vector3.new(netLength, NET_HEIGHT, 0.6),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY + NET_HEIGHT * 0.5, 0)),
		color = Palette.color(Palette.court.net),
		material = Enum.Material.Fabric,
		transparency = 0.35,
		canCollide = false,
		parent = folder,
	})
	Build.part({
		name = "NetTape",
		size = Vector3.new(netLength, 0.8, 0.8),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY + NET_HEIGHT + 0.1, 0)),
		color = Palette.color(Palette.court.line),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = folder,
	})
	for _, side in { -1, 1 } do
		local at = Vector3.new(side * netLength * 0.5, 0, 0)
		Build.part({
			name = "NetPost",
			size = Vector3.new(1.4, NET_HEIGHT + 1.2, 1.4),
			cframe = CFrame.new(centre + at + Vector3.new(0, context.groundY + (NET_HEIGHT + 1.2) * 0.5, 0)),
			color = Palette.color(Palette.estate.iron),
			material = Enum.Material.Metal,
			parent = folder,
		})
	end

	--[[
		The surround: four sides of mesh with one gate in it.

		This was three sides with the fourth left open, on the reasoning that
		a court is somewhere you walk onto rather than a gated section. A
		court with a side missing is not a court — a tennis court is a box,
		and the fence is the single thing that says so from across an estate.

		So it closes all the way round and the way in is a gate. The gate is
		built shut and `Structures.openCourtGate` swings it, which the run
		calls when the section unlocks: the fence reads as a boundary while
		the court is locked, and as a door once it is not.
	]]
	--[[
		Thirteen studs, not twenty.

		Twenty is three and a half people tall — from anywhere above head
		height the four panels closed over the court like a lid, and the shot
		from the terrace looked as though the tennis court had been roofed
		in. Thirteen still cannot be jumped (a Roblox jump tops out around
		seven) and still reads as a cage from outside it.
	]]
	local FENCE_H = 13
	local halfW, halfD = width * 0.5 + 2.5, depth * 0.5 + 2.5
	local GATE = 16

	--- The gate goes in the middle of whichever side is longest, which is the
	--- side an estate this shape is walked at from.
	local gateOnX = width >= depth
	local sides = {
		{ from = Vector3.new(-halfW, 0, -halfD), to = Vector3.new(halfW, 0, -halfD), gate = gateOnX },
		{ from = Vector3.new(-halfW, 0, halfD), to = Vector3.new(halfW, 0, halfD), gate = false },
		{ from = Vector3.new(-halfW, 0, -halfD), to = Vector3.new(-halfW, 0, halfD), gate = not gateOnX },
		{ from = Vector3.new(halfW, 0, -halfD), to = Vector3.new(halfW, 0, halfD), gate = false },
	}

	for _, run in sides do
		local delta = run.to - run.from
		local length = delta.Magnitude
		local along = delta.Unit
		local alongX = math.abs(delta.X) > math.abs(delta.Z)

		--- Where the gate breaks this side, as a stretch along its own length.
		local runs: { { number } } = if run.gate
			then { { 0, (length - GATE) * 0.5 }, { (length + GATE) * 0.5, length } }
			else { { 0, length } }

		for _, span in runs do
			local low, high = span[1], span[2]
			local panel = high - low
			if panel > 0.5 then
				local mid = centre + run.from + along * ((low + high) * 0.5)
				Build.part({
					name = "CourtMesh",
					size = if alongX then Vector3.new(panel, FENCE_H, 0.4) else Vector3.new(0.4, FENCE_H, panel),
					cframe = CFrame.new(mid + Vector3.new(0, context.groundY + FENCE_H * 0.5, 0)),
					color = Palette.color(Palette.court.mesh),
					material = Enum.Material.DiamondPlate,
					transparency = 0.55,
					parent = folder,
				})

				--[[
					Top, middle and bottom rails.

					Chain-link at this scale is a pane of grey haze, and a pane
					of grey haze between two posts reads as a gap: from the
					court the fence was posts with nothing in between, and from
					above the panel's own top edge was the only line in it,
					which is what made four upright panels look like a roof.
					The rails are the part of a fence the eye actually finds.
				]]
				for _, height in { 0.4, FENCE_H * 0.5, FENCE_H } do
					Build.part({
						name = "CourtRail",
						size = if alongX
							then Vector3.new(panel, 0.5, 0.55)
							else Vector3.new(0.55, 0.5, panel),
						cframe = CFrame.new(mid + Vector3.new(0, context.groundY + height, 0)),
						color = Palette.color(Palette.estate.iron),
						material = Enum.Material.Metal,
						canCollide = false,
						parent = folder,
					})
				end
			end
		end

		--[[
			One post per corner, not two.

			Each of the four sides ran a post at both of its own ends, and
			every corner is an end of two sides — so all four corners had two
			identical posts standing in exactly the same place, with their
			caps on one plane. The two that run across take the corners; the
			two that run up and down stop short of them.
		]]
		local posts = math.max(math.floor(length / 22), 1)
		for index = (if alongX then 0 else 1), (if alongX then posts else posts - 1) do
			local at = centre + run.from + along * (length * index / posts)
			Build.part({
				name = "CourtPost",
				size = Vector3.new(1.3, FENCE_H + 1, 1.3),
				cframe = CFrame.new(at + Vector3.new(0, context.groundY + (FENCE_H + 1) * 0.5, 0)),
				color = Palette.color(Palette.estate.iron),
				material = Enum.Material.Metal,
				parent = folder,
			})
		end

		--- The gate itself: two leaves and a post either side of the opening.
		if run.gate then
			for _, side in { -1, 1 } do
				local jamb = centre + run.from + along * ((length + side * GATE) * 0.5)
				Build.part({
					name = "GatePost",
					size = Vector3.new(2, FENCE_H + 3, 2),
					cframe = CFrame.new(jamb + Vector3.new(0, context.groundY + (FENCE_H + 3) * 0.5, 0)),
					color = Palette.color(Palette.estate.iron),
					material = Enum.Material.Metal,
					parent = folder,
				})
				local leafMid = centre
					+ run.from
					+ along * ((length + side * GATE * 0.5) * 0.5)
				local leaf = Build.part({
					name = "CourtGate",
					size = if alongX
						then Vector3.new(GATE * 0.5, FENCE_H, 0.6)
						else Vector3.new(0.6, FENCE_H, GATE * 0.5),
					cframe = CFrame.new(leafMid + Vector3.new(0, context.groundY + FENCE_H * 0.5, 0)),
					color = Palette.color(Palette.estate.iron),
					material = Enum.Material.DiamondPlate,
					transparency = 0.35,
					parent = folder,
				})
				--- Remembered so the gate can be swung about the right jamb.
				leaf:SetAttribute("HingeX", jamb.X)
				leaf:SetAttribute("HingeZ", jamb.Z)
				leaf:SetAttribute("Swing", side * (if alongX then 1 else -1))
			end
		end
	end

	return folder
end

--[[
	Swings a court's gate open, once, when its section unlocks.

	The leaves are hinged on their own jamb rather than slid aside, because a
	gate that vanishes is a hole and a gate that swings is a gate — and the
	swing is the only part of a fence anybody actually watches.
]]
function Structures.openCourtGate(container: Instance, sectionId: string)
	local folder = container:FindFirstChild(`Court_{sectionId}`)
	if not folder then
		return
	end
	for _, leaf in folder:GetChildren() do
		if leaf:IsA("BasePart") and leaf.Name == "CourtGate" and not leaf:GetAttribute("Open") then
			leaf:SetAttribute("Open", true)
			local hinge = Vector3.new(
				leaf:GetAttribute("HingeX") :: number,
				leaf.Position.Y,
				leaf:GetAttribute("HingeZ") :: number
			)
			local swing = (leaf:GetAttribute("Swing") :: number) or 1
			local turned = CFrame.new(hinge)
				* CFrame.Angles(0, math.rad(-100 * swing), 0)
				* CFrame.new(hinge):Inverse()
				* leaf.CFrame
			TweenService:Create(leaf, TweenInfo.new(1.1, Enum.EasingStyle.Quad), { CFrame = turned }):Play()
			-- Nothing to walk into once it has swung out of the way.
			task.delay(1.1, function()
				if leaf.Parent then
					leaf.CanCollide = false
				end
			end)
		end
	end
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

	--[[
		A balustrade all the way round, broken where the steps come up.

		In the estate's own pale stone. The parapet builder defaults to The
		House's trim, because a rooftop parapet on that house is that colour —
		and the note on that line calls it the single most identifying colour
		in the property. Left to the default, the whole length of the mansion's
		terrace rail came out teal between cream stone balusters.
	]]
	Structures.parapet(context, zone, 1, opening, Palette.color(Palette.estate.quoin))
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
		--- The two that run across sit six hundredths lower, so where they
		--- cross at a corner one of them wins instead of both fighting.
		local drop = if alongX then 0 else 0.06
		Build.part({
			name = "BalustradeRail",
			size = if alongX then Vector3.new(length, 1, 2.4) else Vector3.new(2.4, 1, length),
			cframe = CFrame.new(
				centre + run.from + delta * 0.5 + Vector3.new(0, context.groundY + lift + 5.2 - drop, 0)
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

	--- Proud of the lawn by the same hair a room's floor is, and for the same
	--- reason: two surfaces at one height flicker against each other.
	Build.part({
		name = "Floor",
		size = Vector3.new(width + 4, 2, depth + 4),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY - 1 + FLOOR_LIFT, 0)),
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
		castShadow = false,
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

	--[[
		Eaves, and the lantern along the ridge.

		Four beams round the edge, not one slab across the middle. This was
		built as a single part the full footprint plus eight — an opaque iron
		lid laid over a glazed roof, so the one building on the estate you are
		supposed to be able to see into was a black rectangle from anywhere
		above eye level, and the glass roof under it was never visible at all.
		A cornice is a frame; what goes between it is the glass.
	]]
	local EAVE = 4
	for _, beam in {
		{ size = Vector3.new(width + EAVE * 2, 1.6, EAVE), at = Vector3.new(0, 0, -(depth + EAVE) * 0.5) },
		{ size = Vector3.new(width + EAVE * 2, 1.6, EAVE), at = Vector3.new(0, 0, (depth + EAVE) * 0.5) },
		--- Butted, not crossed: two beams overlapping at a corner put two
		--- faces of iron on the same plane and the corner flickers.
		{ size = Vector3.new(EAVE, 1.6, depth), at = Vector3.new(-(width + EAVE) * 0.5, 0, 0) },
		{ size = Vector3.new(EAVE, 1.6, depth), at = Vector3.new((width + EAVE) * 0.5, 0, 0) },
	} do
		Build.part({
			name = "Eaves",
			size = beam.size,
			cframe = CFrame.new(centre + beam.at + Vector3.new(0, context.groundY + HEIGHT, 0)),
			color = Palette.color(Palette.estate.iron),
			material = Enum.Material.Metal,
			parent = folder,
		})
	end
	Build.part({
		name = "Glasshouse",
		size = Vector3.new(width, 1, depth),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY + HEIGHT + 1.3, 0)),
		color = Palette.color(Palette.estate.glass),
		material = Enum.Material.SmoothPlastic,
		transparency = 0.72,
		--[[
			Glass does not throw a shadow, and here it was throwing the only
			one that mattered. Roblox shades a translucent part exactly as it
			shades a brick, so the roof of the glasshouse put the whole floor
			of it in the dark: a building whose entire purpose is that the sun
			gets in, and the one section on the property you could not see the
			debris in.
		]]
		castShadow = false,
		parent = folder,
	})
	--[[
		Glazing bars across the roof.

		The pane above is glass at nearly three quarters transparent, which
		is right — the whole point of the building is that the sun gets in —
		and the consequence is that from underneath there is nothing there at
		all. Standing on the floor and looking up you saw an open box with
		the lantern's iron cap hanging in the sky over it and no roof joining
		the two. A glasshouse roof is mostly bars, and from below the bars
		are the only part of it you were ever going to see.

		Across the short way and repeated down the long one, which is how a
		span is actually framed, and no shadow: a grid of shadows on a floor
		you are meant to be able to find leaves on is the same mistake the
		roof pane itself already made.
	]]
	local ribsAlongX = width <= depth
	local ribSpan = if ribsAlongX then depth else width
	local ribs = math.max(math.floor(ribSpan / 10), 1)
	for index = 0, ribs do
		local slide = -ribSpan * 0.5 + ribSpan * index / ribs
		Build.part({
			name = "GlazingBar",
			size = if ribsAlongX
				then Vector3.new(width + EAVE * 2, 0.9, 0.9)
				else Vector3.new(0.9, 0.9, depth + EAVE * 2),
			cframe = CFrame.new(
				centre
					+ (if ribsAlongX then Vector3.new(0, 0, slide) else Vector3.new(slide, 0, 0))
					+ Vector3.new(0, context.groundY + HEIGHT + 1.9, 0)
			),
			color = Palette.color(Palette.estate.iron),
			material = Enum.Material.Metal,
			canCollide = false,
			castShadow = false,
			parent = folder,
		})
	end

	local ridgeAlongX = width >= depth
	Build.part({
		name = "Lantern",
		size = if ridgeAlongX then Vector3.new(width * 0.55, 6, 14) else Vector3.new(14, 6, depth * 0.55),
		cframe = CFrame.new(centre + Vector3.new(0, context.groundY + HEIGHT + 4.3, 0)),
		color = Palette.color(Palette.estate.glass),
		material = Enum.Material.SmoothPlastic,
		transparency = 0.62,
		castShadow = false,
		parent = folder,
	})
	--- Uprights down the lantern's sides, so six studs of glass between two
	--- iron slabs reads as a raised light and not as a gap in the roof.
	local lanternRun = if ridgeAlongX then width * 0.55 else depth * 0.55
	local lanternPosts = math.max(math.floor(lanternRun / 11), 1)
	for index = 0, lanternPosts do
		local slide = -lanternRun * 0.5 + lanternRun * index / lanternPosts
		for _, side in { -1, 1 } do
			Build.part({
				name = "LanternPost",
				size = Vector3.new(0.9, 6, 0.9),
				cframe = CFrame.new(
					centre
						+ (if ridgeAlongX
							then Vector3.new(slide, 0, side * 7)
							else Vector3.new(side * 7, 0, slide))
						+ Vector3.new(0, context.groundY + HEIGHT + 4.3, 0)
				),
				color = Palette.color(Palette.estate.iron),
				material = Enum.Material.Metal,
				canCollide = false,
				castShadow = false,
				parent = folder,
			})
		end
	end
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
