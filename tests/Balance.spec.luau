--!strict
--[[ Balance — the multiplier stack every payout runs through. ]]

local Balance = require("./.build/Shared/Config/Balance")
local GameConfig = require("./.build/Shared/Config/GameConfig")
local ToolUpgrades = require("./.build/Shared/Config/ToolUpgrades")
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
			local stats = Balance.stats(levels(), "hands")
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

		h.it("adds a machine's hopper on top of the bag, after the pass doubles it", function()
			local plain = Balance.bagCapacity(levels(), nil, 3000)
			h.expectEqual(plain, GameConfig.BASE_BAG_CAPACITY + 3000, "hopper adds to the bag")
			local doubled = Balance.bagCapacity(levels(), { doubleBag = true }, 3000)
			h.expectEqual(doubled, GameConfig.BASE_BAG_CAPACITY * 2 + 3000, "the pass doubles the bag, not the hopper")
			h.expectEqual(Balance.bagCapacity(levels(), nil, nil), GameConfig.BASE_BAG_CAPACITY, "no machine, no hopper")
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

		h.it("multiplies in the run's section bonus", function()
			-- Three finished sections at +30% each read as +90%, applied on top
			-- of everything else — the world pays better the cleaner it is.
			h.expectClose(Balance.cashMultiplier(levels(), { sectionBoost = 0.9 }), 1.9)
			h.expectClose(
				Balance.cashMultiplier(levels(), { doubleCash = true, sectionBoost = 0.5 }),
				3
			)
			h.expectClose(Balance.cashMultiplier(levels(), { sectionBoost = 0 }), 1)
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

		h.it("applies the tool's own rate slot, and only its own", function()
			local tool = Tools.expect("gas_mower")
			local base = Balance.effectiveCutRate(tool, levels(), false)

			-- Three levels of the gas mower's Throttle speed the gas mower up...
			local upgraded = Balance.effectiveCutRate(tool, levels({ ["gas_mower/rate"] = 3 }), false)
			h.expectTrue(upgraded > base, "the tool's rate slot must matter")
			h.expectClose(upgraded, tool.rate * ToolUpgrades.rateMultiplier({ ["gas_mower/rate"] = 3 }, "gas_mower"))

			-- ...and do nothing for the rake. Tool upgrades belong to tools.
			local rake = Tools.expect("rake")
			h.expectClose(
				Balance.effectiveCutRate(rake, levels({ ["gas_mower/rate"] = 3 }), false),
				Balance.effectiveCutRate(rake, levels(), false)
			)
		end)
	end)

	h.describe("ToolUpgrades — every tool's three slots", function()
		h.it("gives every tool a power, a rate and a yield slot", function()
			for _, tool in Tools.list do
				local tree = ToolUpgrades.treeFor(tool.id)
				h.expectEqual(#tree, 3, `{tool.id} should have three upgrade slots`)
				h.expectEqual(tree[1].slot, "power")
				h.expectEqual(tree[2].slot, "rate")
				h.expectEqual(tree[3].slot, "yield")
				for _, slot in tree do
					h.expectTrue(slot.baseCost > 0, `{slot.key} is free`)
					h.expectTrue(#slot.name > 0, `{slot.key} has no name`)
				end
			end
		end)

		h.it("prices the hand's ladder at the reference's pocket change", function()
			local tree = ToolUpgrades.treeFor("hands")
			h.expectClose(ToolUpgrades.costAt(tree[1], 0) :: number, 1)
			h.expectClose(ToolUpgrades.costAt(tree[2], 0) :: number, 0.5)
			h.expectClose(ToolUpgrades.costAt(tree[3], 0) :: number, 0.75)
		end)

		h.it("stops selling at max level", function()
			local slot = ToolUpgrades.treeFor("hands")[1]
			h.expectEqual(ToolUpgrades.costAt(slot, slot.maxLevel), nil)
			h.expectTrue(ToolUpgrades.costAt(slot, slot.maxLevel - 1) ~= nil)
		end)

		h.it("compounds each level's effect on the multipliers", function()
			local none: { [string]: number } = {}
			h.expectClose(ToolUpgrades.rateMultiplier(none, "hands"), 1)
			h.expectClose(ToolUpgrades.yieldMultiplier(none, "hands"), 1)
			h.expectClose(ToolUpgrades.powerBonus(none, "hands"), 0)

			local some = { ["hands/rate"] = 2, ["hands/power"] = 2, ["hands/yield"] = 1 }
			h.expectTrue(ToolUpgrades.rateMultiplier(some, "hands") > 1)
			h.expectTrue(ToolUpgrades.powerBonus(some, "hands") >= 1, "two power levels should add a full height level")
			h.expectTrue(ToolUpgrades.yieldMultiplier(some, "hands") > 1)
		end)

		h.it("resolves a stored key back to its slot and tool", function()
			local slot, tool = ToolUpgrades.slotByKey("gas_mower/rate")
			h.expectTrue(slot ~= nil and tool ~= nil, "a real key must resolve")
			h.expectEqual((slot :: any).slot, "rate")
			h.expectEqual((tool :: any).id, "gas_mower")

			local badSlot = ToolUpgrades.slotByKey("no_such_tool/rate")
			h.expectEqual(badSlot, nil)
		end)
	end)

	h.describe("Balance — the contribution split", function()
		--[[
			`run.contribution` was counted on every cut and read by nothing,
			and `ROUND_COMPLETION_BONUS` was read by nothing either, so
			finishing a property paid exactly nothing and a team of four
			rewarded whoever stood still as well as the three who mowed.
		]]
		local FULL = GameConfig.ROUND_COMPLETION_BONUS

		h.it("pays a solo finisher the whole pool", function()
			h.expectEqual(Balance.completionTips(500, 500, 1), FULL)
		end)

		h.it("pays a team pulling evenly the same each", function()
			for _, runners in { 2, 3, 4 } do
				local each = 100
				h.expectEqual(
					Balance.completionTips(each, each * runners, runners),
					FULL,
					`a fair share of {runners} should still be a full share`
				)
			end
		end)

		h.it("pays a passenger their share and no more", function()
			-- One player cut a tenth of what the other three did between them.
			local leech, rest = 10, 90
			local total = leech + rest
			h.expectEqual(Balance.completionTips(leech, total, 4), math.floor(FULL * 4 * 0.1 + 0.5))
			h.expectTrue(
				Balance.completionTips(leech, total, 4) < FULL,
				"standing still should not pay a full share"
			)
		end)

		h.it("pays nothing for nothing, and never divides by zero", function()
			h.expectEqual(Balance.completionTips(0, 100, 4), 0)
			h.expectEqual(Balance.completionTips(50, 0, 4), 0)
			h.expectEqual(Balance.completionTips(50, 100, 0), 0)
		end)

		h.it("never pays more than a full share to one player", function()
			-- Contribution can only exceed the total if the totals drifted; the
			-- split should clamp rather than hand out a multiple.
			h.expectEqual(Balance.completionTips(500, 100, 1), FULL)
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
