--!strict
--[[
	BagService — the clippings you are carrying, and the trailer that buys them.

	Money arrives when the bag is emptied, not while you mow. The loop is the
	original one: mow until the bag fills, walk it to the trailer, watch the
	payout land in one satisfying lump. Capacity decides how long you can stay
	on the lawn between trips, which is what the Grasp upgrade and the Infinite
	Bag pass actually buy — fewer interruptions, not a bigger number.

	The bag is tracked in *weight*, not item count: a log takes fifteen units of
	space and a clipping takes one, so hauling wood is a real decision rather
	than a strict upgrade. Contents live in memory only — a bag does not survive
	a rejoin, which also means it can never be duplicated across servers.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local DebrisConfig = require(Shared.Config.Debris)
local Format = require(Shared.Util.Format)
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

	local remaining = weightToSell
	local unitsSold = 0
	local base = 0

	--[[
		Cheapest per unit of bag weight first, which is what the note above
		promises and what the loop did not do.

		It read straight off `bag.units`, and that is a hash table: Luau gives
		no order for one, so which debris drained first was whatever the
		internal layout happened to yield. The total paid was right either way,
		so nothing looked wrong — but the pour takes a couple of seconds, and a
		player who walks off part way through kept an arbitrary remainder
		rather than the logs they felled a tree for.

		The chipper is folded in because it triples wood, which only makes wood
		more firmly the thing worth keeping until last.
	]]
	local order: { number } = {}
	for debrisId in bag.units do
		table.insert(order, debrisId)
	end
	table.sort(order, function(a, b)
		local defA, defB = DebrisConfig.get(a), DebrisConfig.get(b)
		local rateA = defA.value / defA.weight
		local rateB = defB.value / defB.weight
		if chipper then
			if a == DebrisConfig.Log or a == DebrisConfig.Chips then
				rateA *= CHIPPER_MULTIPLIER
			end
			if b == DebrisConfig.Log or b == DebrisConfig.Chips then
				rateB *= CHIPPER_MULTIPLIER
			end
		end
		if rateA == rateB then
			-- Ties broken by id so a mixed bag always drains the same way.
			return a < b
		end
		return rateA < rateB
	end)

	for _, debrisId in order do
		if remaining <= 0 then
			break
		end
		local held = bag.units[debrisId]
		if not held then
			continue
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

	--[[
		The base price, not the multiplied one.

		This used to work out the player's cash multiplier here and hand the
		multiplied figure to `award`, which works out the same multiplier and
		applies it again: every upgrade and every boost was squared, so a
		doubled payout paid four times and a tripled one paid nine. `award`
		owns the multiplier; the seller owns the price.
	]]
	local paid = EconomyService.award(player, base)

	DataService.withProfile(player, function(profile)
		profile.stats.unitsSold += unitsSold
	end)

	soldSignal:Fire(player, unitsSold, paid)
	return paid
end

--[[
	Sells up to `weight` of the bag's contents. The trailer pour: called a few
	times a second while the player stands in range, so the bag empties as a
	stream and the tally on screen counts up with it.
]]
function BagService.sellUpTo(player: Player, weight: number): number
	return sell(player, math.min(weight, bagFor(player).weight))
end

--- Empties the whole bag at once — the Empty Bag product, not the trailer.
function BagService.dump(player: Player): number
	local paid = sell(player, bagFor(player).weight)
	if paid > 0 then
		EconomyService.notify(player, "sale", `Emptied the bag for {Format.cash(paid)}`, paid)
	end
	return paid
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
end

return BagService
