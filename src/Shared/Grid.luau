--!strict
--[[
	Grid — tile-space geometry.

	Pure math with no Roblox dependency beyond the numbers passed in, so it can
	be unit tested outside Studio. Everything the mowing loop needs to answer
	"which tiles did that pass cover?" lives here.

	Tile coordinates are zero-based: tx in [0, width), tz in [0, depth).
	Linear indices are one-based so they can key a Luau array directly, while the
	tile buffer is addressed with `index - 1`.
]]

local GameConfig = require(script.Parent.Config.GameConfig)

local Grid = {}
Grid.__index = Grid

export type Grid = typeof(setmetatable(
	{} :: {
		width: number,
		depth: number,
		tileSize: number,
		chunkTiles: number,
		chunksX: number,
		chunksZ: number,
		--- World-space X/Z of the minimum corner of tile (0, 0).
		originX: number,
		originZ: number,
	},
	Grid
))

function Grid.new(width: number, depth: number, originX: number?, originZ: number?): Grid
	local tileSize = GameConfig.TILE_SIZE
	local chunkTiles = GameConfig.CHUNK_TILES
	return setmetatable({
		width = width,
		depth = depth,
		tileSize = tileSize,
		chunkTiles = chunkTiles,
		chunksX = math.ceil(width / chunkTiles),
		chunksZ = math.ceil(depth / chunkTiles),
		originX = originX or 0,
		originZ = originZ or 0,
	}, Grid)
end

function Grid.tileCount(self: Grid): number
	return self.width * self.depth
end

function Grid.chunkCount(self: Grid): number
	return self.chunksX * self.chunksZ
end

function Grid.inBounds(self: Grid, tx: number, tz: number): boolean
	return tx >= 0 and tz >= 0 and tx < self.width and tz < self.depth
end

--- One-based linear index for a tile. Caller must have checked bounds.
function Grid.toIndex(self: Grid, tx: number, tz: number): number
	return tz * self.width + tx + 1
end

--- Inverse of `toIndex`.
function Grid.fromIndex(self: Grid, index: number): (number, number)
	local zero = index - 1
	local tz = zero // self.width
	return zero - tz * self.width, tz
end

--- Tile containing a world position. May be out of bounds; check with inBounds.
function Grid.worldToTile(self: Grid, x: number, z: number): (number, number)
	return math.floor((x - self.originX) / self.tileSize), math.floor((z - self.originZ) / self.tileSize)
end

--- World-space centre of a tile.
function Grid.tileToWorld(self: Grid, tx: number, tz: number): (number, number)
	local half = self.tileSize * 0.5
	return self.originX + tx * self.tileSize + half, self.originZ + tz * self.tileSize + half
end

--------------------------------------------------------------------
-- Chunks
--------------------------------------------------------------------

function Grid.chunkOf(self: Grid, tx: number, tz: number): (number, number)
	return tx // self.chunkTiles, tz // self.chunkTiles
end

--- One-based linear chunk index.
function Grid.chunkIndex(self: Grid, cx: number, cz: number): number
	return cz * self.chunksX + cx + 1
end

function Grid.chunkFromIndex(self: Grid, index: number): (number, number)
	local zero = index - 1
	local cz = zero // self.chunksX
	return zero - cz * self.chunksX, cz
end

