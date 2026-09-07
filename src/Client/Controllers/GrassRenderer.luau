--!strict
--[[
	GrassRenderer — draws the tile buffer.

	The client holds its own copy of the world's tile bytes and renders only a
	window of it: detail inside DETAIL_RADIUS, a single flat plane per chunk out
	to LOD_RADIUS, nothing beyond. Parts come from a pool and are recycled,
	because churning thousands of Instances is what actually costs frames.

	Debris is not drawn the same way for every type. Grass is a block whose
	height falls as it is mown, which is what makes an upgrade visible. Leaves
	are scattered flat sprites — a drift of separate leaves rather than a slab —
	because that is the entire visual signature of the genre, and one solid
	coloured block reads nothing like it.

	Scatter is derived from a hash of the tile index, so a given leaf sits in the
	same spot at the same angle every frame instead of shimmering as the window
	moves.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkCodec = require(Shared.ChunkCodec)
local DebrisConfig = require(Shared.Config.Debris)
local GameConfig = require(Shared.Config.GameConfig)
local Grid = require(Shared.Grid)
local Palette = require(Shared.Config.Palette)
local Props = require(Shared.Config.Props)
local Worlds = require(Shared.Config.Worlds)
local Remotes = require(Shared.Remotes)

local GrassRenderer = {}

local TILE = GameConfig.TILE_SIZE
local HEIGHT_STUD = GameConfig.HEIGHT_STUD

--- Leaves drawn per height level on a tile.
local LEAVES_PER_LEVEL = 4
--- Cap, so a deep drift never explodes the part budget.
local MAX_LEAVES_PER_TILE = 10

local grid: Grid.Grid? = nil
local tiles: buffer? = nil
local container: Folder? = nil
local detailFolder: Folder? = nil
local lodFolder: Folder? = nil

--- Tile index -> the parts currently drawing it.
local active: { [number]: { Part } } = {}
--- Blocks and leaves are shaped differently, so they cannot share a pool:
--- handing a leaf's mesh to a grass block would leave an ellipse on the lawn.
local blockPool: { Part } = {}
local leafPool: { Part } = {}
--- Whether the parts currently drawing a tile are leaves.
local activeIsLeaf: { [number]: boolean } = {}
local lodParts: { [number]: Part } = {}
local known: { [number]: boolean } = {}
--[[
	When each chunk was last asked for.

	This was a plain "have we asked?" flag, set the first time a chunk came
	into range and never cleared, so a request that went out and never came
	back left a hole in the world for the rest of the run — the client would
	not ask twice. On The Mansion that was not a rare packet either: better
	than a third of the property arrived as bare ground you could walk across
	and never clear, because the tiles were on the server and the client had
	simply given up asking. Asking again after a few seconds costs one number
	per missing chunk and closes the hole.
]]
local requestedAt: { [number]: number } = {}

--- How long to wait for a chunk before asking for it again.
local REQUEST_RETRY_SECONDS = 3

--- Chunks asked for in one pass, so a world that has just loaded does not send
--- its entire grid in a single packet.
local REQUEST_BATCH = 256
local openSections: { [string]: boolean } = {}
local tileSection: { string } = {}

--[[
	The colours the distance is painted in, for the world now loaded.

	A chunk seen from far off is one flat slab, and what it should look like is
	the ground of this particular lot: green on the two lawns, dark stone on the
	Gas Station. Taking it from the grass palette instead laid a green rectangle
	over the stone yard, which is the same mistake as painting a leafy chunk
	gold, one world along. Both are worked out once per load from the world's
	own `baseGround`.
]]
local groundColor = Palette.color(Palette.ground.lawn)

--[[
	The same blend again, for the surfaces inside a world that are not its
	ground.

	The rule above is right and was applied one level too coarsely: it takes
	the world's `baseGround`, and a world is not all one surface. The House's
	Rooftop is a slab of brown slate twenty-nine studs up and its Basement is
	a stone floor eighteen studs down, and both are filled with leaves — so
	both were carpeted in a colour worked out from the lawn. Standing anywhere
	on the property, the house had a bright green lawn on its roof, and the
	one thing the drift colour exists to tell you from a distance — that there
	is litter up there worth going up for — it said in the colour of grass.

	Keyed by section kind, because that is what decides the surface: a roof is
	roofing, a room has the stone floor every room in the game is built with,
	and everything else is standing on the lot.
]]
local surfaceByKind: { [string]: Color3 } = {}
--- One colour per section for what is lying on it, so a chunk never picks its
--- own and a section never comes out as a patchwork.
local litterBySection: { [string]: Color3 } = {}
--- The tallest a tile can be, which is all `ChunkCodec` has room to say.
local MAX_TILE_HEIGHT = 3

--[[
	How much of the floor a kind of debris actually hides, per unit of height.

	A leaf drift lies flat and covers what it lands on; a clump of weeds is a
	tall thing with floor all round it, and a scatter of branches is mostly
	gaps. Height is not coverage, and treating it as though it were painted
	the east terrace as a solid sheet of tan when what is on it is pale
	flagstones with green through the joints.
]]
local COVERAGE: { [number]: number } = {
	--[[
		Measured against the detailed half of the tennis court, which is the
		one place in the game you can see both halves of this decision in a
		single shot. At 0.95 the far half was drawn about half again as
		covered as the near half — the court went from dark blue with leaves
		on it to a solid warm tan across the streaming boundary. A leaf clump
		covers most of its own tile and not all of it.
	]]
	[DebrisConfig.Leaves] = 0.72,
	[DebrisConfig.Chips] = 0.85,
	[DebrisConfig.Hedge] = 0.70,
	[DebrisConfig.Grass] = 0.62,
	[DebrisConfig.Weeds] = 0.62,
	[DebrisConfig.Log] = 0.40,
	[DebrisConfig.Sticks] = 0.35,
}
local DEFAULT_COVERAGE = 0.6

--[[
	How solid the stand-in is drawn, from how much it covers.

	Not the coverage itself. Read literally, a lot sown with scattered weeds
	is nine tenths bare floor, and nine tenths transparent is invisible: the
	Gas Station's whole forecourt came out as clean grey concrete from the
	back of the lot while every tile of it was still full, which is a worse
	lie than the flat sheet this replaced. The plane is a stand-in for
	something you cannot draw at that range, and it has to be seen.

	So a floor is never less than a quarter covered while anything is left on
	it, and coverage decides the rest.
]]
local LOD_FLOOR = 0.25
local LOD_RANGE = 0.68

--- How much of its floor each section's own mix hides, by the same reasoning.
local coverBySection: { [string]: number } = {}
--- False on a lot floored with something other than grass, which changes what
--- has to be drawn at distance and what can be left to the ground.
local groundIsLawn = true
local tileKind: { string } = {}
local tileElevation: { number } = {}

local requestChunks: RemoteEvent
local chunkDelta: RemoteEvent
local worldInfo: RemoteEvent

local DETAIL_SQ = GameConfig.DETAIL_RADIUS * GameConfig.DETAIL_RADIUS
local LOD_SQ = GameConfig.LOD_RADIUS * GameConfig.LOD_RADIUS

--------------------------------------------------------------------
-- Deterministic scatter
--------------------------------------------------------------------

--[[
	A stable pseudo-random number in [0, 1) from a tile index and a salt.

	Deterministic on purpose: leaves must sit still. Seeding from a real RNG
	would re-scatter the whole drift every time the render window moved.
]]
local function hash01(index: number, salt: number): number
	local n = index * 73856093 + salt * 19349663
	n = bit32.bxor(n, bit32.rshift(n, 13))
	n = (n * 1274126177) % 4294967296
	return (n % 65536) / 65536
end

--------------------------------------------------------------------
-- Part pool
--------------------------------------------------------------------

local function newPart(leaf: boolean): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	if leaf then
		--[[
			A leaf is a leaf, not a box and not a squashed ball.

			These were built-in shapes — a sphere for the rounded sort and a
			prism for the pointed one — because they cost no asset. At the
			density a drift is drawn they read as a gravel of orange pebbles.
			They are models now, the same one part per leaf as before.
		]]
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.Name = "Blade"
		mesh.Parent = part
	else
		--[[
			A tile of grass is a clump of grass, not a cube of it.

			Every uncut tile used to be one four-by-four box as tall as the
			grass on it, which is why a property read as a chequerboard of
			coloured squares from any distance — hundreds of them, edge to
			edge, over the whole lawn. It is the same one part per tile as
			before, so the budget and the pooling are unchanged; the part just
			carries a model of a clump instead of being a box.
		]]
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.Name = "Clump"
		mesh.Parent = part
	end

	return part
end

--[[
	The stand-in for a whole chunk seen from far off.

	It carries no model at all, unlike the near tiles, and that is the point.
	It used to be a lawn panel — a three stud square of turf — scaled to a
	thirty-two stud chunk, which is nine times its own size, so its weave came
	out as bands several studs wide. Every chunk stretched the same panel the
	same way, so the bands lined up across chunk boundaries and the whole
	middle distance of every property was striped like a ploughed field. It was
	the same mistake as the ground under it, one layer up.

	A plain slab in the lawn's own colour and material has nothing to magnify,
	and meets the ground it sits on without a seam.

	Kept out of the pools the near tiles share, because those parts carry a
	`SpecialMesh` and one with no id set renders as nothing at all — which is
	how the far half of a property once came to be a hole.
]]
local function newLodPart(): Part
	local part = Instance.new("Part")
	part.Name = "Lod"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function poolFor(leaf: boolean): { Part }
	return if leaf then leafPool else blockPool
end

local function acquire(leaf: boolean): Part
	local part = table.remove(poolFor(leaf))
	if part then
		return part
	end
	return newPart(leaf)
end

local function recycle(part: Part, leaf: boolean)
	part.Parent = nil
	local target = poolFor(leaf)
	if #target < GameConfig.MAX_TILE_PARTS then
		table.insert(target, part)
	else
		part:Destroy()
	end
end

local function release(index: number)
	local parts = active[index]
	if not parts then
		return
	end
	local leaf = activeIsLeaf[index] == true
	active[index] = nil
	activeIsLeaf[index] = nil
	for _, part in parts do
		recycle(part, leaf)
	end
end

--- Resizes a tile's part list to exactly `count`, reusing what is already there.
local function slots(index: number, count: number, leaf: boolean): { Part }
	-- A tile that changed shape has to give its parts back to the right pool.
	if active[index] and activeIsLeaf[index] ~= leaf then
		release(index)
	end

	local parts = active[index]
	if not parts then
		parts = {}
		active[index] = parts
		activeIsLeaf[index] = leaf
	end

	while #parts > count do
		local part = table.remove(parts)
		if part then
			recycle(part, leaf)
		end
	end
	while #parts < count do
		table.insert(parts, acquire(leaf))
	end

	return parts
end

--------------------------------------------------------------------
-- Zones
--------------------------------------------------------------------

local function buildZoneMap(worldId: string, theGrid: Grid.Grid)
	table.clear(tileSection)
	table.clear(tileElevation)
	table.clear(tileKind)
	table.clear(surfaceByKind)
	local world = Worlds.get(worldId)
	if not world then
		return
	end
	local ground = world.baseGround
	groundColor = Color3.new(ground[1], ground[2], ground[3])

	--[[
		Whether this property's ground is a lawn, which decides the whole rule
		below.

		Grass seen from far enough away is the ground it grows on, so on a
		lawn a chunk of uncut grass needs nothing drawn for it — that is why
		only leaves ever got a stand-in. On The Gas Station the ground is
		stone, and a forecourt thick with weeds is not stone: past the detail
		radius the weeds simply stopped being drawn and the lot came out as a
		vast empty slab of concrete with a band of green around the player.
		The same complaint as the tennis court, one property along, and the
		same cause — a rule written for grass on grass, applied to everything.
	]]
	local lawn = Palette.color(Palette.ground.lawn)
	groundIsLawn = math.abs(groundColor.R - lawn.R)
			+ math.abs(groundColor.G - lawn.G)
			+ math.abs(groundColor.B - lawn.B)
		< 0.03

	--[[
		The surface each kind of section is floored with, unblended.

		`WorldService` lays a roof deck in `house.roof`, every room floor in
		`ground.stoneDark`, a court in tarmac and a terrace in estate stone.
		Anything not listed stands on the lot itself.
	]]
	surfaceByKind.roof = Palette.color(Palette.house.roof)
	surfaceByKind.room = Palette.color(Palette.ground.stoneDark)
	surfaceByKind.court = Palette.color(Palette.court.tarmac)
	surfaceByKind.terrace = Palette.color(Palette.estate.stone)
	surfaceByKind.glasshouse = surfaceByKind.room

	--[[
		One litter colour for a whole section, taken from what it is sown
		with rather than from what happens to be left in each chunk.

		Colouring a chunk by whichever debris weighs most *in that chunk* puts
		the chequerboard back: the east terrace is sown with grass, leaves and
		branches, so each thirty-two stud square picked a different winner and
		the terrace came out as a patchwork of green, tan and olive rectangles
		— the exact fault the original leaves-only rule existed to avoid. You
		cannot tell a branch from a weed at that range, and pretending to is
		only a way of drawing tile edges.

		What the whole section is sown with, averaged, is the honest answer
		and it does not change from square to square — so a terrace reads as
		one terrace and a forecourt as one forecourt.

		Averaged rather than won outright. Taking only the heaviest entry is
		the same mistake one step up: the east terrace is sown grass, leaves
		and sticks, leaves win on weight, and the terrace was drawn in flat
		gold — while standing on it you are looking at pale flagstones with
		green weeds through the joints and brown branches across them. The
		near half of the section and the far half were two different places.

		Each entry counts for its weight times how tall it is sown, because a
		tall weed covers more of the floor than a leaf does, and that is what
		you can see from two hundred studs away.
	]]
	table.clear(litterBySection)
	table.clear(coverBySection)
	for _, section in world.sections do
		local red, green, blue, total = 0, 0, 0, 0
		local hides, weights = 0, 0
		for _, entry in section.fill do
			local colour = if entry.debris == DebrisConfig.Leaves
				then Palette.color(Palette.leafAverage)
				else Palette.color(DebrisConfig.get(entry.debris).color)
			local mass = entry.weight * (entry.heightMin + entry.heightMax) * 0.5
			red += colour.R * mass
			green += colour.G * mass
			blue += colour.B * mass
			total += mass
			hides += (COVERAGE[entry.debris] or DEFAULT_COVERAGE) * entry.weight
			weights += entry.weight
		end
		if total > 0 then
			litterBySection[section.id] = Color3.new(red / total, green / total, blue / total)
		end
		if weights > 0 then
			coverBySection[section.id] = hides / weights
		end
	end

	for _, section in world.sections do
		local r = section.rect
		local elevation = section.elevation or 0
		for tz = r.z, math.min(r.z + r.d - 1, theGrid.depth - 1) do
			for tx = r.x, math.min(r.x + r.w - 1, theGrid.width - 1) do
				local index = Grid.toIndex(theGrid, tx, tz)
				tileSection[index] = section.id
				tileElevation[index] = elevation
				tileKind[index] = section.kind or ""
			end
		end
	end
end

local function isLocked(index: number): boolean
	local sectionId = tileSection[index]
	if not sectionId then
		return false
	end
	return not openSections[sectionId]
end

--------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------

local function desaturate(color: Color3): Color3
	local grey = (color.R + color.G + color.B) / 3
	return color:Lerp(Color3.new(grey, grey, grey), 0.6)
end

local function baseColor(debrisId: number, index: number): Color3
	if debrisId == DebrisConfig.Leaves then
		return Palette.color(Palette.leaves[(index % #Palette.leaves) + 1])
	elseif debrisId == DebrisConfig.Grass then
		return Palette.color(if index % 3 == 0 then Palette.grass.bladeDark else Palette.grass.blade)
	elseif debrisId == DebrisConfig.Weeds then
		return Palette.color(Palette.weeds)
	elseif debrisId == DebrisConfig.Hedge then
		return Palette.color(Palette.hedge)
	elseif debrisId == DebrisConfig.Sticks then
		return Palette.color(Palette.sticks)
	end
	local def = DebrisConfig.get(debrisId)
	return Color3.new(def.color[1], def.color[2], def.color[3])
end

--[[
	A drift of separate leaves lying flat on the ground.

	Each leaf gets its own shape, angle, tilt, size and shade. The tilt matters
	more than it sounds: leaves lying at slightly different pitches catch the low
	sun differently and overlap unevenly, which is what turns a dense scatter
	into a carpet of individual leaves rather than a painted floor.
]]
--- The two leaf models, picked between per leaf so a drift never tiles.
local LEAF_SHAPES: { Props.Prop } = { Props.catalogue.LeafMaple, Props.catalogue.LeafOak }

--[[
	Lays a leaf model flat and works out the scale that gets it there.

	A leaf model is a card: two big axes and one thin one. Which axis is thin
	depends on how the model was authored, and the two in the catalogue happen
	to disagree, so rather than carry that per-asset the thin axis is simply the
	smallest of the three. The mesh is then turned until that axis points up and
	scaled so the two big ones cover the wanted footprint.

	Returns the scale for the mesh and the extra rotation for the part.
]]
local function layFlat(def: Props.Prop, width: number, thickness: number, length: number): (Vector3, CFrame)
	local native = def.native
	if native.Z <= native.X and native.Z <= native.Y then
		-- Standing card: tip it back so its face points at the sky.
		return Vector3.new(width / native.X, length / native.Y, thickness / native.Z),
			CFrame.Angles(-math.pi * 0.5, 0, 0)
	elseif native.X <= native.Y and native.X <= native.Z then
		-- On its edge: stand it down sideways.
		return Vector3.new(thickness / native.X, width / native.Y, length / native.Z),
			CFrame.Angles(0, 0, math.pi * 0.5)
	end
	-- Already lying down.
	return Vector3.new(width / native.X, thickness / native.Y, length / native.Z), CFrame.identity
end

local function drawLeaves(index: number, wx: number, wz: number, floor: number, height: number, locked: boolean)
	local count = math.min(height * LEAVES_PER_LEVEL, MAX_LEAVES_PER_TILE)
	local parts = slots(index, count, true)

	for slot, part in parts do
		local offsetX = (hash01(index, slot * 5 + 1) - 0.5) * (TILE + 0.6)
		local offsetZ = (hash01(index, slot * 5 + 2) - 0.5) * (TILE + 0.6)
		local yaw = hash01(index, slot * 5 + 3) * math.pi * 2
		local scale = 0.78 + hash01(index, slot * 5 + 4) * 0.5
		local shapeRoll = hash01(index, slot * 5 + 5)
		local layer = (slot - 1) // LEAVES_PER_LEVEL

		-- A few degrees of pitch and roll, so they never lie perfectly flush.
		local pitch = (hash01(index, slot * 11 + 1) - 0.5) * 0.34
		local roll = (hash01(index, slot * 11 + 2) - 0.5) * 0.34

		-- Roughly a third are the pointed maple sort, the rest the oak.
		local def = if shapeRoll < 0.34 then LEAF_SHAPES[1] else LEAF_SHAPES[2]
		--[[
			A leaf, at the size a leaf is.

			These were three studs across. A player is five studs tall, so
			every leaf on the lawn was the size of a dinner plate, and eight
			of them on a four stud tile covered it three times over — which
			is why a drift read as a sheet of red paint rather than as
			leaves. At this size they overlap about once, which is what a
			real drift does.
		]]
		local width, thickness, length = 1.55 * scale, 0.16, 1.15 * scale
		local meshScale, lie = layFlat(def, width, thickness, length)

		local mesh = part:FindFirstChild("Blade")
		if mesh and mesh:IsA("SpecialMesh") then
			if mesh.MeshId ~= def.mesh then
				mesh.MeshId = def.mesh
			end
			--[[
				No texture on a leaf, on purpose.

				Both leaf models are painted red in their own texture, and a
				texture is what a mesh shows: the nine autumn shades the
				drift is supposed to be drawn from were being multiplied into
				a red that was already red, so every leaf in the game came
				out the same fire red whichever shade it had been given. A
				leaf is one flat colour anyway, and an untextured mesh takes
				the colour of the part under it, so dropping the texture is
				what actually gets the palette onto the lawn.
			]]
			mesh.TextureId = ""
			mesh.VertexColor = Vector3.one
			mesh.Scale = meshScale
		end

		local palette = Palette.leaves
		local color = Palette.color(palette[((index * 7 + slot * 3) % #palette) + 1])
		-- One in seven lands pale side up.
		if hash01(index, slot * 13) > 0.86 then
			color = Palette.color(Palette.leafPale)
		end
		if locked then
			color = desaturate(color)
		end

		part.Size = Vector3.new(width, thickness, length)
		-- Yaw in the world, then lie down and take on the tilt, so the couple of
		-- degrees of pitch and roll stay small however the model was authored.
		part.CFrame = CFrame.new(wx + offsetX, floor + 0.09 + layer * 0.07, wz + offsetZ)
			* CFrame.Angles(0, yaw, 0)
			* lie
			* CFrame.Angles(pitch, 0, roll)
		part.Color = color
		part.Material = Enum.Material.SmoothPlastic
		part.Transparency = 0
		part.Parent = detailFolder
	end
end

--[[
	Grass, weeds, hedges and sticks, which keep their height because a tile
	getting shorter as it is worked is what makes a tool upgrade legible.

	They are drawn as a handful of separate clumps scattered over the tile
	rather than as one clump stretched to fill it. Filling it was the worst
	thing on the screen: the grass model is a four stud square with its own
	patch of ground under it, so one per tile laid a four stud square of
	lighter green edge to edge across the whole property, and the lawn came
	out as something you could count the tiles of. Clumps narrower than a tile
	overlap their neighbours and leave gaps between, which is what reads as a
	continuous lawn instead of a grid.

	How many there are falls with the height, so clearing a tile thins it as
	well as shortening it.
]]
--- Which clump model stands in for each kind of debris.
local CLUMP_FOR: { [number]: Props.Prop } = {
	[DebrisConfig.Grass] = Props.catalogue.GrassTuft,
	[DebrisConfig.Weeds] = Props.catalogue.Weeds,
	[DebrisConfig.Hedge] = Props.catalogue.Bush,
	[DebrisConfig.Sticks] = Props.catalogue.Twigs,
}

--- Roughly how wide one clump of each kind is, in studs. Everything but the
--- hedge is narrower than a tile so the scatter can overlap across tile edges.
local CLUMP_WIDTH: { [number]: number } = {
	[DebrisConfig.Grass] = 1.8,
	[DebrisConfig.Weeds] = 1.9,
	[DebrisConfig.Hedge] = TILE,
	[DebrisConfig.Sticks] = 1.7,
}

--[[
	A hedge is a solid mass and stays one piece; everything else thins out as
	it is cleared.

	One more clump than there are levels of height, because a tile worked down
	to its last level should still have something on it rather than a single
	tuft marooned in the middle of four studs of bare lawn.
]]
local function clumpsOn(debrisId: number, height: number): number
	if debrisId == DebrisConfig.Hedge then
		return 1
	end
	return math.clamp(height + 1, 2, 4)
end

local function drawBlock(index: number, wx: number, wz: number, floor: number, height: number, debrisId: number, locked: boolean)
	local count = clumpsOn(debrisId, height)
	local parts = slots(index, count, false)
	local studs = height * HEIGHT_STUD
	local color = baseColor(debrisId, index)
	if locked then
		color = desaturate(color)
	end

	local def = CLUMP_FOR[debrisId] or CLUMP_FOR[DebrisConfig.Grass]
	local width = CLUMP_WIDTH[debrisId] or 2.5
	--[[
		One clump stands in the middle of its tile; several spread out to the
		edges — and no further.

		The spread carried an extra 0.55 studs so a tile did not look sparse,
		and a clump swayed up to a quarter wider than nominal on top of that,
		so the edge of a clump could sit more than half a stud past the edge
		of its own square. Against a wall on the next tile that is a tuft
		coming out of the brick. The reach is worked out per clump from its
		own width, so the widest one still stops at the line.
	]]
	local spread = if count == 1 then 0 else (TILE - width) * 0.5 + 0.55

	for slot, part in parts do
		local yaw = hash01(index, slot * 3 + 3) * math.pi * 2
		-- Vary the size around the nominal one rather than below it, so a
		-- thinned tile is not also a uniformly smaller one.
		local sway = if count == 1 then 1 else 0.78 + hash01(index, slot * 7 + 1) * 0.46
		local wide = width * sway
		local tall = math.max(studs * sway, 0.2)
		local reach = math.min(spread, math.max(TILE * 0.5 - wide * 0.5, 0))
		local offsetX = (hash01(index, slot * 3 + 1) - 0.5) * 2 * reach
		local offsetZ = (hash01(index, slot * 3 + 2) - 0.5) * 2 * reach

		part.Size = Vector3.new(wide, tall, wide)
		part.CFrame = CFrame.new(wx + offsetX, floor + tall * 0.5, wz + offsetZ) * CFrame.Angles(0, yaw, 0)
		part.Color = color
		part.Material = if debrisId == DebrisConfig.Sticks then Enum.Material.Wood else Enum.Material.Grass
		part.Transparency = 0

		local clump = part:FindFirstChild("Clump")
		if clump and clump:IsA("SpecialMesh") and def then
			if clump.MeshId ~= def.mesh then
				clump.MeshId = def.mesh
			end
			-- Set every time: these parts come back from the same pool the
			-- distant carpets use, and would otherwise keep that texture and
			-- whatever tint it was last drawn with.
			clump.TextureId = def.texture or ""
			--[[
				Bring the clump to the palette's green.

				A textured mesh ignores the colour of the part under it, so
				every tuft was showing whatever green its own texture happened
				to be painted — a colder, bluer one than the lawn it stands on,
				which made the grass read as a different plant from the ground.
				The tint is normalised to its brightest channel so it carries
				the hue without darkening the blades to mud.
			]]
			local brightest = math.max(color.R, color.G, color.B, 0.001)
			clump.VertexColor = Vector3.new(color.R, color.G, color.B) / brightest
			clump.Scale = Vector3.new(wide / def.native.X, tall / def.native.Y, wide / def.native.Z)
			clump.Offset = Vector3.zero
		end

		part.Parent = detailFolder
	end
end

local function drawTile(theGrid: Grid.Grid, theTiles: buffer, index: number, locked: boolean)
	local byte = buffer.readu8(theTiles, index - 1)
	local height = ChunkCodec.height(byte)

	if height <= 0 then
		release(index)
		return
	end

	local tx, tz = Grid.fromIndex(theGrid, index)
	local wx, wz = Grid.tileToWorld(theGrid, tx, tz)
	local floor = GameConfig.GROUND_Y + (tileElevation[index] or 0)
	local debrisId = ChunkCodec.debris(byte)

	if debrisId == DebrisConfig.Leaves then
		drawLeaves(index, wx, wz, floor, height, locked)
	else
		drawBlock(index, wx, wz, floor, height, debrisId, locked)
	end
end

--- One flat plane standing in for a whole chunk at distance.
local function drawLod(theGrid: Grid.Grid, theTiles: buffer, chunkIndex: number)
	local cx, cz = Grid.chunkFromIndex(theGrid, chunkIndex)
	local baseX, baseZ = cx * theGrid.chunkTiles, cz * theGrid.chunkTiles

	local remaining, samples = 0, 0
	local floor = GameConfig.GROUND_Y
	--- The corner tiles of what in this chunk actually has something on it.
	local lowX, highX = math.huge, -math.huge
	local lowZ, highZ = math.huge, -math.huge

	--[[
		What kind of debris this chunk is, by weight rather than by whichever
		tile happened to be read last.

		Taking the last one painted a whole thirty-two stud square in the colour
		of a single tile: one hedge tile in the corner of a chunk turned the
		square dark green, one stick tile turned it brown. Across a property
		that came out as a chequerboard of dark and light squares — the thing
		the clumps were brought in to remove, reappearing at distance. A chunk
		is now coloured by whatever most of it actually is.
	]]
	local weight: { [number]: number } = {}
	local debrisId = DebrisConfig.Grass
	local best = 0
	local surface = ""
	local zone = ""

	--[[
		Every tile, not every other one.

		The sampler stepped two at a time, which is enough for "roughly how
		much is left" and not enough for "where exactly is it" — and the
		stand-in is now cut to the tiles that hold something, so a sampler
		that can miss the outermost row would need a row of margin to be
		safe, and a row of margin is four studs of carpet laid over whatever
		is next to the section. Sixty-four reads a chunk instead of sixteen
		buys an exact answer and costs nothing worth measuring.
	]]
	for lz = 0, theGrid.chunkTiles - 1 do
		for lx = 0, theGrid.chunkTiles - 1 do
			local tx, tz = baseX + lx, baseZ + lz
			if Grid.inBounds(theGrid, tx, tz) then
				local index = Grid.toIndex(theGrid, tx, tz)
				local byte = buffer.readu8(theTiles, index - 1)
				local height = ChunkCodec.height(byte)
				samples += 1
				if height > 0 then
					remaining += height
					local kind = ChunkCodec.debris(byte)
					local total = (weight[kind] or 0) + height
					weight[kind] = total
					if total > best then
						best = total
						debrisId = kind
					end
					floor = GameConfig.GROUND_Y + (tileElevation[index] or 0)
					surface = tileKind[index] or ""
					zone = tileSection[index] or ""
					lowX = math.min(lowX, tx)
					highX = math.max(highX, tx)
					lowZ = math.min(lowZ, tz)
					highZ = math.max(highZ, tz)
				end
			end
		end
	end

	local existing = lodParts[chunkIndex]

	--[[
		Grass at distance is the ground it grows on, so nothing is drawn for it.

		The carpet is the lot's own ground colour now, laid a stud or two above
		the actual ground, which is the same colour and the same material. That
		should be invisible and is not: a raised slab catches the light a shade
		differently and puts a shadow along its edge, so the far half of every
		property kept a faint grid of thirty-two stud rectangles on it — the
		last of the chequerboard, in its quietest form.

		A drift still gets one, because a lawn covered in leaves genuinely does
		look different from across a property and that is worth being able to
		see. Bare grass does not, so it is left to the ground to draw.

		That reasoning is about a lawn, and it goes wrong the moment the floor
		is not one. On the tennis court the ground is blue tarmac: a chunk of
		leaves got a carpet, a chunk of fallen branches got nothing and showed
		bare court, and the near end showed real leaves — so a single court
		came out in three different finishes in thirty-two stud squares, with
		one patch dark and littered and the rest of it bare. Reported as only
		one section of the court being black with leaves.

		Litter on a hard floor is not the floor, whatever it is made of and
		whatever the litter is. The test is not which kind of section this is
		but whether what is lying here looks like what it is lying on: grass
		on a lawn does, and nothing else does. So a chunk is skipped only when
		it is grass on grass, and everything else — leaves on a lawn, weeds on
		a forecourt, branches on a court — gets a stand-in.
	]]
	local floorColour: Color3? = surfaceByKind[surface]
	local hardFloor = floorColour ~= nil or not groundIsLawn
	--[[
		How much of this chunk is something other than the grass itself.

		The rule above is right and the way it was applied was not. It was a
		yes or no taken on whichever debris weighed most in the chunk: a
		square that came out mostly leaves drew an opaque slab, the square
		next to it that came out mostly grass drew nothing at all, and a lawn
		sown with both — which is every lawn in the game — alternated between
		the two across a thirty-two stud grid. Looking the length of the
		Cemetery, the middle distance is a chequerboard of squares, which is
		the same complaint the weighting was brought in to fix, one level up.

		The share is a fraction, so it is used as one: a chunk with nothing
		but grass in it is fully transparent, which draws exactly nothing and
		is what "left to the ground" already meant, and a chunk that is all
		drift is opaque, which is what it already was. Everything between
		those two now lands between them instead of at one end or the other.
	]]
	local grassHeight = weight[DebrisConfig.Grass] or 0
	local litterShare = if remaining > 0 then (remaining - grassHeight) / remaining else 0
	--- Under this it would be drawn at a transparency nobody can see, so the
	--- part is not made at all.
	local growsFromTheGround = not hardFloor and litterShare < 0.03
	local nothingToDraw = samples == 0 or remaining == 0 or growsFromTheGround
	if nothingToDraw then
		if existing then
			existing.Parent = nil
		end
		return
	end

	local part: Part
	if existing then
		part = existing
	else
		part = newLodPart()
		lodParts[chunkIndex] = part
	end

	local averageHeight = remaining / samples * HEIGHT_STUD

	-- A leaf drift has no real height, so its stand-in stays a thin carpet —
	-- and so does anything lying on a hard floor, which is litter rather than
	-- something growing out of it.
	local thickness = if debrisId == DebrisConfig.Leaves or hardFloor
		then 0.3
		else math.max(averageHeight, 0.2)
	--[[
		Only as big as what it is standing in for.

		The plane used to be the whole chunk, thirty-two studs square, however
		little of that chunk had anything on it. A chunk that catches the edge
		of the pool laid an opaque lawn-green slab straight across the water,
		and every chunk on a section's boundary spilled its carpet out onto
		whatever was next door. The stand-in is now cut down to exactly the
		tiles that hold something.
	]]
	local fromX, toX = lowX, highX
	local fromZ, toZ = lowZ, highZ
	local nearX, nearZ = Grid.tileToWorld(theGrid, fromX, fromZ)
	local farX, farZ = Grid.tileToWorld(theGrid, toX, toZ)
	local wide = (toX - fromX + 1) * TILE
	local deep = (toZ - fromZ + 1) * TILE
	local x, z = (nearX + farX) * 0.5, (nearZ + farZ) * 0.5

	--[[
		The floor, carried towards what is lying on it.

		Two numbers rather than a table of special cases. On a lawn the blend
		is a fifth, because the grass beside the drift is already saying what
		the ground is and a loud carpet would read as paint; anywhere else it
		is most of the way, because there the litter is the only thing to see
		and a quiet blend is a grey lid that hides the surface as well as the
		debris.

		Leaves are blended towards the average of the nine shades a drift is
		actually made of rather than towards any one of them. Everything else
		uses its own colour, which is what puts green weeds on a grey
		forecourt instead of nothing at all.
	]]
	local litter = litterBySection[zone]
		or (if debrisId == DebrisConfig.Leaves
			then Palette.color(Palette.leafAverage)
			else Palette.color(DebrisConfig.get(debrisId).color))

	--[[
		How far towards the litter, by how much of it is still there.

		A flat fraction paints a chunk with one leaf left in it exactly as
		loudly as an untouched one, so a section you have half cleared still
		reads as full from the other end of it — and the moment the last tile
		goes the whole square vanishes at once. Scaling by what the chunk
		actually holds means the distance fades as you work, which is both
		true and the only feedback you get on a section you are not standing
		in.
	]]
	local fullness = math.clamp(remaining / (samples * MAX_TILE_HEIGHT), 0, 1)

	part.Size = Vector3.new(wide, thickness, deep)
	part.CFrame = CFrame.new(x, floor + thickness * 0.5, z)
	--[[
		Litter on a hard floor is laid over it, not instead of it.

		Opaque, the stand-in covers the court: its markings, its colour and
		the shape of it all disappear behind a solid rectangle, and the seam
		against the detailed tiles beside it is a straight line across the
		middle of the section. Left partly transparent, the tarmac and the
		white lines carry on underneath and the carpet reads as what it is —
		the same leaves, drawn more cheaply.

		A lawn keeps its opaque slab, because there the slab *is* the ground.
	]]
	part.Material = if debrisId == DebrisConfig.Leaves or hardFloor
		then Enum.Material.SmoothPlastic
		else Enum.Material.Grass

	--[[
		On a hard floor the stand-in is the litter, thinned to how much of the
		floor it covers — not the floor mixed with the litter.

		Mixing them is what a lerp does, and mixing two colours from opposite
		sides of the wheel gives mud: the tennis court is blue tarmac, autumn
		leaves are gold, and every blend of the two came out a flat grey. From
		the terrace the court read as swept clean while it was still buried,
		and the only way to find out otherwise was to walk down there. Drawn
		as gold at a transparency that says how much of it there is, the blue
		underneath shows through the gaps instead of being averaged away, and
		neither colour has to be a lie.

		A lawn keeps its opaque slab and its gentle blend, because there the
		slab *is* the ground rather than something lying on it.
	]]
	if hardFloor then
		part.Color = litter
		local cover = coverBySection[zone] or COVERAGE[debrisId] or DEFAULT_COVERAGE
		local solidity = LOD_FLOOR + LOD_RANGE * cover * fullness
		part.Transparency = math.clamp(1 - solidity, 0.16, 0.80)
	else
		part.Color = groundColor:Lerp(litter, 0.06 + 0.16 * fullness)
		-- All drift is the opaque slab it always was; all grass is nothing at
		-- all, which it also always was. The gradient is the new part.
		part.Transparency = math.clamp(1 - litterShare, 0, 1)
	end
	part.Parent = lodFolder
end

--------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------

local pendingRequest: { number } = {}

local function refresh()
	local theGrid = grid
	local theTiles = tiles
	if not theGrid or not theTiles then
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local focus = camera.CFrame.Position
	local now = os.clock()

	local centreTx, centreTz = Grid.worldToTile(theGrid, focus.X, focus.Z)
	local reachChunks = math.ceil(GameConfig.LOD_RADIUS / (theGrid.chunkTiles * TILE)) + 1
	local ccx, ccz = centreTx // theGrid.chunkTiles, centreTz // theGrid.chunkTiles

	local visibleDetail: { [number]: boolean } = {}
	table.clear(pendingRequest)


	for cz = ccz - reachChunks, ccz + reachChunks do
		for cx = ccx - reachChunks, ccx + reachChunks do
			if cx >= 0 and cz >= 0 and cx < theGrid.chunksX and cz < theGrid.chunksZ then
				local chunkIndex = Grid.chunkIndex(theGrid, cx, cz)
				local wx, wz = Grid.chunkCentre(theGrid, cx, cz)
				local dx, dz = wx - focus.X, wz - focus.Z
				local distanceSq = dx * dx + dz * dz

				if distanceSq <= LOD_SQ then
					if not known[chunkIndex] and #pendingRequest < REQUEST_BATCH then
						local askedAt = requestedAt[chunkIndex]
						if not askedAt or now - askedAt > REQUEST_RETRY_SECONDS then
							requestedAt[chunkIndex] = now
							table.insert(pendingRequest, chunkIndex)
						end
					end

					local chunkReach = theGrid.chunkTiles * TILE * 0.75
					if distanceSq <= DETAIL_SQ + chunkReach * chunkReach then
						--[[
							The carpet only comes up once the whole chunk is
							getting tufts.

							Whether a chunk draws detail and whether it keeps
							its stand-in were the same question, and they are
							not. A chunk qualified for detail on its centre
							plus three quarters of its width, but only the
							tiles inside the detail radius itself were drawn —
							so the corners of the outermost detail chunks got
							no tufts, and their carpet had already been taken
							away. That is a ring of bare ground just past the
							tufts: sampled around the Cemetery at seventy-eight
							studs out, fourteen of thirty-one points on the
							ring had nothing drawn over them at all. It is what
							"the grass is not loading all the way" looks like.

							A chunk's farthest corner is half its diagonal from
							its centre, so that is the distance at which every
							tile in it is certainly inside the radius, and only
							then is the carpet not needed. Between the two, the
							chunk keeps its carpet and grows tufts through it.
						]]
						local corner = theGrid.chunkTiles * TILE * 0.70711
						local inner = math.max(GameConfig.DETAIL_RADIUS - corner, 0)
						if distanceSq <= inner * inner then
							local lod = lodParts[chunkIndex]
							if lod then
								lod.Parent = nil
							end
						else
							drawLod(theGrid, theTiles, chunkIndex)
						end

						local baseX, baseZ = cx * theGrid.chunkTiles, cz * theGrid.chunkTiles
						for lz = 0, theGrid.chunkTiles - 1 do
							for lx = 0, theGrid.chunkTiles - 1 do
								local tx, tz = baseX + lx, baseZ + lz
								if Grid.inBounds(theGrid, tx, tz) then
									local index = Grid.toIndex(theGrid, tx, tz)
									local tileX, tileZ = Grid.tileToWorld(theGrid, tx, tz)
									local tdx, tdz = tileX - focus.X, tileZ - focus.Z
									if tdx * tdx + tdz * tdz <= DETAIL_SQ then
										visibleDetail[index] = true
										drawTile(theGrid, theTiles, index, isLocked(index))
									end
								end
							end
						end
					else
						drawLod(theGrid, theTiles, chunkIndex)
					end
				end
			end
		end
	end

	for index in active do
		if not visibleDetail[index] then
			release(index)
		end
	end

	if #pendingRequest > 0 then
		requestChunks:FireServer(table.clone(pendingRequest))
	end
end

--------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------

local function resetWorld(width: number, depth: number)
	for index in active do
		release(index)
	end
	for _, part in lodParts do
		part:Destroy()
	end
	table.clear(lodParts)
	table.clear(known)
	table.clear(requestedAt)

	grid = Grid.new(width, depth)
	tiles = buffer.create(width * depth)
	table.clear(tileSection)
	table.clear(tileElevation)
end

function GrassRenderer.setOpenSections(sections: { [string]: boolean })
	local theGrid = grid
	local theTiles = tiles
	openSections = sections

	if theGrid and theTiles then
		for index in active do
			drawTile(theGrid, theTiles, index, isLocked(index))
		end
	end
end

function GrassRenderer.getOpenSections(): { [string]: boolean }
	return openSections
end

function GrassRenderer.tiles(): buffer?
	return tiles
end

function GrassRenderer.grid(): Grid.Grid?
	return grid
end

--[[
	Where a tile's debris actually sits, as a centre and a size.

	Pickup targeting needs to draw an outline that lands on the leaves rather
	than on the ground plane under them, and only the renderer knows how tall the
	drift was drawn or how far up the section's floor is.
]]
function GrassRenderer.tileBounds(index: number): (Vector3?, Vector3?)
	local theGrid = grid
	local theTiles = tiles
	if not theGrid or not theTiles or index < 1 or index > Grid.tileCount(theGrid) then
		return nil, nil
	end

	local byte = buffer.readu8(theTiles, index - 1)
	local height = ChunkCodec.height(byte)
	if height <= 0 then
		return nil, nil
	end

	local tx, tz = Grid.fromIndex(theGrid, index)
	local wx, wz = Grid.tileToWorld(theGrid, tx, tz)
	local floor = GameConfig.GROUND_Y + (tileElevation[index] or 0)

	-- Leaves lie flat and scatter slightly past the tile edge; anything else is
	-- drawn as a block filling the tile exactly.
	local studs, width
	if ChunkCodec.debris(byte) == DebrisConfig.Leaves then
		studs, width = 0.7, TILE + 0.9
	else
		studs, width = height * HEIGHT_STUD, TILE
	end

	return Vector3.new(wx, floor + studs * 0.5, wz), Vector3.new(width, studs, width)
end

--- Applies a locally predicted cut so mowing feels instant; the server's
--- authoritative state overwrites it on the next chunk delta.
function GrassRenderer.predictCut(index: number, levels: number)
	local theTiles = tiles
	local theGrid = grid
	if not theTiles or not theGrid or index < 1 or index > Grid.tileCount(theGrid) then
		return
	end
	local byte = buffer.readu8(theTiles, index - 1)
	local height = ChunkCodec.height(byte)
	if height <= 0 then
		return
	end
	buffer.writeu8(theTiles, index - 1, ChunkCodec.withHeight(byte, math.max(height - levels, 0)))
	drawTile(theGrid, theTiles, index, isLocked(index))
end

function GrassRenderer.start()
	requestChunks = Remotes.event(Remotes.REQUEST_CHUNKS)
	chunkDelta = Remotes.event(Remotes.CHUNK_DELTA)
	worldInfo = Remotes.event(Remotes.WORLD_INFO)

	container = Instance.new("Folder")
	;(container :: Folder).Name = "MowGrass"
	;(container :: Folder).Parent = Workspace

	detailFolder = Instance.new("Folder")
	;(detailFolder :: Folder).Name = "Detail"
	;(detailFolder :: Folder).Parent = container

	lodFolder = Instance.new("Folder")
	;(lodFolder :: Folder).Name = "Lod"
	;(lodFolder :: Folder).Parent = container

	worldInfo.OnClientEvent:Connect(function(info: any)
		if type(info) == "table" and type(info.width) == "number" and type(info.depth) == "number" then
			resetWorld(info.width, info.depth)
			local theGrid = grid
			if theGrid and type(info.worldId) == "string" then
				buildZoneMap(info.worldId, theGrid)
			end
		end
	end)

	chunkDelta.OnClientEvent:Connect(function(packet: any)
		local theGrid = grid
		local theTiles = tiles
		if not theGrid or not theTiles or typeof(packet) ~= "buffer" then
			return
		end
		local touched = ChunkCodec.decodeInto(theGrid, theTiles, packet)
		if touched then
			for _, chunkIndex in touched do
				known[chunkIndex] = true
			end
		end
	end)

	local accumulator = 0
	local interval = 1 / GameConfig.RENDER_REFRESH_HZ
	RunService.RenderStepped:Connect(function(delta)
		accumulator += delta
		if accumulator >= interval then
			accumulator = 0
			refresh()
		end
	end)
end

return GrassRenderer
