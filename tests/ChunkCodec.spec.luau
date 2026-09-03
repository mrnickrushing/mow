--!strict
--[[ ChunkCodec — tile bit packing and the chunk wire format. ]]

local ChunkCodec = require("./.build/Shared/ChunkCodec")
local Grid = require("./.build/Shared/Grid")
local Debris = require("./.build/Shared/Config/Debris")
local GameConfig = require("./.build/Shared/Config/GameConfig")
local h = require("./harness")

--- Fills a tile buffer with a deterministic but varied pattern.
local function seed(grid: Grid.Grid): buffer
	local tiles = buffer.create(Grid.tileCount(grid))
	for i = 0, Grid.tileCount(grid) - 1 do
		local debris = i % (Debris.MAX_ID + 1)
		local height = i % 4
		buffer.writeu8(tiles, i, ChunkCodec.pack(debris, height, i % 5 == 0))
	end
	return tiles
end

return function()
	h.describe("ChunkCodec — what still fits in the byte", function()
		--[[
			A tile is one byte: two bits of height, three of debris id, one wet
			flag. Both numbered fields are packed to exactly their capacity, so
			the next thing added to either list corrupts every tile that carries
			it rather than failing anywhere a person would notice.

			The debris side is covered: `MAX_ID` is derived from the table now,
			and Config.spec holds it to three bits. This is the other side —
			every other test in this file walks a hard-coded `0..3`, so raising
			MAX_HEIGHT is the one change nothing would catch.
		]]
		h.it("round-trips every height the game allows", function()
			h.expectTrue(
				GameConfig.MAX_HEIGHT <= 3,
				`MAX_HEIGHT {GameConfig.MAX_HEIGHT} will not fit in the two-bit height field`
			)
			for height = 0, GameConfig.MAX_HEIGHT do
				local byte = ChunkCodec.pack(Debris.MAX_ID, height, true)
				h.expectEqual(ChunkCodec.height(byte), height, `height {height} does not survive packing`)
				h.expectEqual(ChunkCodec.debris(byte), Debris.MAX_ID, `height {height} corrupted the debris id`)
				h.expectTrue(ChunkCodec.isWet(byte), `height {height} lost the wet flag`)
			end
		end)
	end)

	h.describe("ChunkCodec — tile byte", function()
		h.it("round-trips every debris/height/wet combination", function()
			for debris = 0, Debris.MAX_ID do
				for height = 0, 3 do
					for _, wet in { false, true } do
						local byte = ChunkCodec.pack(debris, height, wet)
						h.expectEqual(ChunkCodec.debris(byte), debris, `debris {debris}`)
						h.expectEqual(ChunkCodec.height(byte), height, `height {height}`)
						h.expectEqual(ChunkCodec.isWet(byte), wet, "wet flag")
					end
				end
			end
		end)

		h.it("fits in one byte", function()
			local byte = ChunkCodec.pack(Debris.MAX_ID, 3, true)
			h.expectTrue(byte >= 0 and byte <= 255, `byte was {byte}`)
		end)

		h.it("changes height without disturbing debris or wetness", function()
			local byte = ChunkCodec.pack(Debris.Weeds, 3, true)
			local cut = ChunkCodec.withHeight(byte, 0)
			h.expectEqual(ChunkCodec.height(cut), 0)
			h.expectEqual(ChunkCodec.debris(cut), Debris.Weeds, "debris must survive a cut")
			h.expectTrue(ChunkCodec.isWet(cut), "wetness must survive a cut")
		end)

		h.it("changes wetness without disturbing debris or height", function()
			local byte = ChunkCodec.pack(Debris.Grass, 2, false)
			local wet = ChunkCodec.withWet(byte, true)
			h.expectTrue(ChunkCodec.isWet(wet))
			h.expectEqual(ChunkCodec.height(wet), 2)
			h.expectEqual(ChunkCodec.debris(wet), Debris.Grass)

			local dry = ChunkCodec.withWet(wet, false)
			h.expectFalse(ChunkCodec.isWet(dry))
			h.expectEqual(ChunkCodec.height(dry), 2)
			h.expectEqual(ChunkCodec.debris(dry), Debris.Grass)
		end)
	end)

	h.describe("ChunkCodec — wire format", function()
		h.it("round-trips a batch of chunks byte for byte", function()
			local grid = Grid.new(32, 32)
			local source = seed(grid)
			local target = buffer.create(Grid.tileCount(grid))

			local chunks = {}
			for i = 1, Grid.chunkCount(grid) do
				table.insert(chunks, i)
			end

			local packet = ChunkCodec.encode(grid, source, chunks)
			local touched = ChunkCodec.decodeInto(grid, target, packet)

			h.expectTrue(touched ~= nil, "decode should succeed")
			h.expectEqual(#(touched :: { number }), #chunks, "all chunks reported")

			for i = 0, Grid.tileCount(grid) - 1 do
				h.expectEqual(buffer.readu8(target, i), buffer.readu8(source, i), `tile offset {i}`)
			end
		end)

		h.it("only writes the chunks it was given", function()
			local grid = Grid.new(32, 32)
			local source = seed(grid)
			local target = buffer.create(Grid.tileCount(grid))

			local packet = ChunkCodec.encode(grid, source, { 1 })
			ChunkCodec.decodeInto(grid, target, packet)

			-- Chunk 1 covers tiles (0..7, 0..7).
			h.expectEqual(buffer.readu8(target, Grid.toIndex(grid, 3, 3) - 1), buffer.readu8(source, Grid.toIndex(grid, 3, 3) - 1))
			-- A tile outside chunk 1 must still be untouched.
			h.expectEqual(buffer.readu8(target, Grid.toIndex(grid, 20, 20) - 1), 0, "tile outside the batch")
		end)

		h.it("handles partial edge chunks without corrupting neighbours", function()
			-- 9x9 tiles over 8x8 chunks leaves three ragged edge chunks.
			local grid = Grid.new(9, 9)
			local source = seed(grid)
			local target = buffer.create(Grid.tileCount(grid))

			local chunks = {}
			for i = 1, Grid.chunkCount(grid) do
				table.insert(chunks, i)
			end

			local packet = ChunkCodec.encode(grid, source, chunks)
			h.expectTrue(ChunkCodec.decodeInto(grid, target, packet) ~= nil)

			for i = 0, Grid.tileCount(grid) - 1 do
				h.expectEqual(buffer.readu8(target, i), buffer.readu8(source, i), `tile offset {i}`)
			end
		end)

		h.it("encodes an empty batch", function()
			local grid = Grid.new(16, 16)
			local packet = ChunkCodec.encode(grid, seed(grid), {})
			local touched = ChunkCodec.decodeInto(grid, buffer.create(Grid.tileCount(grid)), packet)
			h.expectTrue(touched ~= nil)
			h.expectEqual(#(touched :: { number }), 0)
		end)

		h.it("rejects a truncated packet", function()
			local grid = Grid.new(16, 16)
			local packet = ChunkCodec.encode(grid, seed(grid), { 1, 2 })
			local short = buffer.create(buffer.len(packet) - 10)
			buffer.copy(short, 0, packet, 0, buffer.len(short))

			local target = buffer.create(Grid.tileCount(grid))
			h.expectTrue(ChunkCodec.decodeInto(grid, target, short) == nil, "truncated packet must be refused")
		end)

		h.it("rejects a packet from another format version", function()
			local grid = Grid.new(16, 16)
			local packet = ChunkCodec.encode(grid, seed(grid), { 1 })
			buffer.writeu8(packet, 0, ChunkCodec.VERSION + 1)

			local target = buffer.create(Grid.tileCount(grid))
			h.expectTrue(ChunkCodec.decodeInto(grid, target, packet) == nil, "version mismatch must be refused")
		end)

		h.it("rejects a packet too short to hold a header", function()
			local grid = Grid.new(16, 16)
			local target = buffer.create(Grid.tileCount(grid))
			h.expectTrue(ChunkCodec.decodeInto(grid, target, buffer.create(2)) == nil)
		end)

		h.it("keeps a full batch inside the remote size budget", function()
			local grid = Grid.new(96, 96)
			local maxChunks = ChunkCodec.maxChunksPerPacket(grid)
			local chunks = {}
			for i = 1, math.min(maxChunks, Grid.chunkCount(grid)) do
				table.insert(chunks, i)
			end
			local packet = ChunkCodec.encode(grid, seed(grid), chunks)
			h.expectTrue(buffer.len(packet) <= 64 * 1024, `packet was {buffer.len(packet)} bytes`)
		end)
	end)
end
