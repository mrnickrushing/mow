--!strict
--[[
	Upgrades — the stat lines sold at the boards in front of the shed.

	These are the upgrades that belong to the *player* rather than to any one
	tool: how much you carry, how fast you walk, what you charge, how far the
	trailer reaches. Cut speed and yield are not here — those belong to each
	tool's own three-slot tree in ToolUpgrades, which is where the journal
	sells them.

	Each line has a geometric cost curve (`baseCost * costGrowth^level`) and a
	value curve that is either additive or multiplicative from `base`. The bag
	is deliberately the cheapest early line: fewer trips to the trailer is the
	single biggest early-game speed-up.
]]

local Types = require(script.Parent.Parent.Types)

local Upgrades = {}

local list: { Types.UpgradeDef } = {
	{
		id = "bag",
		name = "Bag",
		description = "Carry more before you have to walk back to the trailer.",
		maxLevel = 15,
		baseCost = 3,
		costGrowth = 1.85,
		base = 25,
		step = 1.55,
		mode = "mul",
		suffix = " units",
	},
	{
		id = "walk",
		name = "Stride",
		description = "Move between the lawn and the trailer faster.",
		maxLevel = 10,
		baseCost = 6,
		costGrowth = 1.95,
		base = 16,
		step = 1.8,
		mode = "add",
		suffix = " studs/s",
	},
	{
		id = "cash",
		name = "Fortune",
		description = "Charge more for the same work.",
		maxLevel = 10,
		baseCost = 30,
		costGrowth = 2.3,
		base = 1,
		step = 0.15,
		mode = "add",
		suffix = "x cash",
	},
	{
		id = "fuel",
		name = "Reserve",
		description = "Run gas tools and vehicles longer between refills.",
		maxLevel = 8,
		baseCost = 60,
		costGrowth = 2.2,
		base = 100,
		step = 1.25,
		mode = "mul",
		suffix = " L",
	},
	{
		id = "trailer",
		name = "Haul",
		description = "Level 1 unlocks the portable trailer. Later levels widen its dump radius.",
		maxLevel = 5,
		baseCost = 90,
		costGrowth = 2.4,
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
