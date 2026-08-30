--!strict
--[[
	BagService — the buffer between the lawn and the wallet.

	Nobody walks anywhere to sell. Everything collected lands in the bag, and
	the bag drains itself continuously, paying cash as it goes — a fixed
	fraction of capacity per second, so a bigger bag both buffers a burst and
	pays out faster. Capacity is the wall a fast tool hits: collect quicker than
	the bag drains and the tool stalls on a full bag, which is exactly what the
	capacity upgrade and the Infinite Bag pass remove.

	The bag is tracked in *weight*, not item count: a log takes fifteen units of
	space and a clipping takes one, so hauling wood is a real decision rather
	than a strict upgrade. Contents live in memory only — a bag does not survive
	a rejoin, which also means it can never be duplicated across servers.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local DebrisConfig = require(Shared.Config.Debris)
local Economy = require(Shared.Config.Economy)
local DataService = require(script.Parent.DataService)
local RunState = require(script.Parent.RunState)
local EconomyService = require(script.Parent.EconomyService)
local WorldService = require(script.Parent.WorldService)

local BagService = {}

export type Bag = {
	--- Units held, keyed by debris id.
	units: { [number]: number },
	--- Cached sum of units * weight, so capacity checks are O(1).
	weight: number,
}

local bags: { [Player]: Bag } = {}

--- Fires as (player, units, cash) whenever a bag is sold.
local soldSignal = Instance.new("BindableEvent")
BagService.Sold = soldSignal.Event

local function bagFor(player: Player): Bag
	local bag = bags[player]
	if not bag then
		bag = { units = {}, weight = 0 }
		bags[player] = bag
	end
	return bag
end

BagService.get = bagFor

function BagService.capacity(player: Player): number
	local run = RunState.find(player)
	if not run then
		return 0
	end
	return Balance.bagCapacity(run.upgrades, EconomyService.modifiers(player))
end

function BagService.weight(player: Player): number
	return bagFor(player).weight
end

function BagService.isFull(player: Player): boolean
	return bagFor(player).weight >= BagService.capacity(player)
end

--[[
	Adds as much of `units` as will fit.

	Returns how many units were actually taken, so the caller can leave the
	remainder on the ground rather than silently destroying it when the bag is
	full — a player who does not notice their bag filled should not lose work.
]]
function BagService.add(player: Player, debrisId: number, units: number): number
	if units <= 0 then
		return 0
	end

	local def = DebrisConfig.get(debrisId)
	if def.weight <= 0 then
		return 0
	end

	local bag = bagFor(player)
	local space = BagService.capacity(player) - bag.weight
	if space <= 0 then
		return 0
	end

	local affordable = math.floor(space / def.weight)
	local taken = math.min(units, affordable)
	if taken <= 0 then
		return 0
	end

	bag.units[debrisId] = (bag.units[debrisId] or 0) + taken
	bag.weight += taken * def.weight
	return taken
end

--- Extra multiplier the wood chipper applies to wood.
local CHIPPER_MULTIPLIER = 3

--- True once the player owns the wood chipper bolted to their trailer.
local function hasChipper(player: Player): boolean
	local run = RunState.find(player)
	return run ~= nil and run.ownedTools["wood_chipper"] == true
end

--- Total cash the current contents would fetch, before multipliers.
function BagService.baseValue(player: Player): number
	local property = WorldService.world
	local multiplier = if property then property.payoutMultiplier else 1
	local chipper = hasChipper(player)
	local total = 0

	for debrisId, units in bagFor(player).units do
		local value = DebrisConfig.get(debrisId).value * units * multiplier
		-- The chipper only pays on wood, which is what makes felling trees the
		-- endgame's best use of bag space rather than just its heaviest.
		if chipper and (debrisId == DebrisConfig.Log or debrisId == DebrisConfig.Chips) then
			value *= CHIPPER_MULTIPLIER
		end
		total += value
	end

	return total
end

--[[
	Sells `weightToSell` worth of the bag's contents. Returns the cash paid.

	Contents drain cheapest-per-weight first. That order matters with mixed
	loads: the drain is a queue, and paying the logs out last means a player
	who felled a tree keeps its value pending a little longer rather than
	having it jump the clippings it was mixed in with.
]]
local function sell(player: Player, weightToSell: number): number
	local bag = bagFor(player)
	if bag.weight <= 0 or weightToSell <= 0 then
		return 0
	end

	local property = WorldService.world
	local worldMultiplier = if property then property.payoutMultiplier else 1
	local chipper = hasChipper(player)

	local run = RunState.find(player)
	local personal = if run
		then Balance.cashMultiplier(run.upgrades, EconomyService.modifiers(player))
		else 1

	local remaining = weightToSell
	local unitsSold = 0
	local base = 0

	for debrisId, held in bag.units do
		if remaining <= 0 then
			break
		end
		local def = DebrisConfig.get(debrisId)
		local units = math.min(held, remaining / def.weight)
		if units > 0 then
			local value = def.value * units * worldMultiplier
			if chipper and (debrisId == DebrisConfig.Log or debrisId == DebrisConfig.Chips) then
				value *= CHIPPER_MULTIPLIER
			end
			base += value
			unitsSold += units
			remaining -= units * def.weight

			local left = held - units
			if left < 1e-6 then
				bag.units[debrisId] = nil
			else
				bag.units[debrisId] = left
			end
		end
	end

	if unitsSold <= 0 then
		return 0
	end

	bag.weight = math.max(bag.weight - (weightToSell - remaining), 0)

	local paid = EconomyService.award(player, base * personal)

	DataService.withProfile(player, function(profile)
		profile.stats.unitsSold += unitsSold
	end)

	soldSignal:Fire(player, unitsSold, paid)
	return paid
end

--- Sells everything at once. The Empty Bag product, and the end of a run.
function BagService.dump(player: Player): number
	return sell(player, bagFor(player).weight)
end

--- Empties the bag without paying, used when a round rotates the map.
function BagService.clear(player: Player)
	local bag = bags[player]
	if bag then
		table.clear(bag.units)
		bag.weight = 0
	end
end

function BagService.clearAll()
	for player in bags do
		BagService.clear(player)
	end
end

function BagService.start()
	Players.PlayerRemoving:Connect(function(player)
		bags[player] = nil
	end)

	-- The drain. Ticked a few times a second rather than per frame: the sums
	-- involved are tiny, and paying out in visible sips is part of the feel —
	-- the cash counter should tick up like a meter, not glide.
	local accumulator = 0
	RunService.Heartbeat:Connect(function(delta)
		accumulator += delta
		if accumulator < 0.25 then
			return
		end
		local elapsed = accumulator
		accumulator = 0

		for player, bag in bags do
			if bag.weight > 0 then
				local capacity = BagService.capacity(player)
				local drain = capacity * Economy.DRAIN_FRACTION_PER_SECOND * elapsed
				if drain > 0 then
					sell(player, math.min(drain, bag.weight))
				end
			end
		end
	end)
end

return BagService
