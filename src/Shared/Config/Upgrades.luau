--!strict
--[[
	Upgrades — the six purchasable stat lines sold at the Shed.

	Each line has a geometric cost curve (`baseCost * costGrowth^level`) and a
	value curve that is either additive or multiplicative from `base`.

	Bag Capacity is deliberately the cheapest early line: fewer trips to the
	trailer is the single biggest early-game speed-up, which mirrors how the
	reference game's players rank bag upgrades first.
]]

local Types = require(script.Parent.Parent.Types)

local Upgrades = {}

local list: { Types.UpgradeDef } = {
	{
		id = "bag",
		name = "Leaf Bag",
		description = "Carry more before you have to walk back to the trailer.",
		maxLevel = 15,
		baseCost = 250,
		costGrowth = 2.35,
		base = 25,
		step = 1.55,
		mode = "mul",
		suffix = " units",
	},
	{
		id = "speed",
		name = "Cut Speed",
		description = "Sharper blades swing faster and bite deeper into tall grass.",
		-- Deliberately short. A tile cannot take less than one pass, so past a
		-- few levels this line would be selling nothing. Four honest levels beat
		-- twelve where most do not move the number.
		maxLevel = 4,
		baseCost = 200,
		costGrowth = 2.1,
		base = 1,
		step = 0.16,
		mode = "add",
		suffix = "x",
	},
	{
		id = "yield",
		name = "Mulching Blades",
		description = "Chop finer and get more out of every square of lawn.",
		maxLevel = 12,
		baseCost = 900,
		costGrowth = 2.55,
		base = 1,
		step = 0.18,
		mode = "add",
		suffix = "x debris",
	},
	{
		id = "walk",
		name = "Work Boots",
		description = "Move between the lawn and the trailer faster.",
		maxLevel = 10,
		baseCost = 450,
		costGrowth = 2.1,
		base = 16,
		step = 1.8,
		mode = "add",
		suffix = " studs/s",
	},
	{
		id = "cash",
		name = "Business Sense",
		description = "Charge more for the same work.",
		maxLevel = 10,
		baseCost = 1200,
		costGrowth = 2.8,
		base = 1,
		step = 0.15,
		mode = "add",
		suffix = "x cash",
	},
	{
		id = "fuel",
		name = "Fuel Tank",
		description = "Run gas tools and vehicles longer between refills.",
		maxLevel = 8,
		baseCost = 5000,
		costGrowth = 2.5,
		base = 100,
		step = 1.25,
		mode = "mul",
		suffix = " L",
	},
	{
		id = "trailer",
		name = "Trailer Hitch",
		description = "Level 1 unlocks the portable trailer. Later levels widen its dump radius.",
		maxLevel = 5,
		baseCost = 4000,
		costGrowth = 2.7,
		base = 12,
		step = 6,
		mode = "add",
		suffix = " studs",
	},
}

Upgrades.list = list

local byId: { [string]: Types.UpgradeDef } = {}
for _, def in list do
	byId[def.id] = def
end
Upgrades.byId = byId

--- Level at which the portable trailer becomes available.
Upgrades.PORTABLE_TRAILER_LEVEL = 1

function Upgrades.get(id: string): Types.UpgradeDef?
	return byId[id]
end

--- Cost of moving from `level` to `level + 1`. Returns nil when maxed.
function Upgrades.costAt(def: Types.UpgradeDef, level: number): number?
	if level >= def.maxLevel then
		return nil
	end
	return math.floor(def.baseCost * def.costGrowth ^ level)
end

--- The stat value a player has at `level` of this line.
function Upgrades.valueAt(def: Types.UpgradeDef, level: number): number
	local clamped = math.clamp(level, 0, def.maxLevel)
	if def.mode == "mul" then
		return def.base * def.step ^ clamped
	end
	return def.base + def.step * clamped
end

return Upgrades
