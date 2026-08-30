--!strict
--[[
	Balance — the one place where a player's effective stats are computed.

	Every multiplier in the game funnels through here: upgrade levels, gamepasses,
	timed boosts and server-wide events. Keeping the stack in a single pure module
	means the economy simulator can predict progression exactly as the live game
	pays it out, and a balance change never has to be made twice.

	Deliberately free of Roblox dependencies so it can be unit tested.
]]

local GameConfig = require(script.Parent.GameConfig)
local Types = require(script.Parent.Parent.Types)
local Upgrades = require(script.Parent.Upgrades)

local Balance = {}

--- Levels held in each upgrade line, keyed by upgrade id.
export type UpgradeLevels = { [string]: number }

--- Everything outside the upgrade lines that can move a player's numbers.
export type Modifiers = {
	doubleCash: boolean?,
	doubleBag: boolean?,
	fastFeet: boolean?,
	infiniteFuel: boolean?,
	vip: boolean?,
	--- Product-granted cash multiplier, 1 when no boost is running.
	cashBoost: number?,
	--- Server-wide event multiplier, 1 when nothing is running.
	serverBoost: number?,
}

local EMPTY_MODIFIERS: Modifiers = {}

local function level(levels: UpgradeLevels, id: string): number
	return levels[id] or 0
end

local function valueOf(levels: UpgradeLevels, id: string): number
	local def = Upgrades.get(id)
	assert(def, `unknown upgrade line {id}`)
	return Upgrades.valueAt(def, level(levels, id))
end

--------------------------------------------------------------------
-- Individual stats
--------------------------------------------------------------------

function Balance.bagCapacity(levels: UpgradeLevels, mods: Modifiers?): number
	local m = mods or EMPTY_MODIFIERS
	local capacity = valueOf(levels, "bag")
	if m.doubleBag then
		capacity *= 2
	end
	return math.floor(capacity)
end

--- Multiplier applied to a tool's base passes-per-second.
function Balance.cutRateMultiplier(levels: UpgradeLevels): number
	return valueOf(levels, "speed")
end

function Balance.walkSpeed(levels: UpgradeLevels, mods: Modifiers?): number
	local m = mods or EMPTY_MODIFIERS
	local speed = valueOf(levels, "walk")
	if m.fastFeet then
		speed *= 1.3
	end
	return speed
end

--[[
	The full cash multiplier stack.

	Upgrade and VIP bonuses are permanent; the 2x pass, a purchased boost and a
	server-wide event stack multiplicatively on top, so a whale during an event
	feels genuinely fast without any single source being able to run away.
]]
function Balance.cashMultiplier(levels: UpgradeLevels, mods: Modifiers?): number
	local m = mods or EMPTY_MODIFIERS
	local multiplier = valueOf(levels, "cash")
	if m.doubleCash then
		multiplier *= 2
	end
	if m.vip then
		multiplier *= 1.25
	end
	multiplier *= m.cashBoost or 1
	multiplier *= m.serverBoost or 1
	return multiplier
end

--- Multiplies the debris yielded per height level removed.
function Balance.yieldMultiplier(levels: UpgradeLevels): number
	return valueOf(levels, "yield")
end

function Balance.fuelCapacity(levels: UpgradeLevels): number
	return math.floor(valueOf(levels, "fuel"))
end

function Balance.dumpRadius(levels: UpgradeLevels): number
	return valueOf(levels, "trailer")
end

--- True once the player has bought the portable trailer.
function Balance.hasPortableTrailer(levels: UpgradeLevels): boolean
	return level(levels, "trailer") >= Upgrades.PORTABLE_TRAILER_LEVEL
end

--------------------------------------------------------------------
-- Aggregate
--------------------------------------------------------------------

function Balance.stats(levels: UpgradeLevels, mods: Modifiers?): Types.PlayerStats
	return {
		bagCapacity = Balance.bagCapacity(levels, mods),
		cutRate = Balance.cutRateMultiplier(levels),
		yieldMultiplier = Balance.yieldMultiplier(levels),
		walkSpeed = Balance.walkSpeed(levels, mods),
		cashMultiplier = Balance.cashMultiplier(levels, mods),
		fuelCapacity = Balance.fuelCapacity(levels),
		dumpRadius = Balance.dumpRadius(levels),
	}
end

--------------------------------------------------------------------
-- Derived rates
--------------------------------------------------------------------

--[[
	Effective passes per second for a tool.

	Wet grass halves the rate, and tools at or below WET_STALL_MAX_TIER stall
	outright — the sprinkler hazard is meant to send early players looking for a
	better mower, not merely to slow them down.
]]
function Balance.effectiveCutRate(tool: Types.ToolDef, levels: UpgradeLevels, wet: boolean): number
	if wet and tool.tier <= GameConfig.WET_STALL_MAX_TIER then
		return 0
	end
	local rate = tool.rate * Balance.cutRateMultiplier(levels)
	if wet then
		rate *= GameConfig.WET_CUT_PENALTY
	end
	return rate
end

--- Cash paid for `units` of a debris type, after multipliers.
function Balance.payout(unitValue: number, units: number, levels: UpgradeLevels, mods: Modifiers?): number
	return unitValue * units * Balance.cashMultiplier(levels, mods)
end

--- Cash awarded for a completed mow stripe.
function Balance.stripeBonus(tiles: number, levels: UpgradeLevels, mods: Modifiers?): number
	return tiles * GameConfig.STRIPE_BONUS_PER_TILE * Balance.cashMultiplier(levels, mods)
end

return Balance
