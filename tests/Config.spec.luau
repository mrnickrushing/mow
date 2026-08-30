--!strict
--[[
	Config integrity.

	These are design assertions rather than code tests: they catch a tool priced
	out of order, a zone that overlaps the house, or a debris type nothing can
	clear — the sort of mistake that is invisible in a diff and painful in a
	playtest.
]]

local Debris = require("./.build/Shared/Config/Debris")
local Monetization = require("./.build/Shared/Config/Monetization")
local Worlds = require("./.build/Shared/Config/Worlds")
local Tools = require("./.build/Shared/Config/Tools")
local Types = require("./.build/Shared/Types")
local Upgrades = require("./.build/Shared/Config/Upgrades")
local h = require("./harness")

local function rectsOverlap(a: Types.Rect, b: Types.Rect): boolean
	return a.x < b.x + b.w and b.x < a.x + a.w and a.z < b.z + b.d and b.z < a.z + a.d
end

local function pointInRect(x: number, z: number, r: Types.Rect): boolean
	return x >= r.x and z >= r.z and x < r.x + r.w and z < r.z + r.d
end

return function()
	h.describe("Config — tools", function()
		h.it("has unique ids and tiers", function()
			local ids, tiers = {}, {}
			for _, tool in Tools.list do
				h.expectFalse(ids[tool.id] == true, `duplicate tool id {tool.id}`)
				h.expectFalse(tiers[tool.tier] == true, `duplicate tier {tool.tier}`)
				ids[tool.id] = true
				tiers[tool.tier] = true
			end
		end)

		h.it("is listed in tier order with non-decreasing prices", function()
			local previousTier, previousCost = -1, -1
			for _, tool in Tools.list do
				h.expectTrue(tool.tier > previousTier, `{tool.id} is out of tier order`)
				h.expectTrue(tool.cost >= previousCost, `{tool.id} costs less than the tier below it`)
				previousTier, previousCost = tool.tier, tool.cost
			end
		end)

		h.it("starts the player on a tool that is free and owned", function()
			local starter = Tools.expect(Tools.STARTER_ID)
			h.expectEqual(starter.cost, 0, "the starter tool must be free")
			h.expectEqual(starter.tier, 0, "the starter tool must be tier 0")
		end)

		h.it("gives every cutting tool something it can clear", function()
			for _, tool in Tools.list do
				-- Grinders and chippers act on trees and stumps, not on tiles.
				if tool.category ~= "Grinder" and tool.category ~= "Chipper" then
					h.expectTrue(#tool.clears > 0, `{tool.id} cannot clear anything`)
				end
			end
		end)

		h.it("only clears debris its category is allowed to handle", function()
			for _, tool in Tools.list do
				for _, debrisId in tool.clears do
					h.expectTrue(
						Debris.canClear(debrisId, tool.category),
						`{tool.id} lists debris {debrisId} that a {tool.category} cannot clear`
					)
				end
			end
		end)

		h.it("refuses tiles taller than the tool can bite", function()
			local hands = Tools.expect("hands")
			h.expectTrue(Tools.canCut(hands, Debris.Grass, hands.maxHeight))
			h.expectFalse(Tools.canCut(hands, Debris.Grass, hands.maxHeight + 1), "overgrowth gate")
			h.expectFalse(Tools.canCut(hands, Debris.Grass, 0), "a clean tile is not cuttable")

			-- Hands handle leaves; a mower is what should refuse them.
			h.expectTrue(Tools.canCut(hands, Debris.Leaves, 1), "hands must clear leaves")
			h.expectFalse(Tools.canCut(Tools.expect("gas_mower"), Debris.Leaves, 1), "a mower must not")
		end)

		h.it("lets bare hands shift anything a tile can hold", function()
			-- The rule that keeps a run from ever being unwinnable: if a section
			-- is full of something the starter cannot touch and the tool for it
			-- is out of reach, the run is dead. Hands are slow, never blocked.
			local starter = Tools.expect(Tools.STARTER_ID)
			local used: { [number]: boolean } = {}
			for _, world in Worlds.list do
				for _, section in world.sections do
					for _, entry in section.fill do
						used[entry.debris] = true
					end
				end
			end

			for debrisId in used do
				h.expectTrue(
					Debris.canClear(debrisId, starter.category),
					`nothing but paid gear can clear {Debris.get(debrisId).name}`
				)
				h.expectTrue(
					Tools.canCut(starter, debrisId, 3),
					`the starter cannot reach full-height {Debris.get(debrisId).name}`
				)
			end
		end)

		h.it("marks exactly the rideable tools as vehicles", function()
			for _, tool in Tools.list do
				local expected = tool.id == "riding_mower" or tool.id == "zero_turn" or tool.id == "commercial_deck"
				h.expectEqual(Tools.isVehicle(tool), expected, `{tool.id} vehicle flag`)
			end
		end)
	end)

	h.describe("Config — debris", function()
		h.it("can be cleared by at least one real tool", function()
			for id = 1, Debris.MAX_ID do
				local reachable = false
				for _, tool in Tools.list do
					for _, clears in tool.clears do
						if clears == id then
							reachable = true
						end
					end
				end
				-- Logs and chips come from trees and stumps rather than tiles.
				if id ~= Debris.Log and id ~= Debris.Chips then
					h.expectTrue(reachable, `nothing in the game can clear {Debris.get(id).name}`)
				end
			end
		end)

		h.it("pays more per bag unit the harder it is to reach", function()
			local grass = Debris.get(Debris.Grass)
			local log = Debris.get(Debris.Log)
			local grassPerUnit = grass.value / grass.weight
			local logPerUnit = log.value / log.weight
			h.expectTrue(logPerUnit > grassPerUnit * 5, "hauling logs must clearly beat mowing grass")
		end)

		h.it("fits every id in the three bits the wire format allows", function()
			h.expectTrue(Debris.MAX_ID <= 7, `MAX_ID {Debris.MAX_ID} will not fit in three bits`)
			for id = 0, Debris.MAX_ID do
				h.expectTrue(Debris.defs[id] ~= nil, `debris id {id} has no definition`)
			end
		end)
	end)

	h.describe("Config — upgrades", function()
		h.it("has unique ids and a reachable maximum", function()
			local ids = {}
			for _, def in Upgrades.list do
				h.expectFalse(ids[def.id] == true, `duplicate upgrade id {def.id}`)
				ids[def.id] = true
				h.expectTrue(def.maxLevel > 0, `{def.id} has no levels`)
				h.expectTrue(def.costGrowth > 1, `{def.id} must get more expensive`)
			end
		end)

		h.it("changes the value at every level it sells", function()
			for _, def in Upgrades.list do
				local previous = Upgrades.valueAt(def, 0)
				for level = 1, def.maxLevel do
					local value = Upgrades.valueAt(def, level)
					h.expectTrue(value > previous, `{def.id} level {level} is worth no more than level {level - 1}`)
					previous = value
				end
			end
		end)
	end)

	h.describe("Config — worlds", function()
		h.it("keeps every section inside the grid", function()
			for _, world in Worlds.list do
				for _, section in world.sections do
					local r = section.rect
					h.expectTrue(r.x >= 0 and r.z >= 0, `{world.id}/{section.id} starts outside the grid`)
					h.expectTrue(
						r.x + r.w <= world.gridWidth and r.z + r.d <= world.gridDepth,
						`{world.id}/{section.id} runs off the grid`
					)
					h.expectTrue(r.w > 0 and r.d > 0, `{world.id}/{section.id} is empty`)
				end
			end
		end)

		h.it("never overlaps two sections", function()
			for _, world in Worlds.list do
				local sections = world.sections
				for i = 1, #sections do
					for j = i + 1, #sections do
						h.expectFalse(
							rectsOverlap(sections[i].rect, sections[j].rect),
							`{world.id}: {sections[i].id} overlaps {sections[j].id}`
						)
					end
				end
			end
		end)

		h.it("only lets a section sit on the house footprint if it is a roof", function()
			for _, world in Worlds.list do
				local house = world.houseRect
				if house then
					for _, section in world.sections do
						if rectsOverlap(section.rect, house) then
							h.expectTrue(
								(section.elevation or 0) > 0,
								`{world.id}: {section.id} overlaps the house at ground level`
							)
							h.expectEqual(section.kind, "roof", `{world.id}: {section.id} is on the house but not a roof`)
						end
					end
				end
			end
		end)

		h.it("keeps the shed, trailer, spawn and exit on open ground", function()
			for _, world in Worlds.list do
				local points: { [string]: any } = {
					shed = world.shed,
					trailer = world.trailer,
					spawn = world.spawn,
					exit = world.exit,
				}
				for label, point in points do
					h.expectTrue(
						point.x >= 0 and point.z >= 0 and point.x < world.gridWidth and point.z < world.gridDepth,
						`{world.id}: {label} is off the grid`
					)
					for _, section in world.sections do
						h.expectFalse(
							pointInRect(point.x, point.z, section.rect),
							`{world.id}: {label} is buried inside {section.id}`
						)
					end
					local house = world.houseRect
					if house then
						h.expectFalse(
							pointInRect(point.x, point.z, house),
							`{world.id}: {label} is inside the house`
						)
					end
				end
			end
		end)

		h.it("gives every world exactly one starting section", function()
			for _, world in Worlds.list do
				local starts = 0
				for _, section in world.sections do
					if Worlds.unlockKind(section) == "start" then
						starts += 1
					end
				end
				h.expectEqual(starts, 1, `{world.id} should have exactly one start`)
			end
		end)

		h.it("charges for nothing: sections are cleared, not bought", function()
			for _, world in Worlds.list do
				for _, section in world.sections do
					h.expectEqual(section.cost, 0, `{world.id}/{section.id} still has a price on it`)
				end
			end
		end)

		h.it("points every gate at a section that exists and comes earlier", function()
			for _, world in Worlds.list do
				local order: { [string]: number } = {}
				for index, section in world.sections do
					order[section.id] = index
				end

				for _, section in world.sections do
					local kind = Worlds.unlockKind(section)
					if kind == "completion" then
						h.expectTrue(section.requires ~= nil, `{world.id}: {section.id} opens on nothing`)
						local required = section.requires :: string
						h.expectTrue(
							Worlds.section(world, required) ~= nil,
							`{world.id}: {section.id} requires unknown section {required}`
						)
						h.expectTrue(
							order[required] < order[section.id],
							`{world.id}: {section.id} depends on {required}, which comes later`
						)
					elseif kind == "button" then
						h.expectTrue(section.buttonIn ~= nil, `{world.id}: {section.id} has no switch location`)
						local host = section.buttonIn :: string
						h.expectTrue(
							Worlds.section(world, host) ~= nil,
							`{world.id}: {section.id} hides its switch in unknown section {host}`
						)
						h.expectFalse(host == section.id, `{world.id}: {section.id} hides its own switch inside itself`)
					end
				end
			end
		end)

		h.it("leaves every required section reachable from the start", function()
			-- A gate chain that forks off an optional section would lock the run.
			for _, world in Worlds.list do
				local reachable: { [string]: boolean } = {}
				reachable[Worlds.startSection(world).id] = true

				for _, section in world.sections do
					local kind = Worlds.unlockKind(section)
					if kind == "completion" and section.requires then
						reachable[section.id] = reachable[section.requires] == true
					elseif kind == "button" then
						reachable[section.id] = reachable[section.buttonIn :: string] == true
					end
				end

				for _, section in Worlds.requiredSections(world) do
					h.expectTrue(reachable[section.id] == true, `{world.id}: {section.id} can never be opened`)
				end
			end
		end)

		h.it("ends on a required section, not an optional one", function()
			for _, world in Worlds.list do
				local final = Worlds.finalSection(world)
				h.expectFalse(final.optional == true, `{world.id} finishes on an optional section`)
			end
		end)

		h.it("scales waves with the players present", function()
			local world = Worlds.expect(Worlds.STARTER_ID)
			local main = Worlds.startSection(world)
			h.expectEqual(Worlds.wavesFor(main, 1), 1, "solo should be one wave")
			h.expectEqual(Worlds.wavesFor(main, 3), 3, "three players, three waves")

			local garage = Worlds.section(world, "garage")
			h.expectTrue(garage ~= nil)
			h.expectEqual(Worlds.wavesFor(garage :: any, 4), 1, "a pinned section ignores headcount")
		end)

		h.it("keeps the work per player the same however many are playing", function()
			-- The point of waves. A section holds U units per wave and needs one
			-- wave per player, so the run's total work is N*U shared between N
			-- people: everyone does U regardless. A full server takes as long as
			-- a solo run rather than finishing in a fraction of the time.
			local world = Worlds.expect(Worlds.STARTER_ID)
			local section = Worlds.startSection(world)

			local solo = Worlds.wavesFor(section, 1) / 1
			for players = 2, 8 do
				local share = Worlds.wavesFor(section, players) / players
				h.expectClose(share, solo, 1e-9, `work per player changed at {players} players`)
			end
		end)

		h.it("climbs in payout and gates later worlds behind earlier ones", function()
			local previousPayout = 0
			for _, world in Worlds.list do
				h.expectTrue(world.payoutMultiplier >= previousPayout, `{world.id} pays less than the world before`)
				previousPayout = world.payoutMultiplier
				if world.requiresWorld then
					h.expectTrue(
						Worlds.get(world.requiresWorld) ~= nil,
						`{world.id} requires unknown world {world.requiresWorld}`
					)
				end
			end
		end)

		h.it("shows only the first world to a new player", function()
			local available = Worlds.availableTo({})
			h.expectEqual(#available, 1, "a new player should see exactly one world")
			h.expectEqual(available[1].id, Worlds.STARTER_ID)

			local afterHouse = Worlds.availableTo({ house = true })
			h.expectTrue(#afterHouse >= 2, "beating the house should open the next one")
		end)

		h.it("uses a density that leaves some bare ground", function()
			for _, world in Worlds.list do
				for _, section in world.sections do
					h.expectTrue(
						section.density > 0 and section.density <= 1,
						`{world.id}/{section.id} density {section.density} is out of range`
					)
				end
			end
		end)
	end)

	h.describe("Config — monetization", function()
		h.it("has unique keys across passes and products", function()
			local keys = {}
			for _, pass in Monetization.passes do
				h.expectFalse(keys[pass.key] == true, `duplicate key {pass.key}`)
				keys[pass.key] = true
			end
			for _, product in Monetization.products do
				h.expectFalse(keys[product.key] == true, `duplicate key {product.key}`)
				keys[product.key] = true
			end
		end)

		h.it("ships with placeholder ids so nothing charges by accident", function()
			for _, pass in Monetization.passes do
				h.expectFalse(Monetization.isConfigured(pass.id), `{pass.key} has a real id committed`)
			end
			for _, product in Monetization.products do
				h.expectFalse(Monetization.isConfigured(product.id), `{product.key} has a real id committed`)
			end
		end)

		h.it("points every rental at a tool that exists", function()
			for _, product in Monetization.products do
				if product.kind == "rental" then
					h.expectTrue(product.toolId ~= nil, `{product.key} is a rental with no tool`)
					h.expectTrue(
						Tools.get(product.toolId :: string) ~= nil,
						`{product.key} rents unknown tool {product.toolId}`
					)
					h.expectTrue((product.seconds or 0) > 0, `{product.key} rents for no time`)
				end
			end
		end)

		h.it("gives every timed product a duration and every boost a multiplier", function()
			for _, product in Monetization.products do
				if product.kind == "cashBoost" or product.kind == "serverBoost" then
					h.expectTrue((product.multiplier or 0) > 1, `{product.key} boosts by nothing`)
					h.expectTrue((product.seconds or 0) > 0, `{product.key} lasts no time`)
				end
			end
		end)

		h.it("sells every paid tool three ways", function()
			-- Run cash, Robux once, Robux forever. A tool priced in Robux on the
			-- tool table but missing a product would show a dead button in the
			-- shop, and a product for a tool with no Robux price would be
			-- unreachable from anywhere.
			for _, tool in Tools.list do
				local runKey, foreverKey = Monetization.toolProductKeys(tool.id)
				local run = Monetization.productByKey[runKey]
				local forever = Monetization.productByKey[foreverKey]

				if tool.cost > 0 and tool.robuxOnce and tool.robuxPermanent then
					h.expectTrue(run ~= nil, `{tool.id} has no one-run product`)
					h.expectTrue(forever ~= nil, `{tool.id} has no permanent product`)
					h.expectEqual((run :: any).toolId, tool.id)
					h.expectEqual((forever :: any).toolId, tool.id)
					h.expectTrue(
						(forever :: any).robux > (run :: any).robux,
						`{tool.id} costs no more to own than to borrow`
					)
					h.expectTrue(
						(tool.robuxWas :: number) > (tool.robuxPermanent :: number),
						`{tool.id} claims a discount off a lower price`
					)
				else
					h.expectTrue(run == nil, `{tool.id} has a product but no Robux price`)
					h.expectTrue(forever == nil, `{tool.id} has a product but no Robux price`)
				end
			end
		end)

		h.it("prices Robux unlocks in step with the cash ladder", function()
			-- Paying should track how long the tool would otherwise take to earn.
			-- A later, dearer tool costing fewer Robux than an earlier one would
			-- make the cheap end of the ladder the worst thing to buy.
			local previousOnce, previousPermanent = 0, 0
			for _, tool in Tools.list do
				if tool.cost > 0 and tool.robuxOnce and tool.robuxPermanent then
					h.expectTrue(
						tool.robuxOnce >= previousOnce,
						`{tool.id} costs less for one run than a cheaper tool`
					)
					h.expectTrue(
						tool.robuxPermanent >= previousPermanent,
						`{tool.id} costs less to own than a cheaper tool`
					)
					previousOnce = tool.robuxOnce
					previousPermanent = tool.robuxPermanent
				end
			end
		end)

		h.it("keeps the free reward loops meaningful", function()
			local rewards = Monetization.rewards
			h.expectTrue(#rewards.dailyStreak >= 7, "a daily streak should run at least a week")
			local previous = 0
			for _, amount in rewards.dailyStreak do
				h.expectTrue(amount > previous, "each streak day must beat the last")
				previous = amount
			end
			h.expectTrue(
				Tools.get(rewards.freeRentalToolId) ~= nil,
				`free rental names unknown tool {rewards.freeRentalToolId}`
			)
		end)
	end)
end
