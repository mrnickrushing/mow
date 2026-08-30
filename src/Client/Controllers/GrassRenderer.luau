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
local Worlds = require(Shared.Config.Worlds)
local Remotes = require(Shared.Remotes)

local GrassRenderer = {}

local TILE = GameConfig.TILE_SIZE
local HEIGHT_STUD = GameConfig.HEIGHT_STUD

--- Leaves drawn per height level on a tile.
local LEAVES_PER_LEVEL = 3
--- Cap, so a deep drift never explodes the part budget.
local MAX_LEAVES_PER_TILE = 8

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
local requested: { [number]: boolean } = {}
local openSections: { [string]: boolean } = {}
local tileSection: { string } = {}
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
		-- A leaf is a silhouette, not a box. Built-in mesh types give a rounded
		-- blade and a pointed one for free, with no uploaded asset: a floor of
		-- rectangles at this density reads as one sheet of orange, which is the
		-- opposite of the drift of separate leaves we are after.
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Name = "Blade"
		mesh.Parent = part
	end

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
	local world = Worlds.get(worldId)
	if not world then
		return
	end
	for _, section in world.sections do
		local r = section.rect
		local elevation = section.elevation or 0
		for tz = r.z, math.min(r.z + r.d - 1, theGrid.depth - 1) do
			for tx = r.x, math.min(r.x + r.w - 1, theGrid.width - 1) do
				local index = Grid.toIndex(theGrid, tx, tz)
				tileSection[index] = section.id
				tileElevation[index] = elevation
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

		local mesh = part:FindFirstChild("Blade")
		if mesh and mesh:IsA("SpecialMesh") then
			-- Roughly a third are the pointed maple sort, the rest rounded.
			mesh.MeshType = if shapeRoll < 0.34 then Enum.MeshType.Prism else Enum.MeshType.Sphere
		end

		local palette = Palette.leaves
		local color = Palette.color(palette[((index * 7 + slot * 3) % #palette) + 1])
		-- One in seven lands pale side up.
		if hash01(index, slot * 13) > 0.86 then
			color = Palette.color(Palette.leafPale)
		end

		part.Size = Vector3.new(3.0 * scale, 0.34, 2.1 * scale)
		part.CFrame = CFrame.new(wx + offsetX, floor + 0.17 + layer * 0.15, wz + offsetZ)
			* CFrame.Angles(pitch, yaw, roll)
		part.Color = if locked then desaturate(color) else color
		part.Material = Enum.Material.SmoothPlastic
		part.Transparency = 0
		part.Parent = detailFolder
	end
end

--- Grass, weeds and hedges keep the block form, because their height falling is
--- what makes a mower upgrade legible.
local function drawBlock(index: number, wx: number, wz: number, floor: number, height: number, debrisId: number, locked: boolean)
	local parts = slots(index, 1, false)
	local part = parts[1]
	local studs = height * HEIGHT_STUD
	local color = baseColor(debrisId, index)

	part.Size = Vector3.new(TILE, studs, TILE)
	part.CFrame = CFrame.new(wx, floor + studs * 0.5, wz)
	part.Color = if locked then desaturate(color) else color
	part.Material = if debrisId == DebrisConfig.Sticks then Enum.Material.Wood else Enum.Material.Grass
	part.Transparency = 0
	part.Parent = detailFolder
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
	local debrisId = DebrisConfig.Grass
	local floor = GameConfig.GROUND_Y
	local sampleIndex = 1

	for lz = 0, theGrid.chunkTiles - 1, 2 do
		for lx = 0, theGrid.chunkTiles - 1, 2 do
			local tx, tz = baseX + lx, baseZ + lz
			if Grid.inBounds(theGrid, tx, tz) then
				local index = Grid.toIndex(theGrid, tx, tz)
				local byte = buffer.readu8(theTiles, index - 1)
				local height = ChunkCodec.height(byte)
				samples += 1
				if height > 0 then
					remaining += height
					debrisId = ChunkCodec.debris(byte)
					sampleIndex = index
					floor = GameConfig.GROUND_Y + (tileElevation[index] or 0)
				end
			end
		end
	end

	local existing = lodParts[chunkIndex]

	if samples == 0 or remaining == 0 then
		if existing then
			existing.Parent = nil
		end
		return
	end

	local part: Part
	if existing then
		part = existing
	else
		part = newPart(false)
		part.Name = "Lod"
		lodParts[chunkIndex] = part
	end

	local studs = theGrid.chunkTiles * TILE
	local averageHeight = remaining / samples * HEIGHT_STUD

	-- A leaf drift has no real height, so its stand-in stays a thin carpet.
	local thickness = if debrisId == DebrisConfig.Leaves
		then 0.3
		else math.max(averageHeight, 0.2)
	local x, z = Grid.chunkCentre(theGrid, cx, cz)

	part.Size = Vector3.new(studs, thickness, studs)
	part.CFrame = CFrame.new(x, floor + thickness * 0.5, z)
	part.Color = baseColor(debrisId, sampleIndex)
	part.Material = if debrisId == DebrisConfig.Leaves then Enum.Material.SmoothPlastic else Enum.Material.Grass
	part.Transparency = 0
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
					if not known[chunkIndex] and not requested[chunkIndex] then
						requested[chunkIndex] = true
						table.insert(pendingRequest, chunkIndex)
					end

					local chunkReach = theGrid.chunkTiles * TILE * 0.75
					if distanceSq <= DETAIL_SQ + chunkReach * chunkReach then
						local lod = lodParts[chunkIndex]
						if lod then
							lod.Parent = nil
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
	table.clear(requested)

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
