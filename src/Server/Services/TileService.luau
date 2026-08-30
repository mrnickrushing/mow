--!strict
--[[
	TileService — the authoritative cut.

	The client reports only where it is and what it is holding; every decision
	about what that cuts, what it yields and whether it is allowed happens here.
	A pass is rasterised into tile indices with pure grid maths — no raycasts, no
	physics queries, no Touched events — which is what keeps a full server of
	players mowing inside the frame budget.

	Validation, in order: rate limit, tool ownership, position plausibility, zone
	ownership, overgrowth gate, wet-grass stall, bag space.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local ChunkCodec = require(Shared.ChunkCodec)
local Cutting = require(Shared.Cutting)
local DebrisConfig = require(Shared.Config.Debris)
local GameConfig = require(Shared.Config.GameConfig)
local Grid = require(Shared.Grid)
local RateLimiter = require(Shared.Util.RateLimiter)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Types = require(Shared.Types)
local BagService = require(script.Parent.BagService)
local DataService = require(script.Parent.DataService)
local RunState = require(script.Parent.RunState)
local EconomyService = require(script.Parent.EconomyService)
local FuelService = require(script.Parent.FuelService)
local ReplicationService = require(script.Parent.ReplicationService)
local VehicleService = require(script.Parent.VehicleService)
local WorldService = require(script.Parent.WorldService)

local TileService = {}

local limiters: { [Player]: RateLimiter.RateLimiter } = {}
--- Fractional passes carried between ticks, so a slow tool still makes progress.
local progress: { [Player]: number } = {}
local lastIntentAt: { [Player]: number } = {}
--- Reused per call to avoid churning a table every tick per player.
local scratch: { number } = {}

--- Fired as (player, tileIndex, debrisId, levels) for stripe and stat tracking.
local cutSignal = Instance.new("BindableEvent")
TileService.Cut = cutSignal.Event

local TOLERANCE_SQ = GameConfig.MOW_POSITION_TOLERANCE * GameConfig.MOW_POSITION_TOLERANCE

local function limiterFor(player: Player): RateLimiter.RateLimiter
	local limiter = limiters[player]
	if not limiter then
		limiter = RateLimiter.new(GameConfig.MOW_INTENT_MAX_HZ, GameConfig.MOW_INTENT_MAX_HZ)
		limiters[player] = limiter
	end
	return limiter
end

--- The player's actual root position, or nil when they have no character.
local function rootPosition(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

--- True when a section's gate is open for this run.
--- Gates open for everyone at once, so this is a property of the run rather
--- than of the player asking.
local function sectionOpen(sectionId: string): boolean
	if sectionId == "" then
		return false
	end
	return WorldService.isSectionOpen(sectionId)
end

--- Section-open test in the shape `Cutting.pickupTarget` wants: by tile index,
--- not by section id. Hoisted so the hot path is not allocating a closure a
--- dozen times a second per player.
function TileService.isTileOpen(index: number): boolean
	return sectionOpen(WorldService.sectionIdAt(index))
end

--------------------------------------------------------------------
-- The cut
--------------------------------------------------------------------

export type CutResult = {
	tilesTouched: number,
	unitsCollected: number,
	stalled: boolean,
	blockedBySection: string?,
	bagFull: boolean,
}

--[[
	Applies one tick of mowing.

	`passes` is how many swings the tool managed this tick, derived from its rate
	and the time since the last intent. Each pass removes up to `power` height
	levels from every tile in the swath.
]]
function TileService.applyPasses(
	player: Player,
	position: Vector3,
	look: Vector3,
	tool: Types.ToolDef,
	passes: number
): CutResult
	local result: CutResult = {
		tilesTouched = 0,
		unitsCollected = 0,
		stalled = false,
		blockedBySection = nil,
		bagFull = false,
	}

	local grid = WorldService.grid
	local tiles = WorldService.tiles
	local property = WorldService.world
	local run = RunState.find(player)
	if not grid or not tiles or not property or not run or passes <= 0 then
		return result
	end

	-- Two ways to use a tool. A rake or a pair of hands takes one pile at a
	-- time, so it acts on the single tile it is pointed at; a mower or a blower
	-- sweeps everything in the rectangle ahead of it. Everything downstream of
	-- this branch is identical, which is why buying a mower feels like the same
	-- game got wider rather than a different game.
	local indices: { number }
	if tool.mode == "pickup" then
		table.clear(scratch)
		local target =
			Cutting.pickupTarget(grid, tiles, position.X, position.Z, look.X, look.Z, tool, TileService.isTileOpen)
		if target then
			scratch[1] = target
		end
		indices = scratch
	else
		indices = Grid.rasterizeSwath(grid, position.X, position.Z, look.X, look.Z, tool.deck, tool.reach, scratch)
	end

	local levelsAvailable = tool.power * passes
	local yieldMultiplier = Balance.yieldMultiplier(run.upgrades)
	local capacity = BagService.capacity(player)

	for _, index in indices do
		local byte = buffer.readu8(tiles, index - 1)
		local sectionId = WorldService.sectionIdAt(index)
		local owns = sectionOpen(sectionId)
		local space = capacity - BagService.weight(player)

		local outcome = Cutting.evaluate(byte, tool, levelsAvailable, yieldMultiplier, owns, space)

		if outcome.status == "cut" then
			local debrisId = ChunkCodec.debris(byte)
			local height = ChunkCodec.height(byte)

			-- Cutting.evaluate already fitted this to the bag, so the add cannot
			-- come up short and leave units paid for grass that was never cut.
			BagService.add(player, debrisId, outcome.units)
			buffer.writeu8(tiles, index - 1, ChunkCodec.withHeight(byte, height - outcome.levels))
			ReplicationService.markTileDirty(index)
			WorldService.consumeUnits(sectionId, outcome.levels * DebrisConfig.get(debrisId).unitsPerLevel)

			result.tilesTouched += 1
			result.unitsCollected += outcome.units
			cutSignal:Fire(player, index, debrisId, outcome.levels)
		elseif outcome.status == "locked" then
			result.blockedBySection = sectionId
		elseif outcome.status == "overgrown" or outcome.status == "wet" then
			result.stalled = true
		elseif outcome.status == "bagFull" then
			result.bagFull = true
		end
	end

	if result.tilesTouched > 0 then
		DataService.withProfile(player, function(p)
			p.stats.tilesCut += result.tilesTouched
		end)
	end

	return result
end

--------------------------------------------------------------------
-- Intent handling
--------------------------------------------------------------------

local function onMowIntent(player: Player, payload: any)
	if type(payload) ~= "table" then
		return
	end

	local position = payload.position
	local look = payload.look
	local toolId = payload.toolId
	if typeof(position) ~= "Vector3" or typeof(look) ~= "Vector3" or type(toolId) ~= "string" then
		return
	end

	if not limiterFor(player):tryConsume() then
		return
	end

	local run = RunState.find(player)
	if not run then
		return
	end

	-- The client may only mow with a tool it owns and has equipped.
	if run.equippedTool ~= toolId or not run.ownedTools[toolId] then
		return
	end
	local tool = Tools.get(toolId)
	if not tool then
		return
	end

	-- Riding a mower overrides the held tool: the deck under the seat is what
	-- is actually cutting, and it is where the player's power comes from.
	local riding = VehicleService.ridingTool(player)
	if riding then
		tool = riding
	elseif tool.vehicle then
		-- Equipped a vehicle but not sitting on it, so nothing is cutting.
		return
	end

	-- Position is taken from the server's own view of the character; the claimed
	-- position only has to be close enough to be plausible.
	local actual = rootPosition(player)
	if not actual then
		return
	end
	local offset = position - actual
	if offset.X * offset.X + offset.Z * offset.Z > TOLERANCE_SQ then
		return
	end

	local now = os.clock()
	local previous = lastIntentAt[player]
	lastIntentAt[player] = now

	-- Cap the credited interval so a client that stops reporting and resumes
	-- cannot bank a huge single tick.
	local delta = math.clamp(if previous then now - previous else 0, 0, 0.5)
	if delta <= 0 then
		return
	end

	local rate = Balance.effectiveCutRate(tool, run.upgrades, false)
	if rate <= 0 then
		return
	end

	-- Fuel is spent on time actually cutting, not on time merely holding the
	-- tool, so walking the long way round never costs anything.
	if not FuelService.consume(player, tool.id, delta) then
		return
	end

	local carried = (progress[player] or 0) + rate * delta
	local passes = math.floor(carried)
	progress[player] = carried - passes
	if passes <= 0 then
		return
	end

	local result = TileService.applyPasses(player, actual, look, tool, passes)

	if result.blockedBySection and result.tilesTouched == 0 then
		EconomyService.notify(player, "locked", "You have not bought this zone yet", nil)
	elseif result.stalled and result.tilesTouched == 0 then
		EconomyService.notify(player, "stall", `The {tool.name} bogs down here — you need better gear`, nil)
	elseif result.bagFull then
		EconomyService.notify(player, "bagFull", "Bag full — get to the trailer", nil)
	end
end

function TileService.start()
	local intent = Remotes.unreliable(Remotes.MOW_INTENT)
	intent.OnServerEvent:Connect(onMowIntent)

	Players.PlayerRemoving:Connect(function(player)
		limiters[player] = nil
		progress[player] = nil
		lastIntentAt[player] = nil
	end)
end

return TileService
