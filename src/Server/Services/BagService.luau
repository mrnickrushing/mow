--!strict
--[[
	BagService — what a player is carrying, and what happens when they dump it.

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
	local profile = DataService.get(player)
	if not profile then
		return 0
	end
	return Balance.bagCapacity(profile.upgrades, EconomyService.modifiers(player))
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

--- Total cash the current contents would fetch, before multipliers.
function BagService.baseValue(player: Player): number
	local property = WorldService.property
	local multiplier = if property then property.payoutMultiplier else 1
	local total = 0
	for debrisId, units in bagFor(player).units do
		total += DebrisConfig.get(debrisId).value * units * multiplier
	end
	return total
end

--- Sells everything the player is carrying. Returns the cash paid.
function BagService.dump(player: Player): number
	local bag = bagFor(player)
	if bag.weight <= 0 then
		return 0
	end

	local base = BagService.baseValue(player)
	local unitsSold = 0
	for _, units in bag.units do
		unitsSold += units
	end

	table.clear(bag.units)
	bag.weight = 0

	local paid = EconomyService.award(player, base)

	DataService.withProfile(player, function(profile)
		profile.stats.unitsSold += unitsSold
	end)

	EconomyService.notify(player, "sale", `Sold {Format.count(unitsSold)} for {Format.cash(paid)}`, paid)
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
