--!strict
--[[
	Run simulator.

	Plays one world from nothing and reports whether it can be finished inside
	the clock, which section the run stalls in, and what gear a player has by
	the end. Runs reset, so the question is no longer "how long to max out" but
	"is this beatable, and does it stay tense the whole way".

	Run with:  python3 scripts/build_tests.py && luau scripts/simulate.luau

	The virtual player buys greedily by return on investment and never wastes a
	second, so treat every time here as a floor.
]]

local Balance = require("../tests/.build/Shared/Config/Balance")
local Debris = require("../tests/.build/Shared/Config/Debris")
local Economy = require("../tests/.build/Shared/Config/Economy")
local Format = require("../tests/.build/Shared/Util/Format")
local Tools = require("../tests/.build/Shared/Config/Tools")
local Upgrades = require("../tests/.build/Shared/Config/Upgrades")
local Worlds = require("../tests/.build/Shared/Config/Worlds")

--- Typical debris height a player faces.
local AVERAGE_HEIGHT = 2.4
--- Players in the run. Waves scale with this, so more hands is more work.
local PLAYERS = tonumber(({ ... })[1]) or 1
local MAX_STEPS = 3000

type State = {
	cash: number,
	seconds: number,
	levels: { [string]: number },
	owned: { [string]: boolean },
	toolId: string,
}

local function newState(): State
	local levels: { [string]: number } = {}
	for _, def in Upgrades.list do
		levels[def.id] = 0
	end
	return {
		cash = 0,
		seconds = 0,
		levels = levels,
		owned = { [Tools.STARTER_ID] = true },
		toolId = Tools.STARTER_ID,
	}
end

--- The best tool the player owns for clearing `debrisId`.
local function bestTool(state: State, world, debrisId: number): string?
	local best, bestRate = nil, -1
	for id in state.owned do
		local tool = Tools.expect(id)
		if Tools.canCut(tool, debrisId, 1) then
			local rate = Economy.cashPerSecond(tool, state.levels, world, debrisId, AVERAGE_HEIGHT)
			if rate > bestRate then
				best, bestRate = id, rate
			end
		end
	end
	return best
end

--- Cash per second clearing `debrisId` with the best owned tool.
local function income(state: State, world, debrisId: number): number
	local id = bestTool(state, world, debrisId)
	if not id then
		return 0
	end
	return Economy.cashPerSecond(Tools.expect(id), state.levels, world, debrisId, AVERAGE_HEIGHT)
end

--- Debris units a section holds, and the kind that dominates it.
local function sectionUnits(section, yieldMultiplier: number): (number, number)
	local heaviest, heaviestWeight = Debris.Grass, -1
	for _, entry in section.fill do
		if entry.weight > heaviestWeight then
			heaviest, heaviestWeight = entry.debris, entry.weight
		end
	end
	return Economy.sectionUnits(section, yieldMultiplier), heaviest
end

type Candidate = { kind: string, id: string, cost: number, gain: number, roi: number }

--- Purchases worth making right now, best return first.
local function candidates(state: State, world, debrisId: number): { Candidate }
	local base = income(state, world, debrisId)
	local out: { Candidate } = {}

	for _, def in Upgrades.list do
		local cost = Upgrades.costAt(def, state.levels[def.id])
		if cost then
			local levels = table.clone(state.levels)
			levels[def.id] += 1
			local toolId = bestTool(state, world, debrisId)
			if toolId then
				local gain = Economy.cashPerSecond(Tools.expect(toolId), levels, world, debrisId, AVERAGE_HEIGHT) - base
				if gain > 0 then
					table.insert(out, { kind = "upgrade", id = def.id, cost = cost, gain = gain, roi = gain / cost })
				end
			end
		end
	end

	for _, tool in Tools.list do
		if not state.owned[tool.id] and tool.currency == "Cash" and tool.cost > 0 then
			if Tools.canCut(tool, debrisId, 1) then
				local gain = Economy.cashPerSecond(tool, state.levels, world, debrisId, AVERAGE_HEIGHT) - base
				if gain > 0 then
					table.insert(
						out,
						{ kind = "tool", id = tool.id, cost = tool.cost, gain = gain, roi = gain / tool.cost }
					)
				end
			end
		end
	end

	table.sort(out, function(a, b)
		return a.roi > b.roi
	end)
	return out
end

--------------------------------------------------------------------
-- Run
--------------------------------------------------------------------

