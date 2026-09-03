--!strict
--[[
	Stripe — what a clean stripe measures.

	The bug this suite exists for: a stripe's length was the count of distinct
	tiles cut on it, so a mower with a wide deck cut many distinct tiles abreast
	on every step and reached the minimum without travelling anywhere. Every
	case below is written in terms of ground covered versus distance held.
]]

local Stripe = require("./.build/Shared/Stripe")
local GameConfig = require("./.build/Shared/Config/GameConfig")
local h = require("./harness")

local TILE = GameConfig.TILE_SIZE

return function()
	h.describe("Stripe — length is a distance", function()
		h.it("is one tile long the moment the first tile is cut", function()
			local s = Stripe.new(0, 1, 0, 0, 0)
			h.expectClose(Stripe.length(s), 0, 1e-9, "nothing cut yet")
			Stripe.record(s, 0, 0, 1, 0)
			h.expectClose(Stripe.length(s), 1, 1e-9, "one tile under the player")
		end)

		h.it("grows with the ground the player covers, not the ticks they spend", function()
			local s = Stripe.new(0, 1, 0, 0, 0)
			-- Ten cuts standing still on ten different tiles, as a wide deck does.
			for index = 1, 10 do
				Stripe.record(s, 0, 0, index, 0)
			end
			h.expectClose(
				Stripe.length(s),
				1,
				1e-9,
				"a deck ten tiles across covers ground sideways, which is not length"
			)

			-- The same ten cuts, walking a tile between each.
			local walked = Stripe.new(0, 1, 0, 0, 0)
			for index = 1, 10 do
				Stripe.record(walked, 0, (index - 1) * TILE, index, 0)
			end
			h.expectClose(Stripe.length(walked), 10, 1e-9, "ten tiles of travel is ten tiles")
		end)

		h.it("counts the same length whatever the deck cuts on the way", function()
			--[[
				The whole point. Two players drive the identical line; one has
				a mower eleven tiles wide and one is using their hands. The
				stripe is the same stripe.
			]]
			local narrow = Stripe.new(1, 0, 0, 0, 0)
			local wide = Stripe.new(1, 0, 0, 0, 0)
			local tile = 0
			for step = 0, 7 do
				local x = step * TILE
				tile += 1
				Stripe.record(narrow, x, 0, tile, 0)
				for across = 1, 11 do
					Stripe.record(wide, x, 0, tile * 100 + across, 0)
				end
			end
			h.expectClose(Stripe.length(narrow), 8, 1e-9, "eight tiles driven by hand")
			h.expectClose(Stripe.length(wide), 8, 1e-9, "eight tiles driven by a wide deck")
		end)

		h.it("does not shorten when the player backs up over ground already cut", function()
			local s = Stripe.new(0, 1, 0, 0, 0)
			Stripe.record(s, 0, 0, 1, 0)
			Stripe.record(s, 0, 9 * TILE, 2, 0)
			h.expectClose(Stripe.length(s), 10, 1e-9, "ten tiles out")
			Stripe.record(s, 0, 2 * TILE, 3, 0)
			h.expectClose(Stripe.length(s), 10, 1e-9, "still ten after reversing")
		end)

		h.it("measures along its own heading, not the axes", function()
			-- A stripe started facing east, walked north: no progress along it.
			local s = Stripe.new(1, 0, 0, 0, 0)
			Stripe.record(s, 0, 0, 1, 0)
			Stripe.record(s, 0, 20 * TILE, 2, 0)
			h.expectClose(Stripe.length(s), 1, 1e-9, "sideways travel is not stripe length")
		end)
	end)

	h.describe("Stripe — when one ends", function()
		h.it("carries on while the heading holds", function()
			local s = Stripe.new(0, 1, 0, 0, 0)
			h.expectTrue(Stripe.continues(s, 0, 1, 0.1), "dead ahead")
			local drift = math.rad(GameConfig.STRIPE_MAX_DRIFT * 0.5)
			h.expectTrue(
				Stripe.continues(s, math.sin(drift), math.cos(drift), 0.1),
				"half the allowed drift is still the same stripe"
			)
		end)

		h.it("breaks on a turn past the drift", function()
			local s = Stripe.new(0, 1, 0, 0, 0)
			local past = math.rad(GameConfig.STRIPE_MAX_DRIFT + 1)
			h.expectTrue(
				not Stripe.continues(s, math.sin(past), math.cos(past), 0.1),
				"a turn past STRIPE_MAX_DRIFT ends the stripe"
			)
			h.expectTrue(not Stripe.continues(s, 0, -1, 0.1), "and the turn at the end of a row does")
		end)

		h.it("breaks when the cutting stops for longer than the timeout", function()
			local s = Stripe.new(0, 1, 0, 0, 0)
			h.expectTrue(Stripe.continues(s, 0, 1, Stripe.IDLE_TIMEOUT * 0.5), "a brief pause is fine")
			h.expectTrue(
				not Stripe.continues(s, 0, 1, Stripe.IDLE_TIMEOUT + 0.01),
				"stopping ends it — which is how a full bag ends one"
			)
		end)
	end)
end
