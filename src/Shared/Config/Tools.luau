--!strict
--[[
	Tools — the sixteen-tier equipment ladder.

	`deck` (swath width in tiles) is the headline stat: width is felt far more
	than raw speed, so it carries most of the sense of progression. `power` is
	how many height levels come off per pass, which is why an early mower needs
	three passes over tall grass and a late one takes it in one.

	`maxHeight` is the overgrowth gate. A tool bogs down and refuses tiles taller
	than it can bite, so the player runs into a wall they can feel rather than a
	greyed-out button.
]]

local Debris = require(script.Parent.Debris)
local Types = require(script.Parent.Parent.Types)

local Tools = {}

local list: { Types.ToolDef } = {
	{
		id = "shears",
		name = "Hand Shears",
		tier = 0,
		category = "Shears",
		cost = 0,
		currency = "Cash",
		deck = 1,
		power = 1,
		rate = 1.2,
		reach = 5,
		clears = { Debris.Grass },
		maxHeight = 2,
		fuelBurn = 0,
		description = "Two blades and a bad attitude. It cuts grass. Barely.",
	},
	{
		id = "rake",
		name = "Rake",
		tier = 1,
		category = "Rake",
		cost = 12,
		currency = "Cash",
		deck = 1,
		power = 2,
		rate = 1.5,
		reach = 6,
		clears = { Debris.Leaves },
		maxHeight = 3,
		fuelBurn = 0,
		description = "For the leaves the mower just laughs at.",
	},
	{
		id = "reel_mower",
		name = "Push Reel Mower",
		tier = 2,
		category = "Mower",
		cost = 60,
		currency = "Cash",
		deck = 1,
		power = 1,
		rate = 2.0,
		reach = 7,
		clears = { Debris.Grass },
		maxHeight = 2,
		fuelBurn = 0,
		description = "No engine, no fuel, no mercy on your calves.",
	},
	{
		id = "gas_mower",
		name = "Gas Push Mower",
		tier = 3,
		category = "Mower",
		cost = 450,
		currency = "Cash",
		deck = 2,
		power = 2,
		rate = 3.0,
		reach = 8,
		clears = { Debris.Grass },
		maxHeight = 3,
		fuelBurn = 0.6,
		description = "The first time the lawn stops fighting back.",
	},
	{
		id = "trimmer",
		name = "String Trimmer",
		tier = 4,
		category = "Trimmer",
		cost = 2500,
		currency = "Cash",
		deck = 1,
		power = 3,
		rate = 4.0,
		reach = 7,
		clears = { Debris.Weeds, Debris.Grass },
		maxHeight = 3,
		fuelBurn = 0.8,
		description = "Eats weeds. Edges like a surgeon. Loud as a chainsaw.",
	},
	{
		id = "blower",
		name = "Leaf Blower",
		tier = 5,
		category = "Blower",
		cost = 9000,
		currency = "Cash",
		deck = 3,
		power = 3,
		rate = 5.0,
		reach = 14,
		clears = { Debris.Leaves },
		maxHeight = 3,
		fuelBurn = 1.0,
		description = "Clears a cone of leaves in one sweep. Deeply satisfying.",
	},
	{
		id = "self_propelled",
		name = "Self-Propelled Mower",
		tier = 6,
		category = "Mower",
		cost = 9000,
		currency = "Cash",
		deck = 3,
		power = 3,
		rate = 4.0,
		reach = 9,
		clears = { Debris.Grass },
		maxHeight = 3,
		fuelBurn = 1.2,
		description = "It pulls you along. You just steer and collect.",
	},
	{
		id = "hedge_trimmer",
		name = "Hedge Trimmer",
		tier = 7,
		category = "HedgeTrimmer",
		cost = 30000,
		currency = "Cash",
		deck = 2,
		power = 3,
		rate = 3.5,
		reach = 8,
		clears = { Debris.Hedge },
		maxHeight = 3,
		fuelBurn = 1.0,
		description = "Turns a shapeless bush into a crisp green box.",
	},
	{
		id = "pole_saw",
		name = "Pole Saw",
		tier = 8,
		category = "Saw",
		cost = 60000,
		currency = "Cash",
		deck = 1,
		power = 3,
		rate = 2.0,
		reach = 10,
		clears = { Debris.Sticks },
		maxHeight = 3,
		fuelBurn = 1.1,
		description = "Reaches the branches you would rather not climb to.",
	},
	{
		id = "chainsaw",
		name = "Chainsaw",
		tier = 9,
		category = "Chainsaw",
		cost = 90000,
		currency = "Cash",
		deck = 1,
		power = 3,
		rate = 3.0,
		reach = 9,
		clears = { Debris.Sticks },
		maxHeight = 3,
		fuelBurn = 1.6,
		description = "Fells whole trees. Logs pay better than anything on the lawn.",
	},
	{
		id = "riding_mower",
		name = "Riding Mower",
		tier = 10,
		category = "Mower",
		cost = 260000,
		currency = "Cash",
		deck = 5,
		power = 3,
		rate = 6.0,
		reach = 12,
		clears = { Debris.Grass },
		maxHeight = 3,
		fuelBurn = 2.0,
		vehicle = { speed = 34, turnSpeed = 2.4, seatOffset = 2.2 },
		description = "You sit down. The lawn disappears. Worth every dollar.",
	},
	{
		id = "backpack_blower",
		name = "Industrial Backpack Blower",
		tier = 11,
		category = "Blower",
		cost = 900000,
		currency = "Cash",
		deck = 6,
		power = 3,
		rate = 9.0,
		reach = 20,
		clears = { Debris.Leaves },
		maxHeight = 3,
		fuelBurn = 2.4,
		description = "Moves a season of leaves in a single walk.",
	},
	{
		id = "zero_turn",
		name = "Zero-Turn Mower",
		tier = 12,
		category = "Mower",
		cost = 2400000,
		currency = "Cash",
		deck = 7,
		power = 3,
		rate = 8.0,
		reach = 14,
		clears = { Debris.Grass, Debris.Weeds },
		maxHeight = 3,
		fuelBurn = 3.0,
		vehicle = { speed = 48, turnSpeed = 4.2, seatOffset = 2.4 },
		description = "Pivots on a dime. The one everybody rents before they buy.",
	},
	{
		id = "stump_grinder",
		name = "Stump Grinder",
		tier = 13,
		category = "Grinder",
		cost = 6000000,
		currency = "Cash",
		deck = 1,
		power = 3,
		rate = 2.0,
		reach = 8,
		clears = {},
		maxHeight = 3,
		fuelBurn = 2.8,
		description = "The only thing that removes a stump. Pays in wood chips.",
	},
	{
		id = "wood_chipper",
		name = "Wood Chipper",
		tier = 14,
		category = "Chipper",
		cost = 14000000,
		currency = "Cash",
		deck = 1,
		power = 0,
		rate = 1.0,
		reach = 8,
		clears = {},
		maxHeight = 3,
		fuelBurn = 0,
		description = "Deployable. Feed it logs, get triple the money back.",
	},
	{
		id = "commercial_deck",
		name = "Commercial Deck Mower",
		tier = 15,
		category = "Mower",
		cost = 34000000,
		currency = "Cash",
		deck = 11,
		power = 3,
		rate = 10.0,
		reach = 18,
		clears = { Debris.Grass, Debris.Weeds },
		maxHeight = 3,
		fuelBurn = 4.0,
		vehicle = { speed = 52, turnSpeed = 3.0, seatOffset = 2.6 },
		description = "Eleven tiles wide. Municipal contractors weep.",
	},
}

Tools.list = list

local byId: { [string]: Types.ToolDef } = {}
for _, tool in list do
	byId[tool.id] = tool
end
Tools.byId = byId

--- The tool every account starts with.
Tools.STARTER_ID = "shears"

function Tools.get(id: string): Types.ToolDef?
	return byId[id]
end

function Tools.expect(id: string): Types.ToolDef
	local tool = byId[id]
	assert(tool, `unknown tool id {id}`)
	return tool
end

--- True when this tool is ridden rather than carried.
function Tools.isVehicle(tool: Types.ToolDef): boolean
	return tool.vehicle ~= nil
end

--- True when the tool can bite a tile holding `debrisId` at `height`.
--- Both the debris match and the overgrowth gate must pass.
function Tools.canCut(tool: Types.ToolDef, debrisId: number, height: number): boolean
	if height <= 0 or height > tool.maxHeight then
		return false
	end
	for _, id in tool.clears do
		if id == debrisId then
			return true
		end
	end
	return false
end

return Tools
