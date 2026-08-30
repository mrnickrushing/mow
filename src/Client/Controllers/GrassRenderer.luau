--!strict
--[[
	GrassRenderer — draws the tile buffer.

	The client holds its own copy of the world's tile bytes and renders only a
	window of it: individual parts inside DETAIL_RADIUS, a single flat plane per
	chunk out to LOD_RADIUS, and nothing beyond that. Parts come from a pool and
	are recycled rather than created and destroyed, because churning thousands of
	Instances is what actually costs frames.

	Chunks are requested from the server as the camera moves into them, so a
	player never sees stale grass without the server streaming the whole map.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkCodec = require(Shared.ChunkCodec)
local DebrisConfig = require(Shared.Config.Debris)
local GameConfig = require(Shared.Config.GameConfig)
local Grid = require(Shared.Grid)
local Remotes = require(Shared.Remotes)

local GrassRenderer = {}

local TILE = GameConfig.TILE_SIZE
local HEIGHT_STUD = GameConfig.HEIGHT_STUD

local grid: Grid.Grid? = nil
local tiles: buffer? = nil
local container: Folder? = nil
local detailFolder: Folder? = nil
local lodFolder: Folder? = nil

--- Tile index -> the part currently drawing it.
local active: { [number]: Part } = {}
local pool: { Part } = {}
--- Chunk index -> its LOD plane.
local lodParts: { [number]: Part } = {}
--- Chunks whose contents the client has received.
local known: { [number]: boolean } = {}
--- Chunks already asked for, so a request is not repeated every refresh.
local requested: { [number]: boolean } = {}
--- Zones the local player has unlocked; locked ground renders desaturated.
local unlockedZones: { [string]: boolean } = {}

local requestChunks: RemoteEvent
local chunkDelta: RemoteEvent
local worldInfo: RemoteEvent

local DETAIL_SQ = GameConfig.DETAIL_RADIUS * GameConfig.DETAIL_RADIUS
local LOD_SQ = GameConfig.LOD_RADIUS * GameConfig.LOD_RADIUS

--------------------------------------------------------------------
-- Part pool
--------------------------------------------------------------------

local function newPart(): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Grass
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = Vector3.new(TILE, HEIGHT_STUD, TILE)
	return part
end

local function acquire(): Part
	local part = table.remove(pool)
	if part then
		return part
	end
	return newPart()
end

local function release(index: number)
	local part = active[index]
	if not part then
		return
	end
	active[index] = nil
	part.Parent = nil
	if #pool < GameConfig.MAX_TILE_PARTS then
		table.insert(pool, part)
	else
		part:Destroy()
	end
end

--------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------

local function colorFor(debrisId: number, locked: boolean): Color3
	local def = DebrisConfig.get(debrisId)
	local color = Color3.new(def.color[1], def.color[2], def.color[3])
	if locked then
		-- Locked ground reads as out of bounds without a physical barrier, which
		-- a shared map cannot have when zones unlock per player.
		local grey = (color.R + color.G + color.B) / 3
		return color:Lerp(Color3.new(grey, grey, grey), 0.65)
	end
	return color
end

--- Draws or updates one tile, or releases its part when the tile is clean.
local function drawTile(theGrid: Grid.Grid, theTiles: buffer, index: number, zoneLocked: boolean)
	local byte = buffer.readu8(theTiles, index - 1)
	local height = ChunkCodec.height(byte)

	if height <= 0 then
		release(index)
		return
	end

	local existing = active[index]
	local part: Part
	if existing then
		part = existing
	else
		part = acquire()
		active[index] = part
	end

	local tx, tz = Grid.fromIndex(theGrid, index)
	local wx, wz = Grid.tileToWorld(theGrid, tx, tz)
	local studs = height * HEIGHT_STUD

	part.Size = Vector3.new(TILE, studs, TILE)
	part.CFrame = CFrame.new(wx, GameConfig.GROUND_Y + studs * 0.5, wz)
	part.Color = colorFor(ChunkCodec.debris(byte), zoneLocked)
	part.Transparency = if ChunkCodec.isWet(byte) then 0.15 else 0
	part.Parent = detailFolder
end

--- One flat plane standing in for a whole chunk at distance.
local function drawLod(theGrid: Grid.Grid, theTiles: buffer, chunkIndex: number)
	local cx, cz = Grid.chunkFromIndex(theGrid, chunkIndex)
	local baseX, baseZ = cx * theGrid.chunkTiles, cz * theGrid.chunkTiles

	local remaining, samples = 0, 0
	local debrisId = DebrisConfig.Grass
	for lz = 0, theGrid.chunkTiles - 1, 2 do
		for lx = 0, theGrid.chunkTiles - 1, 2 do
			local tx, tz = baseX + lx, baseZ + lz
			if Grid.inBounds(theGrid, tx, tz) then
				local byte = buffer.readu8(theTiles, Grid.toIndex(theGrid, tx, tz) - 1)
				local height = ChunkCodec.height(byte)
				samples += 1
				if height > 0 then
					remaining += height
					debrisId = ChunkCodec.debris(byte)
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
		part = newPart()
		part.Name = "Lod"
		lodParts[chunkIndex] = part
	end

	local studs = theGrid.chunkTiles * TILE
	local averageHeight = remaining / samples * HEIGHT_STUD
	local x, z = Grid.chunkCentre(theGrid, cx, cz)

	part.Size = Vector3.new(studs, math.max(averageHeight, 0.2), studs)
	part.CFrame = CFrame.new(x, GameConfig.GROUND_Y + part.Size.Y * 0.5, z)
	part.Color = colorFor(debrisId, false)
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

	-- Walk the chunks around the camera rather than the whole map.
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

					-- A chunk close enough for detail draws per tile; further out
					-- it collapses to one plane, which is most of the saving.
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
										drawTile(theGrid, theTiles, index, false)
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

	-- Retire any tile part that fell out of the detail window.
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
end

--- The zones the local player owns, so locked ground can be tinted.
function GrassRenderer.setUnlockedZones(zones: { [string]: boolean })
	unlockedZones = zones
end

function GrassRenderer.getUnlockedZones(): { [string]: boolean }
	return unlockedZones
end

--- The client's mirror of the tile buffer, used for local cut prediction.
function GrassRenderer.tiles(): buffer?
	return tiles
end

function GrassRenderer.grid(): Grid.Grid?
	return grid
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
	drawTile(theGrid, theTiles, index, false)
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
