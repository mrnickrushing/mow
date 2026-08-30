--!strict
--[[
	SweepService — the Clean Sweep product.

	Instantly clears a slice of the zone the buyer is standing in, paying them
	for it as though they had cut it. Tiles are taken nearest-first so the effect
	radiates out from the player and reads as their doing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local ChunkCodec = require(Shared.ChunkCodec)
local DebrisConfig = require(Shared.Config.Debris)
local Format = require(Shared.Util.Format)
local Grid = require(Shared.Grid)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local ReplicationService = require(script.Parent.ReplicationService)
local WorldService = require(script.Parent.WorldService)

local SweepService = {}

--[[
	Clears `fraction` of the zone the player is standing in.

	Pays cash directly rather than filling the bag: a sweep can easily be worth
	more than a bag holds, and a product that silently discarded most of what it
	cleared would be indefensible.
]]
function SweepService.sweep(player: Player, fraction: number): number
	local grid = WorldService.grid
	local tiles = WorldService.tiles
	local property = WorldService.property
	local profile = DataService.get(player)
	if not grid or not tiles or not property or not profile then
		return 0
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return 0
	end

	local tx, tz = Grid.worldToTile(grid, root.Position.X, root.Position.Z)
	if not Grid.inBounds(grid, tx, tz) then
		return 0
	end

	local zoneId = WorldService.zoneIdAt(Grid.toIndex(grid, tx, tz))
	local owned = profile.unlockedZones[property.id]
	if zoneId == "" or not owned or not owned[zoneId] then
		EconomyService.notify(player, "denied", "Stand in a zone you own first", nil)
		return 0
	end

	local zone = WorldService.zones[zoneId]
	if not zone then
		return 0
	end

	-- Collect the zone's remaining tiles, nearest first, so the sweep radiates
	-- out from the player instead of clearing a random scatter.
	local candidates: { { index: number, distance: number } } = {}
	local r = zone.def.rect
	for zz = r.z, math.min(r.z + r.d - 1, grid.depth - 1) do
		for xx = r.x, math.min(r.x + r.w - 1, grid.width - 1) do
			local index = Grid.toIndex(grid, xx, zz)
			if ChunkCodec.height(buffer.readu8(tiles, index - 1)) > 0 then
				local dx, dz = xx - tx, zz - tz
				table.insert(candidates, { index = index, distance = dx * dx + dz * dz })
			end
		end
	end

	if #candidates == 0 then
		EconomyService.notify(player, "denied", "Nothing left to sweep here", nil)
		return 0
	end

	table.sort(candidates, function(a, b)
		return a.distance < b.distance
	end)

	local take = math.max(math.floor(#candidates * fraction), 1)
	local yieldMultiplier = Balance.yieldMultiplier(profile.upgrades)
	local baseCash = 0
	local cleared = 0

	for i = 1, math.min(take, #candidates) do
		local index = candidates[i].index
		local byte = buffer.readu8(tiles, index - 1)
		local height = ChunkCodec.height(byte)
		local debrisId = ChunkCodec.debris(byte)
		if height > 0 and debrisId ~= DebrisConfig.Empty then
			local def = DebrisConfig.get(debrisId)
			baseCash += height * def.unitsPerLevel * yieldMultiplier * def.value * property.payoutMultiplier

			buffer.writeu8(tiles, index - 1, ChunkCodec.withHeight(byte, 0))
			ReplicationService.markTileDirty(index)
			WorldService.consumeUnits(zoneId, height * def.unitsPerLevel)
			cleared += 1
		end
	end

	local paid = EconomyService.award(player, baseCash)
	EconomyService.notify(player, "reward", `Swept {Format.count(cleared)} tiles for {Format.cash(paid)}`, paid)
	return paid
end

--- Kept for symmetry with the other services; nothing to wire up.
function SweepService.start() end

return SweepService
