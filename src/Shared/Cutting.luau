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
