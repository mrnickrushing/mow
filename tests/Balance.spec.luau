--!strict
--[[ Balance — the multiplier stack every payout runs through. ]]

local Balance = require("./.build/Shared/Config/Balance")
local GameConfig = require("./.build/Shared/Config/GameConfig")
local Tools = require("./.build/Shared/Config/Tools")
local Upgrades = require("./.build/Shared/Config/Upgrades")
local h = require("./harness")

local function levels(overrides: { [string]: number }?): Balance.UpgradeLevels
	local out: Balance.UpgradeLevels = {}
	for _, def in Upgrades.list do
		out[def.id] = 0
	end
	if overrides then
		for id, value in overrides do
			out[id] = value
		end
	end
	return out
end

return function()
	h.describe("Balance — base state", function()
		h.it("gives a fresh account the documented starting stats", function()
			local stats = Balance.stats(levels())
			h.expectEqual(stats.bagCapacity, GameConfig.BASE_BAG_CAPACITY, "bag")
			h.expectClose(stats.walkSpeed, GameConfig.BASE_WALK_SPEED, 1e-6, "walk speed")
			h.expectClose(stats.cashMultiplier, 1, 1e-6, "cash multiplier")
			h.expectClose(stats.cutRate, 1, 1e-6, "cut rate")
			h.expectEqual(stats.fuelCapacity, GameConfig.BASE_FUEL, "fuel")
			h.expectClose(stats.dumpRadius, GameConfig.BASE_DUMP_RADIUS, 1e-6, "dump radius")
		end)

		h.it("starts without the portable trailer", function()
			h.expectFalse(Balance.hasPortableTrailer(levels()))
			h.expectTrue(Balance.hasPortableTrailer(levels({ trailer = 1 })))
		end)
	end)

	h.describe("Balance — upgrade lines", function()
		h.it("grows bag capacity geometrically", function()
			local one = Balance.bagCapacity(levels({ bag = 1 }))
			local two = Balance.bagCapacity(levels({ bag = 2 }))
			h.expectTrue(one > GameConfig.BASE_BAG_CAPACITY, "level 1 should beat level 0")
			h.expectTrue(two > one, "level 2 should beat level 1")
		end)

		h.it("reaches a meaningful endgame bag", function()
			local def = Upgrades.byId.bag
			local maxed = Balance.bagCapacity(levels({ bag = def.maxLevel }))
			-- An 11-tile deck fills 25 units in well under a second, so the endgame
			-- bag has to be big enough that the walk back is not the whole game.
			h.expectTrue(maxed > 10000, `maxed bag was only {maxed}`)
		end)

		h.it("clamps levels above the maximum", function()
			local def = Upgrades.byId.bag
			local atMax = Balance.bagCapacity(levels({ bag = def.maxLevel }))
			local beyond = Balance.bagCapacity(levels({ bag = def.maxLevel + 25 }))
			h.expectEqual(beyond, atMax, "levels past the cap must not keep paying out")
		end)

		h.it("treats a missing upgrade line as level zero", function()
			h.expectEqual(Balance.bagCapacity({}), GameConfig.BASE_BAG_CAPACITY)
		end)

		h.it("prices each level above the last, and stops at the cap", function()
			for _, def in Upgrades.list do
				local previous = -1
				for level = 0, def.maxLevel - 1 do
					local cost = Upgrades.costAt(def, level)
					h.expectTrue(cost ~= nil, `{def.id} level {level} should have a price`)
					h.expectTrue((cost :: number) > previous, `{def.id} level {level} must cost more than the last`)
					previous = cost :: number
				end
				h.expectTrue(Upgrades.costAt(def, def.maxLevel) == nil, `{def.id} must be unbuyable at max`)
			end
		end)
	end)

	h.describe("Balance — cash multiplier stack", function()
		h.it("stacks passes, VIP and boosts multiplicatively", function()
			local base = Balance.cashMultiplier(levels())
			h.expectClose(base, 1)

			h.expectClose(Balance.cashMultiplier(levels(), { doubleCash = true }), 2)
			h.expectClose(Balance.cashMultiplier(levels(), { vip = true }), 1.25)
			h.expectClose(Balance.cashMultiplier(levels(), { doubleCash = true, vip = true }), 2.5)
			h.expectClose(
				Balance.cashMultiplier(levels(), { doubleCash = true, vip = true, cashBoost = 3, serverBoost = 2 }),
				15
			)
		end)

		h.it("adds the upgrade line on top of purchases", function()
			local def = Upgrades.byId.cash
			local expected = Upgrades.valueAt(def, 4) * 2
			h.expectClose(Balance.cashMultiplier(levels({ cash = 4 }), { doubleCash = true }), expected)
		end)

		h.it("pays out value times units times multiplier", function()
			h.expectClose(Balance.payout(0.02, 100, levels(), { doubleCash = true }), 4)
		end)
	end)

	h.describe("Balance — cut rate and wet grass", function()
		h.it("halves the rate of a tool that can cope with wet grass", function()
			local zeroTurn = Tools.expect("zero_turn")
			local dry = Balance.effectiveCutRate(zeroTurn, levels(), false)
			local wet = Balance.effectiveCutRate(zeroTurn, levels(), true)
			h.expectClose(wet, dry * GameConfig.WET_CUT_PENALTY)
		end)

		h.it("stalls early tools outright in wet grass", function()
			for _, id in { "hands", "reel_mower", "gas_mower" } do
				local tool = Tools.expect(id)
				h.expectClose(Balance.effectiveCutRate(tool, levels(), true), 0, 1e-9, `{id} should stall`)
			end
		end)

		h.it("lets a late tool work through what stalls an early one", function()
			local stalled = Balance.effectiveCutRate(Tools.expect("gas_mower"), levels(), true)
			local working = Balance.effectiveCutRate(Tools.expect("riding_mower"), levels(), true)
			h.expectClose(stalled, 0, 1e-9)
			h.expectTrue(working > 0, "the riding mower must keep going in the wet")
		end)

		h.it("applies the cut speed upgrade", function()
			local tool = Tools.expect("gas_mower")
			local base = Balance.effectiveCutRate(tool, levels(), false)
			local upgraded = Balance.effectiveCutRate(tool, levels({ speed = 5 }), false)
			h.expectTrue(upgraded > base, "cut speed levels must matter")
			h.expectClose(upgraded, tool.rate * Upgrades.valueAt(Upgrades.byId.speed, 5))
		end)
	end)

	h.describe("Balance — stripe bonus", function()
		h.it("scales with tiles and the cash multiplier", function()
			local plain = Balance.stripeBonus(20, levels())
			h.expectClose(plain, 20 * GameConfig.STRIPE_BONUS_PER_TILE)
			h.expectClose(Balance.stripeBonus(20, levels(), { doubleCash = true }), plain * 2)
		end)
	end)
end
