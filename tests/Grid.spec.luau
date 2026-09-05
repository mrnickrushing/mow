--!strict
--[[ Grid — index math, chunk math and swath rasterisation. ]]

local Grid = require("./.build/Shared/Grid")
local GameConfig = require("./.build/Shared/Config/GameConfig")
local h = require("./harness")

local TILE = GameConfig.TILE_SIZE

return function()
	h.describe("Grid — indexing", function()
		h.it("round-trips tile coordinates through linear indices", function()
			local grid = Grid.new(37, 23)
			for tz = 0, grid.depth - 1 do
				for tx = 0, grid.width - 1 do
					local index = Grid.toIndex(grid, tx, tz)
					local bx, bz = Grid.fromIndex(grid, index)
					h.expectEqual(bx, tx, `x at ({tx},{tz})`)
					h.expectEqual(bz, tz, `z at ({tx},{tz})`)
				end
			end
		end)

		h.it("produces one-based indices covering exactly the tile count", function()
			local grid = Grid.new(8, 5)
			h.expectEqual(Grid.toIndex(grid, 0, 0), 1, "first tile")
			h.expectEqual(Grid.toIndex(grid, 7, 4), 40, "last tile")
			h.expectEqual(Grid.tileCount(grid), 40)
		end)

		h.it("rejects out-of-bounds coordinates", function()
			local grid = Grid.new(10, 10)
			h.expectTrue(Grid.inBounds(grid, 0, 0))
			h.expectTrue(Grid.inBounds(grid, 9, 9))
			h.expectFalse(Grid.inBounds(grid, -1, 0))
			h.expectFalse(Grid.inBounds(grid, 10, 0))
			h.expectFalse(Grid.inBounds(grid, 0, 10))
		end)
	end)

	h.describe("Grid — world space", function()
		h.it("maps a tile centre back to the same tile", function()
			local grid = Grid.new(16, 16)
			for _, pair in { { 0, 0 }, { 5, 9 }, { 15, 15 } } do
				local wx, wz = Grid.tileToWorld(grid, pair[1], pair[2])
				local tx, tz = Grid.worldToTile(grid, wx, wz)
				h.expectEqual(tx, pair[1])
				h.expectEqual(tz, pair[2])
			end
		end)

		h.it("honours a non-zero origin", function()
			local grid = Grid.new(16, 16, -100, 250)
			local wx, wz = Grid.tileToWorld(grid, 0, 0)
			h.expectClose(wx, -100 + TILE * 0.5)
			h.expectClose(wz, 250 + TILE * 0.5)
			local tx, tz = Grid.worldToTile(grid, wx, wz)
			h.expectEqual(tx, 0)
			h.expectEqual(tz, 0)
		end)

		h.it("puts a position on a tile boundary in the higher tile", function()
			local grid = Grid.new(16, 16)
			local tx, tz = Grid.worldToTile(grid, TILE, TILE)
			h.expectEqual(tx, 1)
			h.expectEqual(tz, 1)
		end)
	end)

	h.describe("Grid — chunks", function()
		h.it("round-trips chunk coordinates", function()
			local grid = Grid.new(40, 24)
			for cz = 0, grid.chunksZ - 1 do
				for cx = 0, grid.chunksX - 1 do
					local index = Grid.chunkIndex(grid, cx, cz)
					local bx, bz = Grid.chunkFromIndex(grid, index)
					h.expectEqual(bx, cx)
					h.expectEqual(bz, cz)
				end
			end
		end)

		h.it("rounds partial edge chunks up", function()
			local grid = Grid.new(9, 9) -- chunkTiles is 8, so 2x2 chunks
			h.expectEqual(grid.chunksX, 2)
			h.expectEqual(grid.chunksZ, 2)
			h.expectEqual(Grid.chunkCount(grid), 4)
		end)

		h.it("agrees between chunkOf and chunkOfTileIndex", function()
			local grid = Grid.new(20, 20)
			for tz = 0, 19, 3 do
				for tx = 0, 19, 3 do
					local cx, cz = Grid.chunkOf(grid, tx, tz)
					local viaTile = Grid.chunkOfTileIndex(grid, Grid.toIndex(grid, tx, tz))
					h.expectEqual(viaTile, Grid.chunkIndex(grid, cx, cz), `tile ({tx},{tz})`)
				end
			end
		end)
	end)

	h.describe("Grid — sweeping the deck along a path", function()
		local out: { number } = {}
		local scratch: { number } = {}

		local function rows(grid: any, indices: { number }): { [number]: boolean }
			local seen = {}
			for _, index in indices do
				local _, tz = Grid.fromIndex(grid, index)
				seen[tz] = true
			end
			return seen
		end

		h.it("is exactly a swath when the machine has not moved", function()
			local grid = Grid.new(30, 60)
			local wx, wz = Grid.tileToWorld(grid, 15, 10)
			local swath = Grid.rasterizeSwath(grid, wx, wz, 0, 1, 3, TILE * 3, {})
			local sweep = Grid.rasterizeSweep(grid, wx, wz, wx, wz, 0, 1, 3, TILE * 3, out, scratch)
			h.expectSameSet(sweep, swath, "no travel, no difference")
		end)

		h.it("leaves no row uncut across a gap longer than the deck's reach", function()
			-- A ride-on at 48 studs a second loses three tenths of a second of
			-- intents: fourteen studs of travel against a fourteen-stud reach.
			-- Stamping the deck at each end would miss the rows in between.
			local grid = Grid.new(30, 60)
			local x0, z0 = Grid.tileToWorld(grid, 15, 10)
			local reach = TILE * 3.5
			local x1, z1 = x0, z0 + reach + TILE * 2
			local sweep = Grid.rasterizeSweep(grid, x0, z0, x1, z1, 0, 1, 3, reach, out, scratch)

			local covered = rows(grid, sweep)
			local firstRow = select(2, Grid.worldToTile(grid, x0, z0))
			local lastRow = select(2, Grid.worldToTile(grid, x1, z1 + reach))
			for tz = firstRow, lastRow do
				h.expectTrue(covered[tz] == true, `row {tz} was skipped`)
			end
		end)

		h.it("never lists a tile twice", function()
			local grid = Grid.new(30, 60)
			local x0, z0 = Grid.tileToWorld(grid, 15, 10)
			local sweep = Grid.rasterizeSweep(grid, x0, z0, x0, z0 + TILE * 6, 0, 1, 5, TILE * 3, out, scratch)
			local seen = {}
			for _, index in sweep do
				h.expectFalse(seen[index] == true, `tile {index} listed twice`)
				seen[index] = true
			end
		end)

		h.it("covers everything either end's swath would have", function()
			local grid = Grid.new(40, 40)
			local x0, z0 = Grid.tileToWorld(grid, 10, 10)
			local x1, z1 = Grid.tileToWorld(grid, 22, 18)
			local dirX, dirZ = x1 - x0, z1 - z0
			local sweep = Grid.rasterizeSweep(grid, x0, z0, x1, z1, dirX, dirZ, 3, TILE * 2, out, scratch)
			local inSweep = {}
			for _, index in sweep do
				inSweep[index] = true
			end
			for _, index in Grid.rasterizeSwath(grid, x0, z0, dirX, dirZ, 3, TILE * 2, {}) do
				h.expectTrue(inSweep[index] == true, `start swath tile {index} missing`)
			end
			for _, index in Grid.rasterizeSwath(grid, x1, z1, dirX, dirZ, 3, TILE * 2, {}) do
				h.expectTrue(inSweep[index] == true, `end swath tile {index} missing`)
			end
		end)
	end)

	h.describe("Grid — swath rasterisation", function()
		local scratch: { number } = {}

		h.it("cuts a one-tile-wide lane straight ahead", function()
			local grid = Grid.new(20, 20)
			-- Stand at the centre of tile (10, 2) facing +Z, reach two tiles.
			local wx, wz = Grid.tileToWorld(grid, 10, 2)
			local tiles = Grid.rasterizeSwath(grid, wx, wz, 0, 1, 1, TILE * 2, scratch)

			for _, index in tiles do
				local tx = select(1, Grid.fromIndex(grid, index))
				h.expectEqual(tx, 10, "swath must stay in one column")
			end
			h.expectTrue(#tiles >= 3, `expected at least 3 tiles, got {#tiles}`)
		end)

		h.it("widens with the deck", function()
			local grid = Grid.new(30, 30)
			local wx, wz = Grid.tileToWorld(grid, 15, 5)

			local narrow = #Grid.rasterizeSwath(grid, wx, wz, 0, 1, 1, TILE * 3, {})
			local wide = #Grid.rasterizeSwath(grid, wx, wz, 0, 1, 5, TILE * 3, {})

			h.expectTrue(wide > narrow, `deck 5 ({wide}) should beat deck 1 ({narrow})`)
			-- Five columns of the same lane length.
			h.expectClose(wide / narrow, 5, 0.75, "wide swath should be about 5x")
		end)

		h.it("covers the tile underfoot", function()
			local grid = Grid.new(20, 20)
			local wx, wz = Grid.tileToWorld(grid, 6, 6)
			local tiles = Grid.rasterizeSwath(grid, wx, wz, 1, 0, 1, TILE * 2, scratch)

			local underfoot = Grid.toIndex(grid, 6, 6)
			local found = false
			for _, index in tiles do
				if index == underfoot then
					found = true
					break
				end
			end
			h.expectTrue(found, "the tile the player stands on must be cut")
		end)

		h.it("clips at the world edge instead of wrapping", function()
			local grid = Grid.new(10, 10)
			local wx, wz = Grid.tileToWorld(grid, 0, 0)
			-- Face -X, straight off the edge of the world.
			local tiles = Grid.rasterizeSwath(grid, wx, wz, -1, 0, 3, TILE * 4, scratch)

			for _, index in tiles do
				local tx, tz = Grid.fromIndex(grid, index)
				h.expectTrue(Grid.inBounds(grid, tx, tz), `index {index} escaped the grid`)
			end
		end)

		h.it("returns no duplicate tiles", function()
			local grid = Grid.new(30, 30)
			local wx, wz = Grid.tileToWorld(grid, 15, 15)
			-- A diagonal heading is the case most likely to double-count.
			local tiles = Grid.rasterizeSwath(grid, wx, wz, 0.707, 0.707, 5, TILE * 4, scratch)

			local seen: { [number]: boolean } = {}
			for _, index in tiles do
				h.expectFalse(seen[index] == true, `tile {index} appeared twice`)
				seen[index] = true
			end
		end)

		h.it("treats a zero-length heading as a valid direction", function()
			local grid = Grid.new(20, 20)
			local wx, wz = Grid.tileToWorld(grid, 10, 10)
			local tiles = Grid.rasterizeSwath(grid, wx, wz, 0, 0, 3, TILE * 2, scratch)
			h.expectTrue(#tiles > 0, "a still player should still cut underfoot")
		end)

		h.it("covers a comparable area at any heading", function()
			local grid = Grid.new(60, 60)
			local wx, wz = Grid.tileToWorld(grid, 30, 30)

			local axis = #Grid.rasterizeSwath(grid, wx, wz, 0, 1, 3, TILE * 5, {})
			local diagonal = #Grid.rasterizeSwath(grid, wx, wz, 0.707, 0.707, 3, TILE * 5, {})

			-- A rotated rectangle rasterises to a slightly different count, but a
			-- large gap here would mean diagonal mowing leaves visible stripes.
			local ratio = diagonal / axis
			h.expectTrue(ratio > 0.7 and ratio < 1.45, `axis {axis} vs diagonal {diagonal} (ratio {ratio})`)
		end)
	end)

	h.describe("Grid — targeting ahead", function()
		h.it("finds the nearest acceptable tile along the heading", function()
			local grid = Grid.new(20, 20)
			local wx, wz = Grid.tileToWorld(grid, 5, 5)
			local wanted = Grid.toIndex(grid, 5, 8)

			local found = Grid.targetAhead(grid, wx, wz, 0, 1, TILE * 6, function(index)
				return index == wanted
			end)
			h.expectEqual(found, wanted)
		end)

		h.it("prefers the closer of two candidates", function()
			local grid = Grid.new(20, 20)
			local wx, wz = Grid.tileToWorld(grid, 5, 5)
			local near = Grid.toIndex(grid, 5, 6)
			local far = Grid.toIndex(grid, 5, 9)

			local found = Grid.targetAhead(grid, wx, wz, 0, 1, TILE * 8, function(index)
				return index == near or index == far
			end)
			h.expectEqual(found, near, "should take the nearer leaf")
		end)

		h.it("falls back to the tile underfoot", function()
			-- Standing in a drift should not mean stepping back to reach it.
			local grid = Grid.new(20, 20)
			local wx, wz = Grid.tileToWorld(grid, 7, 7)
			local underfoot = Grid.toIndex(grid, 7, 7)

			local found = Grid.targetAhead(grid, wx, wz, 0, 1, TILE * 3, function(index)
				return index == underfoot
			end)
			h.expectEqual(found, underfoot)
		end)

		h.it("returns nothing when there is nothing to take", function()
			local grid = Grid.new(20, 20)
			local wx, wz = Grid.tileToWorld(grid, 5, 5)
			local found = Grid.targetAhead(grid, wx, wz, 0, 1, TILE * 5, function()
				return false
			end)
			h.expectTrue(found == nil)
		end)

		h.it("never targets outside the grid", function()
			local grid = Grid.new(10, 10)
			local wx, wz = Grid.tileToWorld(grid, 9, 9)
			local found = Grid.targetAhead(grid, wx, wz, 1, 1, TILE * 8, function()
				return true
			end)
			if found then
				local tx, tz = Grid.fromIndex(grid, found)
				h.expectTrue(Grid.inBounds(grid, tx, tz), "target escaped the grid")
			end
		end)
	end)

	h.describe("Grid — rectangles", function()
		h.it("lists exactly the tiles inside a rect", function()
			local grid = Grid.new(20, 20)
			local tiles = Grid.tilesInRect(grid, 2, 3, 4, 5, {})
			h.expectEqual(#tiles, 20)
			for _, index in tiles do
				local tx, tz = Grid.fromIndex(grid, index)
				h.expectTrue(Grid.rectContains(2, 3, 4, 5, tx, tz), `({tx},{tz}) outside rect`)
			end
		end)

		h.it("clips a rect that runs off the edge", function()
			local grid = Grid.new(10, 10)
			local tiles = Grid.tilesInRect(grid, 8, 8, 5, 5, {})
			h.expectEqual(#tiles, 4)
		end)
	end)
end
