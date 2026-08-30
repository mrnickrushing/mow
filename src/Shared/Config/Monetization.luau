--!strict
--[[
	Monetization — every gamepass and developer product in one file.

	The ids below are PLACEHOLDERS. Create the passes and products on the Roblox
	creator dashboard, paste the real ids in, and nothing else in the codebase
	needs to change. Until then MonetizationService treats a zero id as "not
	configured" and quietly skips it, so the game runs fine unmonetised.

	See docs/MONETIZATION.md for the full setup walkthrough.
]]

local Monetization = {}

export type PassDef = {
	key: string,
	id: number,
	name: string,
	robux: number,
	description: string,
}

export type ProductKind = "rental" | "cashBoost" | "fuel" | "bag" | "sweep" | "serverBoost" | "roundTime"

export type ProductDef = {
	key: string,
	id: number,
	name: string,
	robux: number,
	kind: ProductKind,
	description: string,
	--- Rentals: the tool granted, and for how long.
	toolId: string?,
	seconds: number?,
	--- Cash and server boosts: the multiplier applied while active.
	multiplier: number?,
	--- Clean Sweep: fraction of the current zone cleared instantly.
	fraction: number?,
}

--------------------------------------------------------------------
-- Gamepasses (permanent)
--------------------------------------------------------------------

local passes: { PassDef } = {
	{
		key = "doubleCash",
		id = 0,
		name = "2x Cash",
		robux = 199,
		description = "Every load you sell is worth double, forever.",
	},
	{
		key = "doubleBag",
		id = 0,
		name = "2x Bag",
		robux = 249,
		description = "Twice the capacity. Half the trips to the trailer.",
	},
	{
		key = "autoCollect",
		id = 0,
		name = "Auto-Collect",
		robux = 399,
		description = "Cut debris drifts to you instead of waiting to be walked over.",
	},
	{
		key = "vip",
		id = 0,
		name = "VIP",
		robux = 499,
		description = "A VIP-only estate, gold equipment skins and a permanent 1.25x.",
	},
	{
		key = "fastFeet",
		id = 0,
		name = "Fast Feet",
		robux = 149,
		description = "Move 30% faster on foot.",
	},
	{
		key = "infiniteFuel",
		id = 0,
		name = "Infinite Fuel",
		robux = 349,
		description = "Gas tools and vehicles never need refilling.",
	},
	{
		key = "instantDump",
		id = 0,
		name = "Instant Dump",
		robux = 599,
		description = "Sell your bag from anywhere on the property.",
	},
}

--------------------------------------------------------------------
-- Developer products (consumable)
--------------------------------------------------------------------

local products: { ProductDef } = {
	{
		key = "rentZeroTurn",
		id = 0,
		name = "Rent a Zero-Turn (2 min)",
		robux = 49,
		kind = "rental",
		toolId = "zero_turn",
		seconds = 120,
		description = "Two minutes on the mower everybody wants. Watch the lawn vanish.",
	},
	{
		key = "rentRidingMower",
		id = 0,
		name = "Rent a Riding Mower (2 min)",
		robux = 25,
		kind = "rental",
		toolId = "riding_mower",
		seconds = 120,
		description = "A cheaper first taste of sitting down to work.",
	},
	{
		key = "fuelCan",
		id = 0,
		name = "Fuel Can",
		robux = 10,
		kind = "fuel",
		description = "Instantly refill your tank to full.",
	},
	{
		key = "cashBoost3x",
		id = 0,
		name = "3x Cash (5 min)",
		robux = 39,
		kind = "cashBoost",
		multiplier = 3,
		seconds = 300,
		description = "Triple payout for five minutes. Fill the bag first.",
	},
	{
		key = "emptyBag",
		id = 0,
		name = "Empty Bag",
		robux = 15,
		kind = "bag",
		description = "Sell everything you are carrying without walking back.",
	},
	{
		key = "cleanSweep",
		id = 0,
		name = "Clean Sweep",
		robux = 99,
		kind = "sweep",
		fraction = 0.05,
		description = "Instantly clears 5% of the zone you are standing in.",
	},
	{
		key = "serverBoost",
		id = 0,
		name = "Neighbourhood Boost (10 min)",
		robux = 149,
		kind = "serverBoost",
		multiplier = 2,
		seconds = 600,
		description = "2x cash for everyone on the server. Your name goes on the announcement.",
	},
	{
		key = "extendRound",
		id = 0,
		name = "Extend Round (+10 min)",
		robux = 79,
		kind = "roundTime",
		seconds = 600,
		description = "Ten more minutes on the clock for the whole server.",
	},
}

Monetization.passes = passes
Monetization.products = products

local passByKey: { [string]: PassDef } = {}
local passById: { [number]: PassDef } = {}
for _, pass in passes do
	passByKey[pass.key] = pass
	if pass.id ~= 0 then
		passById[pass.id] = pass
	end
end

local productByKey: { [string]: ProductDef } = {}
local productById: { [number]: ProductDef } = {}
for _, product in products do
	productByKey[product.key] = product
	if product.id ~= 0 then
		productById[product.id] = product
	end
end

Monetization.passByKey = passByKey
Monetization.passById = passById
Monetization.productByKey = productByKey
Monetization.productById = productById

--- True once a real Roblox id has been pasted in for this entry.
function Monetization.isConfigured(id: number): boolean
	return id ~= 0
end

--------------------------------------------------------------------
-- Free reward loops
--
-- These exist so progression never depends on spending. A player who buys
-- nothing still gets a steady drip of cash and the occasional rental.
--------------------------------------------------------------------

Monetization.rewards = {
	--- Cash for logging in on consecutive days, indexed by streak day.
	dailyStreak = { 250, 600, 1400, 3000, 7000, 15000, 40000 },
	--- Granted every PLAYTIME_INTERVAL seconds of active play.
	playtimeInterval = 480,
	playtimeCash = 500,
	--- One free two-minute riding mower every this many seconds of play.
	freeRentalInterval = 1800,
	freeRentalToolId = "riding_mower",
	freeRentalSeconds = 120,
	--- Flat bonus the first time a player is on a server that reaches 100%.
	firstCompletionCash = 5000,
	--- Group members get a small permanent edge that costs nothing.
	groupBonusMultiplier = 1.05,
	groupId = 0,
}

return Monetization
