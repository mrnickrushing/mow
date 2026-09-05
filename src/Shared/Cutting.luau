--!strict
--[[
	Cutting — what one tool does to one tile.

	Pulled out of TileService so the rules that decide whether a cut is allowed,
	and exactly how much comes off, are pure and testable. The server calls this
	for every tile in a swath; the client calls the same predicate when
	predicting, so the two can never disagree about what should have happened.
]]

local DebrisConfig = require(script.Parent.Config.Debris)
local ChunkCodec = require(script.Parent.ChunkCodec)
local GameConfig = require(script.Parent.Config.GameConfig)
local Grid = require(script.Parent.Grid)
local Tools = require(script.Parent.Config.Tools)
local Types = require(script.Parent.Types)

local Cutting = {}

export type Status =
	--- Cut successfully.
	"cut"
	--- Nothing here to cut.
	| "clean"
	--- The player has not bought this zone.
	| "locked"
	--- This tool does not handle this kind of debris.
	| "wrongTool"
	--- Debris is taller than this tool can bite.
	| "overgrown"
	--- Wet, and this tool is too weak to work through it.
	| "wet"
	--- No room left in the bag.
	| "bagFull"

export type Outcome = {
	status: Status,
	--- Height levels removed. Zero for every status but "cut".
	levels: number,
	--- Debris units yielded, already scaled by the yield multiplier.
	units: number,
	--- Bag space those units consume.
	weight: number,
}

local NOTHING: Outcome = { status = "clean", levels = 0, units = 0, weight = 0 }

local function refuse(status: Status): Outcome
	return { status = status, levels = 0, units = 0, weight = 0 }
end

--[[
	Evaluates one tile.

	`levelsAvailable` is how much height the tool's passes could remove this tick,
	and `bagSpace` is the room left in the bag in weight units.

	The bag limit is applied *before* anything is taken, not after. Working it out
	afterwards would let a player bank units for a cut that never landed, which is
	free money.
]]
--[[
	Whether the ground a player is standing on is wet.

	`Balance.effectiveCutRate` has always taken a `wet` flag: it stalls the
	bottom three tiers outright and halves everyone else. Both of the two
	places in the game that ask for a cut rate — the server's mow tick and the
	client's prediction of it — passed `false`, so the halving never once
	happened and a sprinkler was a wall for cheap tools and nothing at all for
	good ones. `Cutting.evaluate` refuses wet *tiles* for the cheap tools
	independently, which is why the stall half looked like it worked.

	The rate is charged per tick rather than per tile, so it is the tile under
	the player that decides it. Shared, because a client predicting a different
	rate from the server is grass that moves and comes back.
]]
function Cutting.isWetAt(grid: Grid.Grid, tiles: buffer, worldX: number, worldZ: number): boolean
	local tx, tz = Grid.worldToTile(grid, worldX, worldZ)
	if not Grid.inBounds(grid, tx, tz) then
		return false
	end
	return ChunkCodec.isWet(buffer.readu8(tiles, Grid.toIndex(grid, tx, tz) - 1))
end

function Cutting.evaluate(
	byte: number,
	tool: Types.ToolDef,
	levelsAvailable: number,
	yieldMultiplier: number,
	ownsZone: boolean,
	bagSpace: number
): Outcome
	local height = ChunkCodec.height(byte)
	if height <= 0 then
		return NOTHING
	end

	if not ownsZone then
		return refuse("locked")
	end

	local debrisId = ChunkCodec.debris(byte)
	if debrisId == DebrisConfig.Empty then
		return NOTHING
	end

	-- Separate "wrong tool for this debris" from "right tool, grass too thick",
	-- because only the second one should tell the player to go buy a mower.
	if not DebrisConfig.canClear(debrisId, tool.category) then
		return refuse("wrongTool")
	end
	if not Tools.canCut(tool, debrisId, height) then
		return refuse(if height > tool.maxHeight then "overgrown" else "wrongTool")
	end

	if ChunkCodec.isWet(byte) and tool.tier <= GameConfig.WET_STALL_MAX_TIER then
		return refuse("wet")
	end

	local wanted = math.min(height, math.floor(levelsAvailable))
	if wanted <= 0 then
		return NOTHING
	end

	local def = DebrisConfig.get(debrisId)
	local unitsPerLevel = def.unitsPerLevel * yieldMultiplier
	if unitsPerLevel <= 0 or def.weight <= 0 then
		return NOTHING
	end

	local weightPerLevel = unitsPerLevel * def.weight
	local levelsThatFit = math.floor(bagSpace / weightPerLevel)
	local levels = math.min(wanted, levelsThatFit)
	if levels <= 0 then
		return refuse("bagFull")
	end

	return {
		status = "cut",
		levels = levels,
		units = levels * unitsPerLevel,
		weight = levels * weightPerLevel,
	}
