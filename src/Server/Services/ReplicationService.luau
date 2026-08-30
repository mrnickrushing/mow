--!strict
--[[
	ReplicationService — batches tile changes out to clients.

	Cuts are marked dirty per chunk and flushed on a fixed tick rather than sent
	per tile, and only to clients close enough to see them. A player who walks
	into a fresh area asks for those chunks explicitly, which keeps the steady
	stream small without anyone ever seeing stale grass.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkCodec = require(Shared.ChunkCodec)
local GameConfig = require(Shared.Config.GameConfig)
local Grid = require(Shared.Grid)
local Remotes = require(Shared.Remotes)
local WorldService = require(script.Parent.WorldService)

local ReplicationService = {}

local dirty: { [number]: boolean } = {}
local dirtyCount = 0
local chunkDelta: RemoteEvent
local requestChunks: RemoteEvent
local worldInfo: RemoteEvent

function ReplicationService.markDirty(chunkIndex: number)
	if not dirty[chunkIndex] then
		dirty[chunkIndex] = true
		dirtyCount += 1
	end
end

--- Marks the chunk containing a tile index.
function ReplicationService.markTileDirty(tileIndex: number)
	local grid = WorldService.grid
	if grid then
		ReplicationService.markDirty(Grid.chunkOfTileIndex(grid, tileIndex))
	end
end

local function playerPosition(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

--- Sends the given chunks in full to one player, split to fit the remote cap.
function ReplicationService.sendChunks(player: Player, chunkIndices: { number })
	local grid = WorldService.grid
	local tiles = WorldService.tiles
	if not grid or not tiles or #chunkIndices == 0 then
		return
	end

	local perPacket = ChunkCodec.maxChunksPerPacket(grid)
	local batch = table.create(math.min(perPacket, #chunkIndices))

	for _, chunkIndex in chunkIndices do
		table.insert(batch, chunkIndex)
		if #batch >= perPacket then
			chunkDelta:FireClient(player, ChunkCodec.encode(grid, tiles, batch))
			table.clear(batch)
		end
	end

	if #batch > 0 then
		chunkDelta:FireClient(player, ChunkCodec.encode(grid, tiles, batch))
	end
end

--- Tells a player which property is loaded and how big its grid is.
function ReplicationService.sendWorldInfo(player: Player)
	local grid = WorldService.grid
	local property = WorldService.property
	if not grid or not property then
		return
	end
	worldInfo:FireClient(player, {
		propertyId = property.id,
		width = grid.width,
		depth = grid.depth,
		totalUnits = WorldService.totalUnits,
	})
end

function ReplicationService.broadcastWorldInfo()
	for _, player in Players:GetPlayers() do
		ReplicationService.sendWorldInfo(player)
	end
end

local function flush()
	if dirtyCount == 0 then
		return
	end

	local grid = WorldService.grid
	local tiles = WorldService.tiles
	if not grid or not tiles then
		table.clear(dirty)
		dirtyCount = 0
		return
	end

	local indices = table.create(dirtyCount)
	for chunkIndex in dirty do
		table.insert(indices, chunkIndex)
	end
	table.clear(dirty)
	dirtyCount = 0

	-- Precompute chunk centres once, then test each player against them.
	local centres = table.create(#indices)
	for i, chunkIndex in indices do
		local cx, cz = Grid.chunkFromIndex(grid, chunkIndex)
		local x, z = Grid.chunkCentre(grid, cx, cz)
		centres[i] = Vector2.new(x, z)
	end

	local perPacket = ChunkCodec.maxChunksPerPacket(grid)
	local radiusSq = GameConfig.REPLICATION_RADIUS * GameConfig.REPLICATION_RADIUS

	for _, player in Players:GetPlayers() do
		local position = playerPosition(player)
		if position then
			local flat = Vector2.new(position.X, position.Z)
			local batch = {}
			for i, chunkIndex in indices do
				-- Squared compare: this runs per chunk per player every tick.
				local offset = centres[i] - flat
				if offset.X * offset.X + offset.Y * offset.Y <= radiusSq then
					table.insert(batch, chunkIndex)
					if #batch >= perPacket then
						chunkDelta:FireClient(player, ChunkCodec.encode(grid, tiles, batch))
						batch = {}
					end
				end
			end
			if #batch > 0 then
				chunkDelta:FireClient(player, ChunkCodec.encode(grid, tiles, batch))
			end
		end
	end
end

function ReplicationService.start()
	chunkDelta = Remotes.event(Remotes.CHUNK_DELTA)
	requestChunks = Remotes.event(Remotes.REQUEST_CHUNKS)
	worldInfo = Remotes.event(Remotes.WORLD_INFO)

	-- A client asks for chunks as it walks into them. Clamped so a hostile
	-- client cannot ask for the whole map every frame.
	requestChunks.OnServerEvent:Connect(function(player, payload)
		if type(payload) ~= "table" then
			return
		end
		local grid = WorldService.grid
		if not grid then
			return
		end

		local wanted = {}
		local chunkCount = Grid.chunkCount(grid)
		for _, value in payload :: { any } do
			if type(value) == "number" and value >= 1 and value <= chunkCount and value % 1 == 0 then
				table.insert(wanted, value)
				if #wanted >= 512 then
					break
				end
			end
		end
		ReplicationService.sendChunks(player, wanted)
	end)

	Players.PlayerAdded:Connect(function(player)
		if WorldService.isLoaded() then
			ReplicationService.sendWorldInfo(player)
		end
	end)

	local accumulator = 0
	local interval = 1 / GameConfig.REPLICATION_HZ
	RunService.Heartbeat:Connect(function(delta)
		accumulator += delta
		if accumulator >= interval then
			accumulator = 0
			flush()
		end
	end)
end

--- Discards pending work; used when a round rotates to a fresh map.
function ReplicationService.reset()
	table.clear(dirty)
	dirtyCount = 0
end

return ReplicationService
