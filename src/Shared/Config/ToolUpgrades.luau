--!strict
--[[
	ToolUpgrades — the three upgrades every tool carries.

	Upgrades belong to tools, not to the player: your hand learns Hold,
	Dexterity and Grasp; a rake you have never bought shows three padlocks and
	three question marks. That does two things the one global list could not.
	It gives every new tool its own little ladder to climb — buying the rake is
	the start of something, not just a stat — and it makes the journal's
	upgrade page readable at a glance: the thing in your hands, and what it
	could become.

	Every tool's tree is the same shape — one upgrade for how hard it hits, one
	for how fast it swings, one for how much each cut yields — because a shape
	the player learns on the hand should transfer to the chainsaw untaught.
	Only the names change with the tool, and the names carry the flavour.

	Levels live in the same table as the shed lines, keyed `toolId/slot`, so
	nothing downstream has to know two kinds of upgrade exist.
]]

local Tools = require(script.Parent.Tools)
local Types = require(script.Parent.Parent.Types)

local ToolUpgrades = {}

export type SlotKind = "power" | "rate" | "yield"

export type Slot = {
	--- `toolId/slot`, the key its level is stored under.
	key: string,
	slot: SlotKind,
	name: string,
	description: string,
	--- The tool category this slot belongs to, which is what the book turns
	--- into the model on its tile. Not the model name itself: this is shared
	--- config, and the catalogue it would have to read is full of `Vector3`s
	--- that do not exist outside Roblox, which puts it out of reach of the
	--- tests that check this table.
	category: string,
	baseCost: number,
	costGrowth: number,
	maxLevel: number,
	--- Additive step per level: power in height-levels, rate and yield in x.
	step: number,
}

ToolUpgrades.MAX_LEVEL = 5
ToolUpgrades.COST_GROWTH = 1.8

--- What one level buys, per slot kind. Power is worth the most per level and
--- costs the most: biting deeper turns three passes into two, which reads
--- bigger than any percentage.
local STEP: { [SlotKind]: number } = {
	power = 0.5,
	rate = 0.14,
	yield = 0.15,
}

--- Slot cost as a fraction of the tool's own price, floored so the free hand
--- still charges the reference's pocket-change prices (1.00$ / 0.50$ / 0.75$).
local COST_FRACTION: { [SlotKind]: number } = {
	power = 0.12,
	rate = 0.08,
	yield = 0.1,
}
local COST_FLOOR: { [SlotKind]: number } = {
	power = 1,
	rate = 0.5,
	yield = 0.75,
}

--- Per-category names, in power/rate/yield order. The shape never changes;
--- the words are the tool's own.
--- Per-category names, in power/rate/yield order. The shape never changes;
--- the words are the tool's own. Each carried an emoji beside it until the
--- interface stopped being drawn in emoji; the picture is the tool's model
--- now, which `Props.forToolCategory` knows, so a name is all that is left.
local NAMES: { [string]: { string } } = {
	Hand = { "Hold", "Dexterity", "Grasp" },
	Shears = { "Edge", "Snip", "Bundle" },
	Rake = { "Tines", "Sweep", "Gather" },
	Mower = { "Blades", "Throttle", "Catcher" },
	Trimmer = { "Line", "Revs", "Guard" },
	Blower = { "Nozzle", "Turbo", "Cyclone" },
	HedgeTrimmer = { "Teeth", "Motor", "Mulcher" },
	Saw = { "Bar", "Stroke", "Splitter" },
	Chainsaw = { "Chain", "Engine", "Timber" },
	Grinder = { "Wheel", "Torque", "Shavings" },
	Chipper = { "Drum", "Feed", "Hopper" },
}

local BLURBS: { [SlotKind]: string } = {
	power = "Bite deeper — clear tall growth in fewer passes.",
	rate = "Work faster — more swings every second.",
	yield = "Waste less — more clippings from every cut.",
}

--------------------------------------------------------------------
-- Trees
--------------------------------------------------------------------

local trees: { [string]: { Slot } } = {}

local function makeSlot(tool: Types.ToolDef, index: number, kind: SlotKind): Slot
	local names = NAMES[tool.category] or NAMES.Hand
	return {
		key = `{tool.id}/{kind}`,
		slot = kind,
		name = names[index],
		description = BLURBS[kind],
		category = tool.category,
		baseCost = math.max(tool.cost * COST_FRACTION[kind], COST_FLOOR[kind]),
		costGrowth = ToolUpgrades.COST_GROWTH,
		maxLevel = ToolUpgrades.MAX_LEVEL,
		step = STEP[kind],
	}
end

for _, tool in Tools.list do
	trees[tool.id] = {
		makeSlot(tool, 1, "power"),
		makeSlot(tool, 2, "rate"),
		makeSlot(tool, 3, "yield"),
	}
end

--- The three upgrade slots for a tool, power/rate/yield order.
function ToolUpgrades.treeFor(toolId: string): { Slot }
	return trees[toolId] or {}
end

--- Cost of moving a slot from `level` to `level + 1`, or nil at max.
function ToolUpgrades.costAt(slot: Slot, level: number): number?
	if level >= slot.maxLevel then
		return nil
	end
	local cost = slot.baseCost * slot.costGrowth ^ level
	-- Kept to cents rather than floored to dollars, because the hand's ladder
	-- starts at fifty cents and flooring would sell its first levels free.
	return math.floor(cost * 100) / 100
end

--------------------------------------------------------------------
-- Effects
--------------------------------------------------------------------

local function levelOf(levels: { [string]: number }, toolId: string, kind: SlotKind): number
	return levels[`{toolId}/{kind}`] or 0
end

--- Extra height-levels per pass this tool has bought.
function ToolUpgrades.powerBonus(levels: { [string]: number }, toolId: string): number
	return levelOf(levels, toolId, "power") * STEP["power" :: SlotKind]
end

--- Swing-speed multiplier for this tool, 1 with nothing bought.
function ToolUpgrades.rateMultiplier(levels: { [string]: number }, toolId: string): number
	return 1 + levelOf(levels, toolId, "rate") * STEP["rate" :: SlotKind]
end

--- Clippings-per-cut multiplier for this tool, 1 with nothing bought.
function ToolUpgrades.yieldMultiplier(levels: { [string]: number }, toolId: string): number
	return 1 + levelOf(levels, toolId, "yield") * STEP["yield" :: SlotKind]
end

--- The slot a stored key refers to, for purchase validation.
function ToolUpgrades.slotByKey(key: string): (Slot?, Types.ToolDef?)
	local toolId = string.match(key, "^([%w_]+)/%a+$")
	if not toolId then
		return nil, nil
	end
	local tool = Tools.get(toolId)
	if not tool then
		return nil, nil
	end
	for _, slot in trees[toolId] do
		if slot.key == key then
			return slot, tool
		end
	end
	return nil, tool
end

return ToolUpgrades