end

--[[
	The tile a pickup tool is pointed at, or nil when there is nothing to take.

	Pickup tools work one thing at a time: you look at a pile, it lights up, you
	take it. That means the client has to be able to name the same tile the server
	is about to act on, or the outline would sit on one pile while a different one
	vanished. So the choice lives here, next to the rules, and both sides call it.

	Only debris this tool is capable of shifting counts as a target. Pointing a
	rake at a hedge should reach past it to the leaves behind, rather than locking
	onto something the rake will refuse to touch.
]]
function Cutting.pickupTarget(
	grid: Grid.Grid,
	tiles: buffer,
	worldX: number,
	worldZ: number,
	dirX: number,
	dirZ: number,
	tool: Types.ToolDef,
	isOpen: (number) -> boolean
): number?
	return Grid.targetAhead(grid, worldX, worldZ, dirX, dirZ, tool.reach, function(index)
		local byte = buffer.readu8(tiles, index - 1)
		if ChunkCodec.height(byte) <= 0 then
			return false
		end
		local debrisId = ChunkCodec.debris(byte)
		if debrisId == DebrisConfig.Empty then
			return false
		end
		if not DebrisConfig.canClear(debrisId, tool.category) then
			return false
		end
		if not Tools.canCut(tool, debrisId, ChunkCodec.height(byte)) then
			return false
		end
		return isOpen(index)
	end)
end

--[[
	Where the server should cut from: the position the client reported, held
	within `maxLead` studs of where the server sees the character.

	The client predicts from its own character, which leads the server's view
	by a tick or two of replication while moving. Cutting from the server's
	view made the server rasterise a rectangle one row behind the client's, so
	the client's front row was predicted cut, put back by the next chunk flush,
	and cut for real a tick later — a strip that visibly regrew in front of
	every swath tool. Pickup tools never showed it, because both sides pick
	"the first tile ahead with something on it" and land on the same tile
	either way.

	Honouring the report within a short radius keeps the server's bound on
	what a client can claim (it still discards anything outside the wider
	plausibility tolerance) while making both sides agree on the swath.
	Returns the reported point when it is within reach, otherwise the point
	`maxLead` studs from the actual one along the line towards the report.
]]
function Cutting.reconcilePosition(
	actualX: number,
	actualZ: number,
	reportedX: number,
	reportedZ: number,
	maxLead: number
): (number, number)
	local dx, dz = reportedX - actualX, reportedZ - actualZ
	local distance = math.sqrt(dx * dx + dz * dz)
	if distance <= maxLead or distance < 1e-6 then
		return reportedX, reportedZ
	end
	local scale = maxLead / distance
	return actualX + dx * scale, actualZ + dz * scale
end

--- Units a tile still holds, for completion accounting. Ignores yield bonuses,
--- because completion must not move when a player buys Mulching Blades.
function Cutting.unitsOnTile(byte: number): number
	local debrisId = ChunkCodec.debris(byte)
	if debrisId == DebrisConfig.Empty then
		return 0
	end
	return ChunkCodec.height(byte) * DebrisConfig.get(debrisId).unitsPerLevel
end

return Cutting
