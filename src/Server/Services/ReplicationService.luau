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
local Loop = require(Shared.Util.Loop)
local Remotes = require(Shared.Remotes)

local ReplicationService = {}

--- Shortest gap between two answers to the same client asking for the world.
local WORLD_INFO_ASK_INTERVAL = 0.5

--[[
	How much chunk data one player may pull, and how fast it refills.

	Chunk requests come from the client as it moves, and one call may ask for up
	to five hundred and twelve of them. Nothing bounded how often it could ask,
	so a client — malicious or merely broken — could sit in a loop demanding the
	whole grid and make the server serialise it over and over, for everybody.

	An allowance rather than a fixed interval, because the honest shape of this
	traffic is one large burst and then a trickle: arriving in a world needs
	every chunk in sight at once, and after that only what comes into view. A
	burst big enough to cover that first load, refilling fast enough to keep up
	with walking, still cuts a runaway loop down to a slow drip.
]]
local CHUNK_BUDGET_BURST = 3200
local CHUNK_BUDGET_PER_SECOND = 600

--- Chunk allowance left, and when it was last topped up, per player.
local chunkBudget: { [Player]: number } = {}
local chunkBudgetAt: { [Player]: number } = {}

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

		-- Refill first, so a player who has been quiet gets their allowance back
		-- before it is spent.
		local now = os.clock()
		local since = now - (chunkBudgetAt[player] or now)
		chunkBudgetAt[player] = now
		local budget = math.min(
			(chunkBudget[player] or CHUNK_BUDGET_BURST) + since * CHUNK_BUDGET_PER_SECOND,
			CHUNK_BUDGET_BURST
		)
		if budget < 1 then
			chunkBudget[player] = budget
			return
		end

		local wanted = {}
		local chunkCount = Grid.chunkCount(theGrid)
		for _, value in payload :: { any } do
			if type(value) == "number" and value >= 1 and value <= chunkCount and value % 1 == 0 then
				table.insert(wanted, value)
				if #wanted >= 512 or #wanted >= budget then
					break
				end
			end
		end

		chunkBudget[player] = budget - #wanted
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
		chunkBudget[player] = nil
		chunkBudgetAt[player] = nil
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

	--[[
		A slow sweep that re-sends what a client already thinks it has.

		Everything above only ever sends a tile the server *changed*, which is
		right until the client is wrong about a tile the server did not change
		— and the client is allowed to be wrong, because it predicts. It cuts
		the grass on screen the instant the button is held and waits for the
		server to agree. When the server does not agree there is nothing in
		the stream to say so, and the mistake is permanent.

		The server disagrees more often than the prediction admits. It drops
		the whole intent when the rate limiter is empty, when the reported
		position is outside the plausibility tolerance, and whenever the
		player's run or tool does not check out; and when the report is merely
		ahead of the server's view it clamps it, so a fast mower rasterises
		one rectangle on the client and a shorter one here. Each of those
		leaves a tile cut on screen and standing on the server.

		The player cannot find those tiles, because there is nothing to find:
		the lawn looks finished, the missed-spot beacons — which read the
		client's own copy — see nothing to mark, and the section sits a
		fraction short of a hundred per cent for the rest of the run with the
		way out shut behind it. Reported twice: "I cleaned both the backyard
		and the pool area and see NOTHING but it's at 99.8%", and then "the
		beacons appeared but I got everything so they disappeared, still no
		completion".

		It also fixes the same thing happening to somebody else's cuts. A
		flush only reaches players inside `REPLICATION_RADIUS`, and a client
		only ever asks for a chunk it has never seen — so a chunk mown by one
		player while another was across the property was never sent to them
		and never asked for again.

		Twelve chunks a tick puts the whole of The House back in front of
		every player about every six seconds, at roughly a kilobyte a second
		each. It is the same encoder and the same packet the client already
		takes on arrival, so a correction costs no more than walking into the
		chunk did.
	]]
	local RESYNC_PERIOD = 0.5
	local RESYNC_CHUNKS = 12
	local resyncCursor: { [Player]: number } = {}

	Players.PlayerRemoving:Connect(function(player)
		resyncCursor[player] = nil
	end)

	Loop.forever("ReplicationService.resync", function()
		task.wait(RESYNC_PERIOD)
		local theGrid = grid
		if not theGrid then
			return
		end
		local count = Grid.chunkCount(theGrid)
		if count <= 0 then
			return
		end
		for _, player in Players:GetPlayers() do
			local cursor = resyncCursor[player] or 0
			local batch = table.create(math.min(RESYNC_CHUNKS, count))
			for step = 0, math.min(RESYNC_CHUNKS, count) - 1 do
				table.insert(batch, (cursor + step) % count + 1)
			end
			resyncCursor[player] = (cursor + RESYNC_CHUNKS) % count
			ReplicationService.sendChunks(player, batch)
		end
	end)
end

--- Discards pending work; used when a round rotates to a fresh map.
function ReplicationService.reset()
	table.clear(dirty)
	dirtyCount = 0
end

return ReplicationService
