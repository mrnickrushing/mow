--!strict
--[[
	Economy simulator.

	Plays a virtual, reasonably efficient player through the whole ladder and
	prints how long each tool, upgrade level and property takes to reach. This is
	how the curve gets tuned: a balance change that turns tier 9 into a wall shows
	up here in a second rather than twenty hours into a playtest.

	Run with:  python3 scripts/build_tests.py && luau scripts/simulate.luau

	The player model buys greedily by return on investment — at every step it
	takes whichever purchase adds the most income per dollar spent. That is a
	slightly optimistic player, so treat the times below as a floor.
]]

local Balance = require("../tests/.build/Shared/Config/Balance")
local Debris = require("../tests/.build/Shared/Config/Debris")
local Economy = require("../tests/.build/Shared/Config/Economy")
local Format = require("../tests/.build/Shared/Util/Format")
local Properties = require("../tests/.build/Shared/Config/Properties")
local Tools = require("../tests/.build/Shared/Config/Tools")
local Upgrades = require("../tests/.build/Shared/Config/Upgrades")

--- Typical grass height a player faces, averaged over a property's zones.
local AVERAGE_HEIGHT = 2.4
--- Give up rather than loop forever if the curve becomes unaffordable.
local MAX_STEPS = 4000

type State = {
	cash: number,
	lifetime: number,
	seconds: number,
	levels: { [string]: number },
	owned: { [string]: boolean },
	--- ownedZones[propertyId][zoneId]
	ownedZones: { [string]: { [string]: boolean } },
	toolId: string,
	propertyId: string,
}

local function newState(): State
	local levels: { [string]: number } = {}
	for _, def in Upgrades.list do
		levels[def.id] = 0
	end
	local starter = Properties.expect(Properties.STARTER_ID)
	local starterZones: { [string]: boolean } = {}
	for _, zone in starter.zones do
		if zone.cost <= 0 then
			starterZones[zone.id] = true
		end
	end

	return {
		cash = 0,
		lifetime = 0,
		seconds = 0,
		levels = levels,
		owned = { [Tools.STARTER_ID] = true },
		ownedZones = { [starter.id] = starterZones },
		toolId = Tools.STARTER_ID,
		propertyId = Properties.STARTER_ID,
	}
end

--- True once every paid zone on a property has been bought.
local function propertyFullyOwned(state: State, property): boolean
	local owned = state.ownedZones[property.id]
	if not owned then
		return false
	end
	for _, zone in property.zones do
		if not owned[zone.id] then
			return false
		end
	end
	return true
end

--- The cheapest zone the player has not yet unlocked on a property.
local function nextZone(state: State, property)
	local owned = state.ownedZones[property.id]
	for _, zone in property.zones do
		if not owned or not owned[zone.id] then
			return zone
		end
	end
	return nil
end

--- The best property the player has earned, and the best tool they own for it.
local function refresh(state: State)
	for _, property in Properties.list do
		if state.lifetime >= property.unlockLifetimeCash then
			state.propertyId = property.id
			if not state.ownedZones[property.id] then
				-- The first zone comes free with the unlock, and so does anything
				-- earned rather than bought — the rooftop and the garage are
				-- opened by playing, so a tuning run should count their lawn.
				local owned: { [string]: boolean } = {}
				for _, zone in property.zones do
					if zone.cost <= 0 then
						owned[zone.id] = true
					end
				end
				state.ownedZones[property.id] = owned
			end
		end
	end

	local property = Properties.expect(state.propertyId)
	local best, bestRate = state.toolId, -1
	for id in state.owned do
		local tool = Tools.expect(id)
		-- Grass is the staple debris; judge tools on how fast they clear it.
		if Tools.canCut(tool, Debris.Grass, 1) then
			local rate = Economy.cashPerSecond(tool, state.levels, property, Debris.Grass, AVERAGE_HEIGHT)
			if rate > bestRate then
				best, bestRate = id, rate
			end
		end
	end
	state.toolId = best
end

--- Debris units the player's unlocked zones hold on the current property.
local function availableUnits(state: State, propertyId: string): number
	local property = Properties.expect(propertyId)
	local owned = state.ownedZones[propertyId]
	if not owned then
		return 0
	end
	local yieldMultiplier = Balance.yieldMultiplier(state.levels)
	local total = 0
	for _, zone in property.zones do
		if owned[zone.id] then
			total += Economy.zoneUnits(zone, AVERAGE_HEIGHT, yieldMultiplier)
		end
	end
	return total
end

local function rateFor(state: State, propertyId: string, levels, toolId: string, ownedZones): number
	local property = Properties.expect(propertyId)
	local tool = Tools.expect(toolId)
	local raw = Economy.cashPerSecond(tool, levels, property, Debris.Grass, AVERAGE_HEIGHT)
	if raw <= 0 then
		return 0
	end

	local saved = state.ownedZones
	state.ownedZones = ownedZones
	local units = availableUnits(state, propertyId)
	state.ownedZones = saved

	local unitsPerSecond = Economy.tilesPerSecond(tool, levels, AVERAGE_HEIGHT)
		* AVERAGE_HEIGHT
		* Debris.get(Debris.Grass).unitsPerLevel
		* Balance.yieldMultiplier(levels)
	return raw * Economy.lawnUtilisation(units, unitsPerSecond, property.roundSeconds)
end

local function income(state: State): number
	return rateFor(state, state.propertyId, state.levels, state.toolId, state.ownedZones)
end

