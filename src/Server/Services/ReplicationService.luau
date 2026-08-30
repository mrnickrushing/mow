--!strict
--[[
	ReplicationService — batches tile changes out to clients.

	Cuts are marked dirty per chunk and flushed on a fixed tick rather than sent
	per tile, and only to clients close enough to see them. A player who walks
	into a fresh area asks for those chunks explicitly, which keeps the steady
	stream small without anyone ever seeing stale grass.

	This is a transport and nothing more: it is handed a grid and a tile buffer
	by whoever generated them and never reaches back for the world itself. That
	keeps the dependency pointing one way — the thing that builds a world tells
	the thing that streams it, not the other way about.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkCodec = require(Shared.ChunkCodec)
local GameConfig = require(Shared.Config.GameConfig)
local Grid = require(Shared.Grid)
local Remotes = require(Shared.Remotes)

local ReplicationService = {}

--- Shortest gap between two answers to the same client asking for the world.
local WORLD_INFO_ASK_INTERVAL = 0.5

--- What a client is told about the loaded world when it joins or a run starts.
export type WorldInfo = {
	worldId: string,
	width: number,
	depth: number,
	totalUnits: number,
}

local dirty: { [number]: boolean } = {}
local dirtyCount = 0
local grid: Grid.Grid? = nil
local tiles: buffer? = nil
local info: WorldInfo? = nil
local chunkDelta: RemoteEvent
local requestChunks: RemoteEvent
local worldInfo: RemoteEvent

--[[
	Points the replicator at a freshly generated world.

	Called once per load. Any chunks still pending from the previous world are
	dropped, because their indices mean something different now.
]]
function ReplicationService.attach(newGrid: Grid.Grid, newTiles: buffer, newInfo: WorldInfo)
	table.clear(dirty)
	dirtyCount = 0
	grid = newGrid
	tiles = newTiles
	info = newInfo
end

--- Keeps the joiner payload current when the world's totals move — a section
--- refilling adds debris back, and a client that joins after that should be
--- told the new total rather than the one the map started with.
function ReplicationService.setTotalUnits(total: number)
	local current = info
	if current then
		current.totalUnits = total
	end
end

function ReplicationService.isAttached(): boolean
	return grid ~= nil
end

function ReplicationService.markDirty(chunkIndex: number)
	if not dirty[chunkIndex] then
		dirty[chunkIndex] = true
		dirtyCount += 1
	end
end

--- Marks the chunk containing a tile index.
function ReplicationService.markTileDirty(tileIndex: number)
	local theGrid = grid
	if theGrid then
		ReplicationService.markDirty(Grid.chunkOfTileIndex(theGrid, tileIndex))
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
	local theGrid = grid
	local theTiles = tiles
	if not theGrid or not theTiles or #chunkIndices == 0 then
		return
	end

	local perPacket = ChunkCodec.maxChunksPerPacket(theGrid)
	local batch = table.create(math.min(perPacket, #chunkIndices))

	for _, chunkIndex in chunkIndices do
		table.insert(batch, chunkIndex)
		if #batch >= perPacket then
			chunkDelta:FireClient(player, ChunkCodec.encode(theGrid, theTiles, batch))
			table.clear(batch)
		end
	end

	if #batch > 0 then
		chunkDelta:FireClient(player, ChunkCodec.encode(theGrid, theTiles, batch))
	end
end

--- Tells a player which property is loaded and how big its grid is.
function ReplicationService.sendWorldInfo(player: Player)
	local current = info
	if not current then
		return
	end
	worldInfo:FireClient(player, {
		worldId = current.worldId,
		width = current.width,
		depth = current.depth,
		totalUnits = current.totalUnits,
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

	local theGrid = grid
	local theTiles = tiles
	if not theGrid or not theTiles then
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
		local cx, cz = Grid.chunkFromIndex(theGrid, chunkIndex)
		local x, z = Grid.chunkCentre(theGrid, cx, cz)
		centres[i] = Vector2.new(x, z)
	end

	local perPacket = ChunkCodec.maxChunksPerPacket(theGrid)
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
						chunkDelta:FireClient(player, ChunkCodec.encode(theGrid, theTiles, batch))
						batch = {}
					end
				end
			end
			if #batch > 0 then
				chunkDelta:FireClient(player, ChunkCodec.encode(theGrid, theTiles, batch))
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
		local theGrid = grid
		if not theGrid then
			return
		end

		local wanted = {}
		local chunkCount = Grid.chunkCount(theGrid)
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
		ReplicationService.sendWorldInfo(player)
	end)

	--[[
		A client asking which world it is standing in.

		The send used to be one-shot — once when you joined and once when a run
		began — so a client whose handler connected a moment after either, which
		in a Studio solo test is every time, never learned the world at all.
		Nothing said so: chunks still arrived and grass still cut, but the
		client could not name the section under its feet, so it predicted no
		cuts, showed no gain numbers, drew no missed-spot beacons and left
		locked ground looking open. Letting the client ask, and keep asking
		until it has an answer, closes that for good.
	]]
	local lastAsked: { [Player]: number } = {}
	worldInfo.OnServerEvent:Connect(function(player)
		local now = os.clock()
		if now - (lastAsked[player] or -math.huge) < WORLD_INFO_ASK_INTERVAL then
			return
		end
		lastAsked[player] = now
		ReplicationService.sendWorldInfo(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastAsked[player] = nil
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
