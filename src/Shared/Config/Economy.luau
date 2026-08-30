--!strict
--[[
	Economy — the throughput model shared by the live game and the simulator.

	Both need to answer the same question: given a tool, a set of upgrades and a
	property, how much cash does a player make per second? Keeping that in one
	pure module is what lets `scripts/simulate.luau` predict the progression
	curve exactly as the server pays it, so balance can be tuned without anyone
	grinding for twenty hours.
]]

local Balance = require(script.Parent.Balance)
local DebrisConfig = require(script.Parent.Debris)
local GameConfig = require(script.Parent.GameConfig)
local Types = require(script.Parent.Parent.Types)

local Economy = {}

--[[
	The bag drains itself, paying cash as it goes; nobody walks anywhere to
	sell. This fraction of capacity drains per second, which makes capacity the
	throughput stat: a bigger bag both buffers a burst and pays out faster, and
	a tool that collects faster than the bag drains is throttled to the drain —
	which is exactly the wall the capacity upgrade removes.
]]
Economy.DRAIN_FRACTION_PER_SECOND = 0.25
--- Fraction of a swath already cut on the previous pass. Real play overlaps.
Economy.OVERLAP_WASTE = 0.18

--- Seconds of walking lost to a refuel trip when a gas tool runs dry.
Economy.REFUEL_OVERHEAD = 2.5
Economy.REFUEL_DISTANCE = 45

--[[
	Tiles per second a tool clears completely.

	Bounded by two independent limits — how fast the player physically covers
	ground, and how much area the tool can process per second — and then divided
	by the passes a tile needs.

	Cut Speed feeds both limits: sharper blades swing faster *and* take more
	height per pass, which is what keeps the upgrade line worth buying once a
	player is quick enough to be movement-limited rather than tool-limited.
]]
function Economy.tilesPerSecond(
	tool: Types.ToolDef,
	levels: Balance.UpgradeLevels,
	averageHeight: number,
	mods: Balance.Modifiers?
): number
	local cutMultiplier = Balance.cutRateMultiplier(levels)
	local moveSpeed = if tool.vehicle then tool.vehicle.speed else Balance.walkSpeed(levels, mods)

	-- Area the tool can physically process, in tiles per second.
	local swathTiles = tool.deck * (tool.reach / GameConfig.TILE_SIZE)
	local swingLimit = tool.rate * cutMultiplier * swathTiles

	-- Area the player can actually reach by moving, in tiles per second.
	local moveLimit = moveSpeed / GameConfig.TILE_SIZE * tool.deck

	local coverage = math.min(swingLimit, moveLimit) * (1 - Economy.OVERLAP_WASTE)

	-- Averaged over a field of mixed heights, so a Cut Speed level always shows
	-- up. Rounding up here made the first level of that line change nothing.
	local effectivePower = math.max(tool.power, 1) * cutMultiplier
	local passesPerTile = math.max(averageHeight / effectivePower, 1)
	return coverage / passesPerTile
end

--[[
	Fraction of time a gas tool is actually cutting rather than walking to refuel.

	Manual tools and the Infinite Fuel pass are always 1. Everything else trades
	a slice of its throughput for the trip to the shed, which is what gives the
	Fuel Tank line something to buy back.
]]
function Economy.fuelDutyCycle(tool: Types.ToolDef, levels: Balance.UpgradeLevels, mods: Balance.Modifiers?): number
	local m = mods
	if tool.fuelBurn <= 0 or (m and m.infiniteFuel) then
		return 1
	end
	local runSeconds = Balance.fuelCapacity(levels) / tool.fuelBurn
	local refuelSeconds = Economy.REFUEL_DISTANCE / math.max(Balance.walkSpeed(levels, mods), 1)
		+ Economy.REFUEL_OVERHEAD
	return runSeconds / (runSeconds + refuelSeconds)
end

--[[
	Sustained cash per second, including the walk back to the trailer.

	The bag is the reason this is not simply "tiles per second times value":
	filling it takes time, emptying it takes time, and the ratio between those is
	what makes a capacity upgrade feel so much better than it looks on paper.
]]
function Economy.cashPerSecond(
	tool: Types.ToolDef,
	levels: Balance.UpgradeLevels,
	world: Types.WorldDef,
	debrisId: number,
	averageHeight: number,
	mods: Balance.Modifiers?
): number
	local def = DebrisConfig.get(debrisId)
	local tiles = Economy.tilesPerSecond(tool, levels, averageHeight, mods)
	if tiles <= 0 then
		return 0
	end

	local unitsPerTile = averageHeight * def.unitsPerLevel * Balance.yieldMultiplier(levels)
	local unitsPerSecond = tiles * unitsPerTile
	local bagUnitsPerSecond = unitsPerSecond * def.weight

	-- Sustained throughput is whichever is slower: the tool putting debris in,
	-- or the bag paying it out. The capacity buffer smooths bursts but cannot
	-- beat the drain over a whole section.
	local capacity = Balance.bagCapacity(levels, mods)
	local drainPerSecond = capacity * Economy.DRAIN_FRACTION_PER_SECOND
	local paidWeightPerSecond = math.min(bagUnitsPerSecond, drainPerSecond)
	local paidUnitsPerSecond = paidWeightPerSecond / def.weight

	local cashPerSecond = paidUnitsPerSecond
		* def.value
		* world.payoutMultiplier
		* Balance.cashMultiplier(levels, mods)

	return cashPerSecond * Economy.fuelDutyCycle(tool, levels, mods)
end

--[[
	How much of the clock a player actually spends cutting.

	Clear your unlocked lawn and the round ends early, the map rotates, and you
	lose only the intermission — not the rest of the round. So the cost of
	outgrowing your zones is the dead time between maps, which is what makes zone
	unlocks worth buying without making an early player feel throttled.
]]
function Economy.lawnUtilisation(
	unitsAvailable: number,
	unitsPerSecond: number,
	roundSeconds: number,
	intermissionSeconds: number?
): number
	if unitsPerSecond <= 0 or roundSeconds <= 0 then
		return 0
	end
	local intermission = intermissionSeconds or GameConfig.INTERMISSION_SECONDS
	local clearSeconds = math.min(unitsAvailable / unitsPerSecond, roundSeconds)
	return clearSeconds / (clearSeconds + intermission)
end

--- Debris units a zone holds when freshly grown.
function Economy.sectionUnits(section: Types.ZoneDef, averageHeight: number, yieldMultiplier: number): number
	local tiles = section.rect.w * section.rect.d * section.density
	-- Weighted mean units-per-level across the zone's debris mix.
	local totalWeight, weightedUnits = 0, 0
	for _, entry in section.fill do
		local def = DebrisConfig.get(entry.debris)
		totalWeight += entry.weight
		weightedUnits += entry.weight * def.unitsPerLevel
	end
	local unitsPerLevel = if totalWeight > 0 then weightedUnits / totalWeight else 0
	return tiles * averageHeight * unitsPerLevel * yieldMultiplier
end

--- Cash a single unit of debris is worth on this property, after multipliers.
function Economy.unitValue(
	debrisId: number,
	world: Types.WorldDef,
	levels: Balance.UpgradeLevels,
	mods: Balance.Modifiers?
): number
	local def = DebrisConfig.get(debrisId)
	return def.value * world.payoutMultiplier * Balance.cashMultiplier(levels, mods)
end

return Economy