--- Income if a hypothetical purchase were made, without mutating `state`.
local function incomeWith(state: State, upgradeId: string?, toolId: string?, zoneId: string?): number
	local levels = state.levels
	if upgradeId then
		levels = table.clone(state.levels)
		levels[upgradeId] += 1
	end

	local tool = Tools.expect(toolId or state.toolId)
	if not Tools.canCut(tool, Debris.Grass, 1) then
		return -1
	end

	local ownedZones = state.ownedZones
	if zoneId then
		ownedZones = table.clone(state.ownedZones)
		local forProperty = table.clone(ownedZones[state.propertyId] or {})
		forProperty[zoneId] = true
		ownedZones[state.propertyId] = forProperty
	end

	return rateFor(state, state.propertyId, levels, tool.id, ownedZones)
end

type Candidate = { kind: string, id: string, cost: number, gain: number, roi: number }

local function candidates(state: State): { Candidate }
	local base = income(state)
	local out: { Candidate } = {}

	for _, def in Upgrades.list do
		local cost = Upgrades.costAt(def, state.levels[def.id])
		if cost then
			local gain = incomeWith(state, def.id, nil) - base
			if gain > 0 then
				table.insert(out, { kind = "upgrade", id = def.id, cost = cost, gain = gain, roi = gain / cost })
			end
		end
	end

	for _, tool in Tools.list do
		if not state.owned[tool.id] and tool.currency == "Cash" and tool.cost > 0 then
			local gain = incomeWith(state, nil, tool.id) - base
			if gain > 0 then
				table.insert(
					out,
					{ kind = "tool", id = tool.id, cost = tool.cost, gain = gain, roi = gain / tool.cost }
				)
			end
		end
	end

	local property = Properties.expect(state.propertyId)
	local owned = state.ownedZones[state.propertyId]
	for _, zone in property.zones do
		if zone.cost > 0 and (not owned or not owned[zone.id]) then
			local gain = incomeWith(state, nil, nil, zone.id) - base
			if gain > 0 then
				table.insert(
					out,
					{ kind = "zone", id = zone.id, cost = zone.cost, gain = gain, roi = gain / zone.cost }
				)
			end
		end
	end

	table.sort(out, function(a, b)
		return a.roi > b.roi
	end)
	return out
end

--- Prints where throughput is currently bottlenecked, to guide tuning.
local function bottleneck(state: State): string
	local tool = Tools.expect(state.toolId)
	local cutMultiplier = Balance.cutRateMultiplier(state.levels)
	local moveSpeed = if tool.vehicle then tool.vehicle.speed else Balance.walkSpeed(state.levels)
	local swing = tool.rate * cutMultiplier * tool.deck * (tool.reach / 4)
	local move = moveSpeed / 4 * tool.deck
	return if swing < move then "tool" else "movement"
end

--------------------------------------------------------------------
-- Run
--------------------------------------------------------------------

local state = newState()
refresh(state)

local milestones: { { at: number, text: string } } = {}
local function note(text: string)
	table.insert(milestones, { at = state.seconds, text = text })
end

local seenProperty: { [string]: boolean } = { [Properties.STARTER_ID] = true }

print("== Mow all the lawns! — progression simulation ==")
print(string.format("start: %s, %s/s", Tools.expect(state.toolId).name, Format.cash(income(state))))
print("")

for step = 1, MAX_STEPS do
	local options = candidates(state)
	local rate = income(state)
	if rate <= 0 then
		note("income stalled at zero")
		break
	end

	local pick: Candidate? = options[1]
	if pick == nil then
		note("nothing left to buy")
		break
	end
	local chosen = pick :: Candidate
	if rate <= 0 then
		note("income stalled at zero")
		break
	end

	-- Time spent earning the purchase price.
	local wait = math.max(pick.cost - state.cash, 0) / rate
	state.seconds += wait
	state.cash += wait * rate
	state.lifetime += wait * rate
	state.cash -= pick.cost

	if chosen.kind == "zone" then
		state.ownedZones[state.propertyId][chosen.id] = true
		local property2 = Properties.expect(state.propertyId)
		if propertyFullyOwned(state, property2) then
			note(string.format("finished every zone on %s", property2.name))
		end
	elseif chosen.kind == "upgrade" then
		state.levels[chosen.id] += 1
		local def = Upgrades.byId[chosen.id]
		local level = state.levels[chosen.id]
		if level == def.maxLevel then
			note(string.format("%s maxed (level %d)", def.name, level))
		end
	else
		state.owned[chosen.id] = true
		note(string.format("bought %s (%s)", Tools.expect(chosen.id).name, Format.cash(chosen.cost)))
	end

	local beforeProperty = state.propertyId
	refresh(state)
	if state.propertyId ~= beforeProperty and not seenProperty[state.propertyId] then
		seenProperty[state.propertyId] = true
		note(string.format("unlocked %s", Properties.expect(state.propertyId).name))
	end

	if step == MAX_STEPS then
		note("hit the step limit")
	end
end

for _, milestone in milestones do
	print(string.format("  %10s   %s", Format.clock(milestone.at), milestone.text))
end

print("")
print(string.format("total play time to max: %s", Format.clock(state.seconds)))
print(string.format("final income:           %s/s", Format.cash(income(state))))
print(string.format("lifetime earned:        %s", Format.cash(state.lifetime)))
print(string.format("final tool:             %s", Tools.expect(state.toolId).name))
print(string.format("final property:         %s", Properties.expect(state.propertyId).name))
print(string.format("final bottleneck:       %s", bottleneck(state)))
print("")
print("upgrade levels:")
for _, def in Upgrades.list do
	print(string.format("  %-16s %d / %d", def.name, state.levels[def.id], def.maxLevel))
end
