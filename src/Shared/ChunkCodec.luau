--!strict
--[[
	ChunkCodec — tile bit packing and chunk wire format.

	The world's tile state is one byte per tile held in a `buffer`, never as
	Instances. That is the single decision that lets a 5,000-tile property run
	with twelve players mowing at once.

	Tile byte layout (LSB first):
		bits 0-1  height, 0..3   (0 = clean)
		bits 2-4  debris id, 0..7
		bit  5    wet flag
		bits 6-7  reserved

	Wire format for a batch of dirty chunks:
		u8   format version
		u16  chunk count
		per chunk:
			u16  chunk index (one-based)
			u8[chunkTiles^2]  tile bytes, row-major within the chunk

	Edge chunks are padded to a full square; padding bytes decode to
	out-of-bounds tiles and are skipped.
]]

local Grid = require(script.Parent.Grid)

local ChunkCodec = {}

ChunkCodec.VERSION = 1

local HEIGHT_MASK = 0b00000011
local DEBRIS_SHIFT = 2
local DEBRIS_MASK = 0b00011100
local WET_BIT = 0b00100000

--------------------------------------------------------------------
-- Tile byte
--------------------------------------------------------------------

function ChunkCodec.pack(debrisId: number, height: number, wet: boolean?): number
	local byte = bit32.band(height, HEIGHT_MASK)
	byte = bit32.bor(byte, bit32.band(bit32.lshift(debrisId, DEBRIS_SHIFT), DEBRIS_MASK))
	if wet then
		byte = bit32.bor(byte, WET_BIT)
	end
	return byte
end

function ChunkCodec.height(byte: number): number
	return bit32.band(byte, HEIGHT_MASK)
end

function ChunkCodec.debris(byte: number): number
	return bit32.rshift(bit32.band(byte, DEBRIS_MASK), DEBRIS_SHIFT)
end

function ChunkCodec.isWet(byte: number): boolean
	return bit32.band(byte, WET_BIT) ~= 0
end

function ChunkCodec.withHeight(byte: number, height: number): number
	return bit32.bor(bit32.band(byte, bit32.bnot(HEIGHT_MASK)), bit32.band(height, HEIGHT_MASK))
end

function ChunkCodec.withWet(byte: number, wet: boolean): number
	if wet then
		return bit32.bor(byte, WET_BIT)
	end
	return bit32.band(byte, bit32.bnot(WET_BIT))
end

--------------------------------------------------------------------
-- Chunk batches
--------------------------------------------------------------------

--- Bytes one encoded chunk occupies, header included.
function ChunkCodec.chunkStride(grid: Grid.Grid): number
	return 2 + grid.chunkTiles * grid.chunkTiles
end

--[[
	Encode the listed chunks out of the world tile buffer.

	`chunkIndices` are one-based. Returns a buffer sized exactly to its contents
	so it can be handed straight to a RemoteEvent.
]]
function ChunkCodec.encode(grid: Grid.Grid, tiles: buffer, chunkIndices: { number }): buffer
	local count = #chunkIndices
	local stride = ChunkCodec.chunkStride(grid)
	local out = buffer.create(3 + count * stride)

	buffer.writeu8(out, 0, ChunkCodec.VERSION)
	buffer.writeu16(out, 1, count)

	local chunkTiles = grid.chunkTiles
	local cursor = 3

	for i = 1, count do
		local chunkIndex = chunkIndices[i]
		buffer.writeu16(out, cursor, chunkIndex)
		cursor += 2

		local cx, cz = Grid.chunkFromIndex(grid, chunkIndex)
		local baseX, baseZ = cx * chunkTiles, cz * chunkTiles

		for lz = 0, chunkTiles - 1 do
			local tz = baseZ + lz
			for lx = 0, chunkTiles - 1 do
				local tx = baseX + lx
				local byte = 0
				if Grid.inBounds(grid, tx, tz) then
					byte = buffer.readu8(tiles, Grid.toIndex(grid, tx, tz) - 1)
				end
				buffer.writeu8(out, cursor, byte)
				cursor += 1
			end
		end
	end

	return out
end

--[[
	Apply an encoded batch into a world tile buffer.

	Returns the list of chunk indices touched so a renderer can refresh exactly
	those, or nil if the payload is malformed or from another format version.
]]
function ChunkCodec.decodeInto(grid: Grid.Grid, tiles: buffer, packet: buffer): { number }?
	if buffer.len(packet) < 3 then
		return nil
	end
	if buffer.readu8(packet, 0) ~= ChunkCodec.VERSION then
		return nil
	end

	local count = buffer.readu16(packet, 1)
	local stride = ChunkCodec.chunkStride(grid)
	if buffer.len(packet) < 3 + count * stride then
		return nil
	end

	local chunkTiles = grid.chunkTiles
	local touched = table.create(count)
	local cursor = 3

	for _ = 1, count do
		local chunkIndex = buffer.readu16(packet, cursor)
		cursor += 2

		local cx, cz = Grid.chunkFromIndex(grid, chunkIndex)
		local baseX, baseZ = cx * chunkTiles, cz * chunkTiles

		for lz = 0, chunkTiles - 1 do
			local tz = baseZ + lz
			for lx = 0, chunkTiles - 1 do
				local tx = baseX + lx
				local byte = buffer.readu8(packet, cursor)
				cursor += 1
				if Grid.inBounds(grid, tx, tz) then
					buffer.writeu8(tiles, Grid.toIndex(grid, tx, tz) - 1, byte)
				end
			end
		end

		table.insert(touched, chunkIndex)
	end

	return touched
end

--- Largest chunk count that fits comfortably in one remote payload.
--- Roblox caps a single event at 64 KB; we stay well under.
function ChunkCodec.maxChunksPerPacket(grid: Grid.Grid): number
	return math.max(1, (48 * 1024) // ChunkCodec.chunkStride(grid))
end

return ChunkCodec
