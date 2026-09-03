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
		id = "hands",
		name = "Bare Hands",
		tier = 0,
		category = "Hand",
		mode = "pickup",
		cost = 0,
		currency = "Cash",
		deck = 1,
		power = 1,
		--[[
			Deliberately miserable.

			Hands clear every kind of debris at full height, which is what
			stops a broke player being stranded — but it also made them a
			universal tool good enough to finish The House with, so the
			simulated player bought nothing all run and the mowers went
			unsold. They still work on anything; they are simply the slowest
			and shortest-reaching way to do it, so the first ten dollars
			always want to become a mower.
		]]
		rate = 0.7,
		reach = 5,
		-- Everything starts here, so hands have to be able to shift anything a
		-- tile can hold. Otherwise a section full of something you cannot afford
		-- the tool for is a dead run, which the simulator found the hard way.
		-- Every other tool is a speed upgrade, never a gate.
		clears = { Debris.Leaves, Debris.Grass, Debris.Weeds, Debris.Hedge, Debris.Sticks },
		maxHeight = 3,
		fuelBurn = 0,
		description = "One armful at a time. It is going to be a long afternoon.",
	},
	{
		id = "reel_mower",
		name = "Push Reel Mower",
		tier = 1,
		category = "Mower",
		-- Tuft by tuft, like the hands it replaces — just faster and deeper.
		-- Swath mowing is what the ride-on mowers sell: the moment you sit on a
		-- zero turn and a whole stripe of lawn vanishes under you is the single
		-- biggest before/after in the game, and it only lands if everything
		-- before it worked one patch at a time.
		mode = "pickup",
		--[[
			The first rung, because the first rung should mow.

			The rake used to sit here at eight against this mower's twenty-five,
			so the opening purchase of a lawn-mowing game was a rake and the
			opening minutes were spent raking. They have swapped places and
			prices; the rake is still the right tool for a drift of leaves, just
			no longer the first thing anybody buys.
		]]
		cost = 10,
		currency = "Cash",
		deck = 1,
		power = 1,
		rate = 2.0,
		reach = 7,
		clears = { Debris.Grass },
		maxHeight = 2,
		fuelBurn = 0,
		robuxOnce = 25,
		robuxPermanent = 60,
		robuxWas = 149,
		tipsPermanent = 200,
		description = "No engine, no fuel, no mercy on your calves.",
	},
	{
		id = "rake",
		name = "Rake",
		tier = 2,
		category = "Rake",
		mode = "pickup",
		cost = 30,
		currency = "Cash",
		deck = 1,
		power = 2,
		rate = 1.5,
		reach = 6,
		clears = { Debris.Leaves },
		maxHeight = 3,
		fuelBurn = 0,
		robuxOnce = 35,
		robuxPermanent = 80,
		robuxWas = 199,
		tipsPermanent = 400,
		description = "For the leaves you would be all day picking up by hand.",
	},
	{
		id = "gas_mower",
		name = "Gas Push Mower",
		tier = 3,
		category = "Mower",
		cost = 60,
		currency = "Cash",
		deck = 2,
		power = 2,
		rate = 3.0,
		reach = 8,
		clears = { Debris.Grass },
		maxHeight = 3,
		fuelBurn = 0.6,
		robuxOnce = 45,
		robuxPermanent = 99,
		robuxWas = 249,
		tipsPermanent = 1200,
		description = "The first time the lawn stops fighting back.",
	},
	{
		id = "trimmer",
		name = "String Trimmer",
		tier = 4,
		category = "Trimmer",
		cost = 140,
		currency = "Cash",
		deck = 1,
		power = 3,
		rate = 4.0,
		reach = 7,
		clears = { Debris.Weeds, Debris.Grass },
		maxHeight = 3,
		fuelBurn = 0.8,
		robuxOnce = 55,
		robuxPermanent = 120,
		robuxWas = 299,
		tipsPermanent = 2500,
		description = "Eats weeds. Edges like a surgeon. Loud as a chainsaw.",
	},
	{
		id = "blower",
		name = "Leaf Blower",
		tier = 5,
		category = "Blower",
		toggle = true,
		cost = 320,
		currency = "Cash",
		deck = 3,
		power = 3,
		rate = 5.0,
		reach = 14,
		clears = { Debris.Leaves },
		maxHeight = 3,
		fuelBurn = 1.0,
		robuxOnce = 90,
		robuxPermanent = 180,
		robuxWas = 529,
		description = "Clears a cone of leaves in one sweep. Deeply satisfying.",
	},
	{
		id = "self_propelled",
		name = "Self-Propelled Mower",
		tier = 6,
		category = "Mower",
		cost = 700,
		currency = "Cash",
		deck = 3,
		power = 3,
		rate = 4.0,
		reach = 9,
		clears = { Debris.Grass },
		maxHeight = 3,
		fuelBurn = 1.2,
		robuxOnce = 99,
		robuxPermanent = 220,
		robuxWas = 599,
		description = "It pulls you along. You just steer and collect.",
	},
	{
		id = "hedge_trimmer",
		name = "Hedge Trimmer",
		tier = 7,
		category = "HedgeTrimmer",
		cost = 1500,
		currency = "Cash",
		deck = 2,
		power = 3,
		rate = 3.5,
		reach = 8,
		clears = { Debris.Hedge },
		maxHeight = 3,
		fuelBurn = 1.0,
		robuxOnce = 120,
		robuxPermanent = 260,
		robuxWas = 699,
		description = "Turns a shapeless bush into a crisp green box.",
	},
	{
		id = "pole_saw",
		name = "Pole Saw",
		tier = 8,
		category = "Saw",
		cost = 3200,
		currency = "Cash",
		deck = 1,
		power = 3,
		rate = 2.0,
		reach = 10,
		clears = { Debris.Sticks },
		maxHeight = 3,
		fuelBurn = 1.1,
		robuxOnce = 140,
		robuxPermanent = 300,
		robuxWas = 799,
		description = "Reaches the branches you would rather not climb to.",
	},
	{
		id = "chainsaw",
		name = "Chainsaw",
		tier = 9,
		category = "Chainsaw",
		cost = 6800,
		currency = "Cash",
		deck = 1,
		power = 3,
		rate = 3.0,
		reach = 9,
		clears = { Debris.Sticks },
		maxHeight = 3,
		fuelBurn = 1.6,
		robuxOnce = 160,
		robuxPermanent = 350,
		robuxWas = 899,
		description = "Fells whole trees. Logs pay better than anything on the lawn.",
	},
	{
		id = "riding_mower",
		name = "Riding Mower",
		tier = 10,
		category = "Mower",
		cost = 14000,
		currency = "Cash",
		deck = 5,
		power = 3,
		rate = 6.0,
		reach = 12,
		clears = { Debris.Grass },
		maxHeight = 3,
		fuelBurn = 2.0,
		vehicle = { speed = 34, turnSpeed = 2.4, seatOffset = 2.2 },
		robuxOnce = 199,
		robuxPermanent = 420,
		robuxWas = 1099,
		description = "You sit down. The lawn disappears. Worth every dollar.",
	},
	{
		id = "backpack_blower",
		name = "Industrial Backpack Blower",
		tier = 11,
		category = "Blower",
		toggle = true,
		cost = 30000,
		currency = "Cash",
		deck = 6,
		power = 3,
		rate = 9.0,
		reach = 20,
		clears = { Debris.Leaves },
		maxHeight = 3,
		fuelBurn = 2.4,
		robuxOnce = 220,
		robuxPermanent = 460,
		robuxWas = 1199,
		description = "Moves a season of leaves in a single walk.",
	},
	{
		id = "zero_turn",
		name = "Zero-Turn Mower",
		tier = 12,
		category = "Mower",
		cost = 65000,
		currency = "Cash",
		deck = 7,
		power = 3,
		rate = 8.0,
		reach = 14,
		clears = { Debris.Grass, Debris.Weeds },
		maxHeight = 3,
		fuelBurn = 3.0,
		vehicle = { speed = 48, turnSpeed = 4.2, seatOffset = 2.4 },
		robuxOnce = 260,
		robuxPermanent = 550,
		robuxWas = 1399,
		description = "Pivots on a dime. The one everybody rents before they buy.",
	},
	{
		id = "stump_grinder",
		name = "Stump Grinder",
		tier = 13,
		category = "Grinder",
		cost = 140000,
		currency = "Cash",
		deck = 1,
		power = 3,
		rate = 2.0,
		reach = 8,
		clears = {},
		maxHeight = 3,
		fuelBurn = 2.8,
		robuxOnce = 290,
		robuxPermanent = 620,
		robuxWas = 1599,
		description = "The only thing that removes a stump. Pays in wood chips.",
	},
	{
		id = "wood_chipper",
		name = "Wood Chipper",
		tier = 14,
		category = "Chipper",
		cost = 300000,
		currency = "Cash",
		deck = 1,
		power = 0,
		rate = 1.0,
		reach = 8,
		clears = {},
		maxHeight = 3,
		fuelBurn = 0,
		robuxOnce = 320,
		robuxPermanent = 680,
		robuxWas = 1749,
		description = "Bolted to your trailer. Every log and stump you sell is worth triple.",
	},
	{
		id = "commercial_deck",
		name = "Commercial Deck Mower",
		tier = 15,
		category = "Mower",
		cost = 650000,
		currency = "Cash",
		deck = 11,
		power = 3,
		rate = 10.0,
		reach = 18,
		clears = { Debris.Grass, Debris.Weeds },
		maxHeight = 3,
		fuelBurn = 4.0,
		vehicle = { speed = 52, turnSpeed = 3.0, seatOffset = 2.6 },
		robuxOnce = 380,
		robuxPermanent = 800,
		robuxWas = 1999,
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
Tools.STARTER_ID = "hands"

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

--[[
	The cheapest proper tool for this debris — the starter does not count.

	Used to answer "why did nothing happen" with something a player can act
	on. Bare hands clear everything, so the honest cheapest answer is always
	"your hands", and a message that only ever says that is no use to somebody
	who has just bought a mower. This names the thing the job actually wants;
	the caller is expected to mention the hands as well, because they are free
	and already in the player's pocket.
]]
function Tools.cheapestFor(debrisId: number): Types.ToolDef?
	local best: Types.ToolDef? = nil
	for _, tool in list do
		if tool.currency == "Cash" and tool.id ~= Tools.STARTER_ID then
			for _, id in tool.clears do
				if id == debrisId and (best == nil or tool.cost < best.cost) then
					best = tool
				end
			end
		end
	end
	return best
end

return Tools