--- Chunk index directly from a tile index, avoiding an intermediate decode.
function Grid.chunkOfTileIndex(self: Grid, tileIndex: number): number
	local tx, tz = Grid.fromIndex(self, tileIndex)
	return Grid.chunkIndex(self, tx // self.chunkTiles, tz // self.chunkTiles)
end

--- World-space centre of a chunk, on the ground plane.
function Grid.chunkCentre(self: Grid, cx: number, cz: number): (number, number)
	local studs = self.chunkTiles * self.tileSize
	return self.originX + (cx + 0.5) * studs, self.originZ + (cz + 0.5) * studs
end

--------------------------------------------------------------------
-- Swath rasterisation
--------------------------------------------------------------------

--[[
	Tiles covered by one pass of a cutting deck.

	The deck is a rectangle `deckTiles` wide and `reach` studs long, starting at
	the player's feet and extending along `dirX, dirZ`. We walk the axis-aligned
	bounding box of that rectangle and keep tiles whose centre falls inside it,
	which gives a stable, seam-free swath at any heading — no raycasts, no
	physics, no Touched events.

	`out` is filled with one-based tile indices and returned, so callers can
	reuse a scratch table across frames.
]]
function Grid.rasterizeSwath(
	self: Grid,
	worldX: number,
	worldZ: number,
	dirX: number,
	dirZ: number,
	deckTiles: number,
	reach: number,
	out: { number }
): { number }
	table.clear(out)

	local len = math.sqrt(dirX * dirX + dirZ * dirZ)
	if len < 1e-4 then
		dirX, dirZ = 0, 1
	else
		dirX, dirZ = dirX / len, dirZ / len
	end

	-- Right-hand perpendicular of the heading.
	local perpX, perpZ = -dirZ, dirX
	local halfWidth = deckTiles * self.tileSize * 0.5

	-- The swath starts slightly behind the player so tiles underfoot are caught.
	local backset = self.tileSize * 0.5
	local startX, startZ = worldX - dirX * backset, worldZ - dirZ * backset
	local endX, endZ = startX + dirX * reach, startZ + dirZ * reach

	local minX = math.min(startX, endX) - halfWidth
	local maxX = math.max(startX, endX) + halfWidth
	local minZ = math.min(startZ, endZ) - halfWidth
	local maxZ = math.max(startZ, endZ) + halfWidth

	local tx0, tz0 = Grid.worldToTile(self, minX, minZ)
	local tx1, tz1 = Grid.worldToTile(self, maxX, maxZ)
	tx0 = math.max(tx0, 0)
	tz0 = math.max(tz0, 0)
	tx1 = math.min(tx1, self.width - 1)
	tz1 = math.min(tz1, self.depth - 1)

	-- Half a tile of slack keeps diagonal passes from leaving hairline gaps.
	local slack = self.tileSize * 0.5
	local alongLimit = reach + backset + slack
	local acrossLimit = halfWidth + slack * 0.5

	for tz = tz0, tz1 do
		for tx = tx0, tx1 do
			local cx, cz = Grid.tileToWorld(self, tx, tz)
			local relX, relZ = cx - startX, cz - startZ
			local along = relX * dirX + relZ * dirZ
			if along >= -slack and along <= alongLimit then
				local across = relX * perpX + relZ * perpZ
				if across >= -acrossLimit and across <= acrossLimit then
					table.insert(out, Grid.toIndex(self, tx, tz))
				end
			end
		end
	end

	return out
end

--- Tiles already collected by the sweep in progress. Module-level so the
--- server's hot path does not allocate a set per intent.
local sweepSeen: { [number]: boolean } = {}

--[[
	Tiles covered by a deck dragged from one point to another.

	One swath per intent assumes the intents arrive. They are sent unreliably,
	on purpose, and a ride-on mower covers three to five studs between ticks —
	so one lost tick was a deck-wide strip the server never cut, sitting
	behind a machine the client had already shown clearing it. The next flush
	put the grass back and it stayed back until the player turned round.

	The deck is rasterised at every half-tile along the segment and the tiles
	are unioned, so whatever happened to the intents in between, the path
	the machine actually took is what gets cut. A gap shorter than half a
	tile is just the swath at the far end. `out` receives one-based tile
	indices with no duplicates; `scratch` is reused for each step's swath.
]]
function Grid.rasterizeSweep(
	self: Grid,
	fromX: number,
	fromZ: number,
	toX: number,
	toZ: number,
	dirX: number,
	dirZ: number,
	deckTiles: number,
	reach: number,
	out: { number },
	scratch: { number }
): { number }
	local dx, dz = toX - fromX, toZ - fromZ
	local distance = math.sqrt(dx * dx + dz * dz)
	local step = self.tileSize * 0.5
	if distance <= step then
		return Grid.rasterizeSwath(self, toX, toZ, dirX, dirZ, deckTiles, reach, out)
	end

	table.clear(out)
	table.clear(sweepSeen)
	local steps = math.ceil(distance / step)
	for i = 0, steps do
		local t = i / steps
		Grid.rasterizeSwath(self, fromX + dx * t, fromZ + dz * t, dirX, dirZ, deckTiles, reach, scratch)
		for _, index in scratch do
			if not sweepSeen[index] then
				sweepSeen[index] = true
				table.insert(out, index)
			end
		end
	end
	return out
end

--[[
	The tile a player is looking at, for pickup tools.

	Walks outward along the heading and returns the first tile that `accept`
	says holds something. Reach is short, so this is a handful of samples rather
	than a search: a player picking leaves up one at a time is aiming at what is
	right in front of their feet.

	Returns nil when there is nothing to take.
]]
function Grid.targetAhead(
	self: Grid,
	worldX: number,
	worldZ: number,
	dirX: number,
	dirZ: number,
	reach: number,
	accept: (number) -> boolean
): number?
	local length = math.sqrt(dirX * dirX + dirZ * dirZ)
	if length < 1e-4 then
		dirX, dirZ = 0, 1
	else
		dirX, dirZ = dirX / length, dirZ / length
	end

	local step = self.tileSize * 0.5
	local samples = math.max(math.ceil(reach / step), 1)
	local best: number? = nil

	for i = 0, samples do
		local distance = step * i
		local x = worldX + dirX * distance
		local z = worldZ + dirZ * distance
		local tx, tz = Grid.worldToTile(self, x, z)
		if Grid.inBounds(self, tx, tz) then
			local index = Grid.toIndex(self, tx, tz)
			if accept(index) then
				best = index
				break
			end
		end
	end

	-- Nothing directly ahead, so try the tile underfoot before giving up: a
	-- player standing in a drift should not have to step back to reach it.
	if not best then
		local tx, tz = Grid.worldToTile(self, worldX, worldZ)
		if Grid.inBounds(self, tx, tz) then
			local index = Grid.toIndex(self, tx, tz)
			if accept(index) then
				best = index
			end
		end
	end

	return best
end

--- Tile indices inside an axis-aligned tile-space rectangle, clipped to bounds.
function Grid.tilesInRect(self: Grid, x: number, z: number, w: number, d: number, out: { number }): { number }
	table.clear(out)
	local tx1 = math.min(x + w - 1, self.width - 1)
	local tz1 = math.min(z + d - 1, self.depth - 1)
	for tz = math.max(z, 0), tz1 do
		for tx = math.max(x, 0), tx1 do
			table.insert(out, Grid.toIndex(self, tx, tz))
		end
	end
	return out
end

--- True when a tile falls inside a tile-space rectangle.
function Grid.rectContains(x: number, z: number, w: number, d: number, tx: number, tz: number): boolean
	return tx >= x and tz >= z and tx < x + w and tz < z + d
end

return Grid
