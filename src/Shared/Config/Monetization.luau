--!strict
--[[
	Monetization — every gamepass and developer product in one file.

	The ids below are PLACEHOLDERS. Create the passes and products on the Roblox
	creator dashboard, paste the real ids in, and nothing else in the codebase
	needs to change. Until then MonetizationService treats a zero id as "not
	configured" and quietly skips it, so the game runs fine unmonetised.

	See docs/MONETIZATION.md for the full setup walkthrough.
]]

local Tools = require(script.Parent.Tools)

local Monetization = {}

export type PassDef = {
	key: string,
	id: number,
	name: string,
	robux: number,
	description: string,
}

export type ProductKind =
	"rental"
	| "cashBoost"
	| "fuel"
	| "bag"
	| "sweep"
	| "serverBoost"
	| "roundTime"
	--- Unlocks a tool for the run in progress. Gone when the run ends, like
	--- every other thing bought with run cash.
	| "toolRun"
	--- Unlocks a tool for good. Handed back at the start of every future run,
	--- so it is a head start rather than a bigger number.
	| "toolPermanent"

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
		id = 1970440268,
		name = "2x Cash",
		robux = 199,
		description = "Every load you sell is worth double, forever.",
	},
	{
		key = "doubleBag",
		id = 1967898814,
		name = "2x Bag",
		robux = 249,
		description = "Twice the capacity. Half the trips to the trailer.",
	},
	--[[
		This said "Cut debris drifts to you instead of waiting to be walked
		over", which is a description of nothing: clippings go straight into
		the bag when they are cut, so a magnet for them has nothing to attract.
		AutoCollectService says as much in its own first paragraph — and then
		implements the useful thing instead, pulling in the log piles you had
		to drop when your bag filled at a tree, and the Golden Blades you
		walked past. Four hundred Robux was buying that and advertising a
		no-op.
	]]
	{
		key = "autoCollect",
		id = 1969206508,
		name = "Auto-Collect",
		robux = 399,
		description = "Dropped log piles and Golden Blades come to you as you walk, no prompts.",
	},
	--[[
		VIP said "A VIP-only estate, gold equipment skins and a permanent
		1.25x" and delivered the last third of that sentence. There is no
		fourth property and no `ZoneUnlock` kind a pass could gate one with;
		there is no cosmetic system of any kind in the codebase to hang a gold
		skin on. `Balance.cashMultiplier` applying 1.25 is the whole of it.

		Described as what it is. The price is a separate question and not one
		a description change should quietly answer: at 499 this buys a 1.25x
		while 2x Cash buys a 2x for 199, which only made sense while the other
		two thirds were meant to exist.
	]]
	{
		key = "vip",
		id = 1969158517,
		name = "VIP",
		--[[
			Repriced, and given a second perk that is worth having.

			At 499 for a 1.25x it was strictly worse than 2x Cash at 199, which
			only ever made sense while the estate and the skins in its old
			description were meant to exist. Doubling tips is the right kind of
			premium: tips buy permanent tools, so it changes how quickly a
			regular unlocks things and not how hard the lawn in front of them
			is. Nobody's run gets easier because somebody bought this.
		]]
		robux = 299,
		description = "A permanent 1.25x on everything you earn, and double tips from every stripe, blade and daily streak.",
	},
	{
		key = "fastFeet",
		id = 1968774518,
		name = "Fast Feet",
		robux = 149,
		description = "Move 30% faster on foot.",
	},
	{
		key = "infiniteFuel",
		id = 1967916808,
		name = "Infinite Fuel",
		robux = 349,
		description = "Gas tools and vehicles never need refilling.",
	},
	{
		key = "instantDump",
		id = 1968300719,
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
		id = 3711182520,
		name = "Rent a Zero-Turn (2 min)",
		robux = 49,
		kind = "rental",
		toolId = "zero_turn",
		seconds = 120,
		description = "Two minutes on the mower everybody wants. Watch the lawn vanish.",
	},
	{
		key = "rentRidingMower",
		id = 3711182451,
		name = "Rent a Riding Mower (2 min)",
		robux = 25,
		kind = "rental",
		toolId = "riding_mower",
		seconds = 120,
		description = "A cheaper first taste of sitting down to work.",
	},
	{
		key = "fuelCan",
		id = 3711182201,
		name = "Fuel Can",
		robux = 10,
		kind = "fuel",
		description = "Instantly refill your tank to full.",
	},
	{
		key = "cashBoost3x",
		id = 3711182500,
		name = "3x Cash (5 min)",
		robux = 39,
		kind = "cashBoost",
		multiplier = 3,
		seconds = 300,
		description = "Triple payout for five minutes. Fill the bag first.",
	},
	{
		key = "emptyBag",
		id = 3711182265,
		name = "Empty Bag",
		robux = 15,
		kind = "bag",
		description = "Sell everything you are carrying without walking back.",
	},
	{
		key = "cleanSweep",
		id = 3711182591,
		name = "Clean Sweep",
		robux = 99,
		kind = "sweep",
		fraction = 0.05,
		description = "Instantly clears 5% of the zone you are standing in.",
	},
	{
		key = "serverBoost",
		id = 3711182615,
		name = "Neighbourhood Boost (10 min)",
		robux = 149,
		kind = "serverBoost",
		multiplier = 2,
		seconds = 600,
		description = "2x cash for everyone on the server. Your name goes on the announcement.",
	},
	{
		key = "extendRound",
		id = 3711182585,
		name = "Extend Round (+10 min)",
		robux = 79,
		kind = "roundTime",
		seconds = 600,
		description = "Ten more minutes on the clock for the whole server.",
	},
}

