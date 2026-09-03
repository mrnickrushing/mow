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
local ToolUpgrades = require(script.Parent.ToolUpgrades)
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
	--- Sells the bag from anywhere, rather than only beside the trailer.
	instantDump: boolean?,
	vip: boolean?,
	--- Product-granted cash multiplier, 1 when no boost is running.
	cashBoost: number?,
	--- Server-wide event multiplier, 1 when nothing is running.
	serverBoost: number?,
	--- Additive bonus from sections the run has finished: 0.3 per section by
	--- default, so three cleared sections read as "+90%".
	sectionBoost: number?,
	--- True while a wasp sting is wearing off.
	stung: boolean?,
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

--- Multiplier applied to a tool's base passes-per-second. Cut speed belongs
--- to the tool's own upgrade tree, not to a shed line.
function Balance.cutRateMultiplier(levels: UpgradeLevels, toolId: string): number
	return ToolUpgrades.rateMultiplier(levels, toolId)
end

function Balance.walkSpeed(levels: UpgradeLevels, mods: Modifiers?): number
	local m = mods or EMPTY_MODIFIERS
	local speed = valueOf(levels, "walk")
	if m.fastFeet then
		speed *= 1.3
	end
	-- A sting belongs here rather than being written straight onto the humanoid,
	-- so that anything which recomputes walk speed — buying a Stride level, a
	-- pass changing, respawning — keeps the penalty instead of cancelling it,
	-- and so the sting wearing off cannot restore a speed that has since gone
	-- stale.
	if m.stung then
		speed *= GameConfig.STING_WALK_PENALTY
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
	-- The section bonus multiplies everything else: it is the run's own
	-- progression, and it should feel bigger the more the player has invested.
	multiplier *= 1 + (m.sectionBoost or 0)
	return multiplier
end

--- Multiplies the debris yielded per height level removed. Per tool, like
--- cut speed: a mulching upgrade bought for the mower says nothing about the
--- rake.
function Balance.yieldMultiplier(levels: UpgradeLevels, toolId: string): number
	return ToolUpgrades.yieldMultiplier(levels, toolId)
end

--- Height-levels one pass of this tool removes, with its Power slot applied.
function Balance.toolPower(tool: Types.ToolDef, levels: UpgradeLevels): number
	return tool.power + ToolUpgrades.powerBonus(levels, tool.id)
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

--- The player-wide stats. Cut rate and yield are per-tool now, so `toolId`
--- names whose tree to read — pass the equipped tool.
function Balance.stats(levels: UpgradeLevels, toolId: string, mods: Modifiers?): Types.PlayerStats
	return {
		bagCapacity = Balance.bagCapacity(levels, mods),
		cutRate = Balance.cutRateMultiplier(levels, toolId),
		yieldMultiplier = Balance.yieldMultiplier(levels, toolId),
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
	local rate = tool.rate * Balance.cutRateMultiplier(levels, tool.id)
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

--[[
	One player's share of the tips paid out for finishing a property.

	The pool is `ROUND_COMPLETION_BONUS` per person in the run, divided by
	share of the work actually done — so finishing solo earns the whole of it,
	a team of four pulling evenly earns it each, and somebody who cut a tenth
	of what the others did earns a tenth. That last part is the point: a team
	of four used to reward whoever stood still exactly as well as the three who
	mowed.
]]
function Balance.completionTips(contribution: number, total: number, runners: number): number
	if total <= 0 or runners <= 0 or contribution <= 0 then
		return 0
	end
	local share = math.min(contribution / total, 1)
	return math.floor(GameConfig.ROUND_COMPLETION_BONUS * runners * share + 0.5)
end

return Balance