local function simulate(world)
	local state = newState()
	local lines: { string } = {}
	local stalled: string? = nil

	for _, section in world.sections do
		if section.optional then
			continue
		end

		-- A cash gate is paid at the door before any of its work can start. If
		-- the money is not there by the time the player reaches it, that is a
		-- config bug worth failing loudly on, not waiting through.
		if Worlds.unlockKind(section) == "cash" then
			if state.cash < section.cost then
				stalled = string.format(
					"%s: gate costs %s, has %s",
					section.name,
					Format.cash(section.cost),
					Format.cash(state.cash)
				)
				break
			end
			state.cash -= section.cost
		end

		local waves = Worlds.wavesFor(section, PLAYERS)
		local sectionStart = state.seconds

		for wave = 1, waves do
			local yieldMultiplier = Balance.yieldMultiplier(state.levels)
			local units, debrisId = sectionUnits(section, yieldMultiplier)
			-- The work splits between everyone present.
			units /= PLAYERS

			local cleared = 0
			local guard = 0

			while cleared < units and guard < MAX_STEPS do
				guard += 1

				local toolId = bestTool(state, world, debrisId)
				if not toolId then
					-- Nothing in hand touches this. A player would go and buy the
					-- tool for it, so the simulator does too; only if it is
					-- unaffordable is the run genuinely walled.
					local cheapest, cheapestCost = nil, math.huge
					for _, tool in Tools.list do
						if
							not state.owned[tool.id]
							and tool.currency == "Cash"
							and Tools.canCut(tool, debrisId, 1)
							and tool.cost < cheapestCost
						then
							cheapest, cheapestCost = tool.id, tool.cost
						end
					end

					if cheapest and state.cash >= cheapestCost then
						state.cash -= cheapestCost
						state.owned[cheapest] = true
						toolId = cheapest
					else
						stalled = string.format(
							"%s: needs %s for %s, has %s",
							section.name,
							if cheapest then Tools.expect(cheapest).name else "a tool that does not exist",
							Debris.get(debrisId).name,
							Format.cash(state.cash)
						)
						break
					end
				end

				local tool = Tools.expect(toolId)
				state.toolId = toolId

				local perSecond = Economy.tilesPerSecond(tool, state.levels, AVERAGE_HEIGHT)
					* AVERAGE_HEIGHT
					* Debris.get(debrisId).unitsPerLevel
					* yieldMultiplier
				if perSecond <= 0 then
					stalled = `{section.name}: throughput fell to zero`
					break
				end

				local rate = income(state, world, debrisId)
				local options = candidates(state, world, debrisId)
				local pick = options[1]

				-- Buy only what pays for itself inside the work that is left.
				local remaining = (units - cleared) / perSecond
				if pick and rate > 0 and pick.gain * remaining > pick.cost then
					local wait = math.max(pick.cost - state.cash, 0) / rate
					state.seconds += wait
					state.cash += wait * rate - pick.cost
					cleared += wait * perSecond

					if pick.kind == "upgrade" then
						state.levels[pick.id] += 1
					else
						state.owned[pick.id] = true
					end
				else
					local seconds = (units - cleared) / perSecond
					state.seconds += seconds
					state.cash += seconds * rate
					cleared = units
				end
			end

			if stalled then
				break
			end
		end

		table.insert(
			lines,
			string.format(
				"  %9s   %-16s %d wave%s, %s",
				Format.clock(state.seconds),
				section.name,
				waves,
				if waves == 1 then "" else "s",
				Format.clock(state.seconds - sectionStart)
			)
		)

		if stalled then
			break
		end
	end

	return state, lines, stalled
end

--------------------------------------------------------------------
-- Report
--------------------------------------------------------------------

print(string.format("== Run simulation, %d player%s ==", PLAYERS, if PLAYERS == 1 then "" else "s"))

for _, world in Worlds.list do
	local state, lines, stalled = simulate(world)
	local budget = world.runSeconds

	print("")
	print(string.format("%s  (%s, clock %s)", world.name, world.difficulty, Format.clock(budget)))
	for _, line in lines do
		print(line)
	end

	if stalled then
		print(string.format("  STALLED — %s", stalled))
	elseif state.seconds > budget then
		print(string.format("  FAILED — needs %s, has %s", Format.clock(state.seconds), Format.clock(budget)))
	else
		print(
			string.format(
				"  beaten in %s, %s to spare (%.0f%% of the clock used)",
				Format.clock(state.seconds),
				Format.clock(budget - state.seconds),
				state.seconds / budget * 100
			)
		)
	end
	print(string.format("  finished holding %s, %s banked", Tools.expect(state.toolId).name, Format.cash(state.cash)))
end
