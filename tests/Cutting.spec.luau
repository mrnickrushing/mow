--!strict
--[[ Cutting — the rules that decide what one tool does to one tile. ]]

local ChunkCodec = require("./.build/Shared/ChunkCodec")
local Cutting = require("./.build/Shared/Cutting")
local Debris = require("./.build/Shared/Config/Debris")
local GameConfig = require("./.build/Shared/Config/GameConfig")
local Tools = require("./.build/Shared/Config/Tools")
local h = require("./harness")

local ROOMY = 1e9

local function grassTile(height: number, wet: boolean?): number
	return ChunkCodec.pack(Debris.Grass, height, wet)
end

return function()
	h.describe("Cutting — permission", function()
		h.it("refuses a zone the player has not bought", function()
			local outcome = Cutting.evaluate(grassTile(3), Tools.expect("gas_mower"), 3, 1, false, ROOMY)
			h.expectEqual(outcome.status, "locked")
			h.expectEqual(outcome.levels, 0)
			h.expectEqual(outcome.units, 0)
		end)

		h.it("reports a clean tile as nothing to do", function()
			local outcome = Cutting.evaluate(grassTile(0), Tools.expect("gas_mower"), 3, 1, true, ROOMY)
			h.expectEqual(outcome.status, "clean")
			h.expectEqual(outcome.levels, 0)
		end)

		h.it("refuses debris the tool does not handle", function()
			local leaves = ChunkCodec.pack(Debris.Leaves, 2, false)
			local outcome = Cutting.evaluate(leaves, Tools.expect("gas_mower"), 3, 1, true, ROOMY)
			h.expectEqual(outcome.status, "wrongTool")
		end)

		h.it("distinguishes overgrown grass from the wrong tool entirely", function()
			-- A reel mower reaches height 2, so height 3 is the overgrowth gate
			-- rather than a mismatch. Hands are never gated, by design.
			local reel = Tools.expect("reel_mower")
			h.expectEqual(
				Cutting.evaluate(grassTile(3), reel, 3, 1, true, ROOMY).status,
				"overgrown",
				"tall grass should read as overgrown"
			)

			-- Hands do handle leaves, so a genuine mismatch needs a mower on them.
			local leaves = ChunkCodec.pack(Debris.Leaves, 1, false)
			h.expectEqual(Cutting.evaluate(leaves, Tools.expect("gas_mower"), 3, 1, true, ROOMY).status, "wrongTool")
			h.expectEqual(
				Cutting.evaluate(leaves, Tools.expect("hands"), 3, 1, true, ROOMY).status,
				"cut",
				"hands clear leaves"
			)
		end)

		h.it("stalls a weak tool in wet grass but not a strong one", function()
			local wet = grassTile(2, true)
			h.expectEqual(Cutting.evaluate(wet, Tools.expect("gas_mower"), 3, 1, true, ROOMY).status, "wet")
			h.expectEqual(Cutting.evaluate(wet, Tools.expect("riding_mower"), 3, 1, true, ROOMY).status, "cut")
		end)

		h.it("matches the configured stall tier exactly", function()
			local wet = grassTile(2, true)
			for _, tool in Tools.list do
				if tool.category == "Mower" and tool.maxHeight >= 2 then
					local outcome = Cutting.evaluate(wet, tool, 3, 1, true, ROOMY)
					local shouldStall = tool.tier <= GameConfig.WET_STALL_MAX_TIER
					h.expectEqual(outcome.status == "wet", shouldStall, `{tool.id} wet behaviour`)
				end
			end
		end)
	end)

	h.describe("Cutting — how much comes off", function()
		h.it("takes at most the height that is there", function()
			local outcome = Cutting.evaluate(grassTile(1), Tools.expect("riding_mower"), 3, 1, true, ROOMY)
			h.expectEqual(outcome.levels, 1, "cannot cut below bare ground")
		end)

		h.it("takes at most what the tool's passes allow", function()
			-- A reel mower has power 1 and reaches height 2, so one pass on a
			-- height-2 tile takes exactly one level and leaves the rest standing.
			local outcome = Cutting.evaluate(grassTile(2), Tools.expect("reel_mower"), 1, 1, true, ROOMY)
			h.expectEqual(outcome.status, "cut")
			h.expectEqual(outcome.levels, 1)
		end)

		h.it("needs several passes for a low-power tool to finish a tile", function()
			local reel = Tools.expect("reel_mower")
			local byte = grassTile(2)
			local passes = 0
			while ChunkCodec.height(byte) > 0 and passes < 10 do
				local outcome = Cutting.evaluate(byte, reel, reel.power, 1, true, ROOMY)
				h.expectEqual(outcome.status, "cut", `pass {passes + 1}`)
				byte = ChunkCodec.withHeight(byte, ChunkCodec.height(byte) - outcome.levels)
				passes += 1
			end
			h.expectEqual(passes, 2, "a power-1 tool should need two passes on height 2")
			h.expectEqual(ChunkCodec.height(byte), 0)
		end)

		h.it("clears tall grass in one bite with a powerful tool", function()
			local outcome = Cutting.evaluate(grassTile(3), Tools.expect("riding_mower"), 3, 1, true, ROOMY)
			h.expectEqual(outcome.levels, 3)
		end)

		h.it("yields units scaled by the mulching multiplier", function()
			local def = Debris.get(Debris.Grass)
			local plain = Cutting.evaluate(grassTile(3), Tools.expect("riding_mower"), 3, 1, true, ROOMY)
			h.expectClose(plain.units, 3 * def.unitsPerLevel)

			local mulched = Cutting.evaluate(grassTile(3), Tools.expect("riding_mower"), 3, 2, true, ROOMY)
			h.expectClose(mulched.units, 3 * def.unitsPerLevel * 2)
		end)

		h.it("reports the bag weight those units consume", function()
			local def = Debris.get(Debris.Grass)
			local outcome = Cutting.evaluate(grassTile(3), Tools.expect("riding_mower"), 3, 1, true, ROOMY)
			h.expectClose(outcome.weight, outcome.units * def.weight)
		end)
	end)

	h.describe("Cutting — the bag limit", function()
		h.it("refuses outright when the bag has no room", function()
			local outcome = Cutting.evaluate(grassTile(3), Tools.expect("riding_mower"), 3, 1, true, 0)
			h.expectEqual(outcome.status, "bagFull")
			h.expectEqual(outcome.levels, 0)
			h.expectEqual(outcome.units, 0, "a full bag must not bank units")
		end)

		h.it("never yields units without removing grass", function()
			-- The bug this guards: fitting the bag *after* taking the units let a
			-- player bank a payout for a cut that never landed.
			local def = Debris.get(Debris.Grass)
			local weightPerLevel = def.unitsPerLevel * def.weight
			for space = 0, weightPerLevel * 4 do
				local outcome = Cutting.evaluate(grassTile(3), Tools.expect("riding_mower"), 3, 1, true, space)
				if outcome.units > 0 then
					h.expectTrue(outcome.levels > 0, `space {space}: paid units for no cut`)
				end
				if outcome.levels == 0 then
					h.expectEqual(outcome.units, 0, `space {space}: units without levels`)
				end
			end
		end)

		h.it("cuts only as many levels as the bag can carry", function()
			local def = Debris.get(Debris.Grass)
			local weightPerLevel = def.unitsPerLevel * def.weight
			-- Room for exactly two levels.
			local outcome = Cutting.evaluate(grassTile(3), Tools.expect("riding_mower"), 3, 1, true, weightPerLevel * 2)
			h.expectEqual(outcome.levels, 2)
			h.expectClose(outcome.weight, weightPerLevel * 2)
		end)

		h.it("never claims more bag space than it was offered", function()
			local def = Debris.get(Debris.Grass)
			local weightPerLevel = def.unitsPerLevel * def.weight
			for space = 0, weightPerLevel * 4 do
				local outcome = Cutting.evaluate(grassTile(3), Tools.expect("riding_mower"), 3, 1.7, true, space)
				h.expectTrue(outcome.weight <= space, `space {space}: took {outcome.weight}`)
			end
		end)

		h.it("accounts for heavier debris taking more room", function()
			local sticks = ChunkCodec.pack(Debris.Sticks, 2, false)
			local def = Debris.get(Debris.Sticks)
			local weightPerLevel = def.unitsPerLevel * def.weight
			local outcome = Cutting.evaluate(sticks, Tools.expect("chainsaw"), 3, 1, true, weightPerLevel)
			h.expectEqual(outcome.levels, 1, "one level of sticks should just fit")
			h.expectClose(outcome.weight, weightPerLevel)
		end)
	end)

	h.describe("Cutting — completion accounting", function()
		h.it("counts units on a tile independent of yield upgrades", function()
			local def = Debris.get(Debris.Grass)
			h.expectClose(Cutting.unitsOnTile(grassTile(3)), 3 * def.unitsPerLevel)
			h.expectClose(Cutting.unitsOnTile(grassTile(0)), 0)
		end)

		h.it("ignores bare ground", function()
			h.expectClose(Cutting.unitsOnTile(ChunkCodec.pack(Debris.Empty, 3, false)), 0)
		end)
	end)
end