--------------------------------------------------------------------
-- Tool unlocks
--
-- Every paid tool can be bought three ways: with the cash you earn during the
-- run, with Robux for this run only, or with Robux for good. The first is the
-- game; the other two are the two different things a player who wants to spend
-- is actually asking for — "get me past this one wall now" and "never start
-- from nothing again" — and selling only one of them serves half of them badly.
--
-- These are generated from the tool table rather than written out, because
-- thirty hand-maintained entries would drift from the tools they price the
-- first time a tool is renamed.
--------------------------------------------------------------------

--[[
	The two product ids each paid tool was given on the dashboard.

	Written out by tool rather than generated, because these are facts about
	the outside world: thirty products exist, each with an id Roblox chose,
	and nothing in this file can derive them. The loop below still builds the
	entries, so a tool renamed or repriced needs no work here — only a tool
	newly given a Robux price needs a row adding, and the test that refuses a
	duplicate id will say so if one is pasted twice.
]]
local TOOL_PRODUCT_IDS: { [string]: { run: number, forever: number } } = {
	reel_mower       = { run = 3711188116, forever = 3711188187 },
	rake             = { run = 3711188311, forever = 3711188387 },
	gas_mower        = { run = 3711188452, forever = 3711188528 },
	trimmer          = { run = 3711188601, forever = 3711188659 },
	blower           = { run = 3711188724, forever = 3711188783 },
	self_propelled   = { run = 3711188853, forever = 3711188938 },
	hedge_trimmer    = { run = 3711189035, forever = 3711189145 },
	pole_saw         = { run = 3711189253, forever = 3711189349 },
	chainsaw         = { run = 3711189430, forever = 3711189522 },
	riding_mower     = { run = 3711189633, forever = 3711189721 },
	backpack_blower  = { run = 3711189834, forever = 3711189902 },
	zero_turn        = { run = 3711189983, forever = 3711190052 },
	stump_grinder    = { run = 3711190160, forever = 3711190238 },
	wood_chipper     = { run = 3711190320, forever = 3711190406 },
	commercial_deck  = { run = 3711190508, forever = 3711190593 },
}

for _, tool in Tools.list do
	local once = tool.robuxOnce
	local permanent = tool.robuxPermanent
	local productIds = TOOL_PRODUCT_IDS[tool.id]
	if tool.cost > 0 and once and permanent then
		table.insert(products, {
			key = `tool_{tool.id}_run`,
			id = if productIds then productIds.run else 0,
			name = `{tool.name} — this run`,
			robux = once,
			kind = "toolRun",
			toolId = tool.id,
			description = `Skip the grind for {tool.name} once. Yours until the run ends.`,
		})
		table.insert(products, {
			key = `tool_{tool.id}_forever`,
			id = if productIds then productIds.forever else 0,
			name = `{tool.name} — forever`,
			robux = permanent,
			kind = "toolPermanent",
			toolId = tool.id,
			description = `Start every run with the {tool.name} already in your hands.`,
		})
	end
end

--- The two product keys that unlock `toolId`, for the shop to look up.
function Monetization.toolProductKeys(toolId: string): (string, string)
	return `tool_{toolId}_run`, `tool_{toolId}_forever`
end

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
	--[[
		Tips for logging in on consecutive days, indexed by streak day.

		Tips, not cash, and deliberately. Every run starts from nothing and the
		prices are in single dollars because of it — a rake is eight dollars —
		so handing a returning player two hundred and fifty of them on arrival
		bought the first half of the ladder before they had cut a blade of
		grass. Money is the thing you earn by working; tips are the thing you
		earn by turning up and by playing well, and they buy their own rewards.
	]]
	dailyStreak = { 3, 6, 10, 16, 24, 34, 50 },
	--- Granted every PLAYTIME_INTERVAL seconds of active play, also as tips.
	playtimeInterval = 480,
	playtimeTips = 5,
	--- One free two-minute riding mower every this many seconds of play.
	freeRentalInterval = 1800,
	freeRentalToolId = "riding_mower",
	freeRentalSeconds = 120,
	--[[
		Paid the first time a player is on a server that reaches 100%.

		It was five thousand in cash — nearly three times the whole of The
		House's gross — granted inside `winRun`, which is to say into a run
		that is over and about to be wiped. The player watched a number appear
		and evaporate, and `firstCompletionClaimed` made sure it never came
		again.

		In tips, it lands somewhere that lasts: a little more than a permanent
		Push Reel Mower, so beating your first property buys the thing that
		makes the next one start faster. Cash was never an option — the note
		above about the daily streak says why.
	]]
	firstCompletionTips = 250,
	--- Group members get a small permanent edge that costs nothing.
	groupBonusMultiplier = 1.05,
	groupId = 0,
}

return Monetization
