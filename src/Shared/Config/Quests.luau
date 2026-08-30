--!strict
--[[
	Quests — the starter chain that teaches the game by playing it.

	A completion bar tells a player how much is left; it does not tell them what
	to do next. The reference solves that with a short list of concrete
	objectives — collect some, sell some, open the book, buy an upgrade, find the
	garage switch — each of which walks the player through a system they would
	otherwise have to discover.

	Progress is counted server-side against these ids; nothing here knows how the
	counting happens.
]]

local Quests = {}

export type Kind =
	--- Debris units gathered into the bag.
	"collect"
	--- Debris units sold at the trailer.
	| "sell"
	--- Opened the journal.
	| "journal"
	--- Bought any upgrade level.
	| "upgrade"
	--- Bought any tool.
	| "tool"
	--- Unlocked a zone by any means.
	| "zone"
	--- Cleared a whole zone.
	| "clearZone"
	--- Banked a Clean Stripe.
	| "stripe"

export type Quest = {
	id: string,
	kind: Kind,
	text: string,
	target: number,
	--- Cash paid on completion.
	reward: number,
	--- Restricts the objective to one zone, tool or upgrade where it matters.
	subject: string?,
}

--[[
	Ordered. The player works one at a time, so each should be doable with what
	the one before it gave them.
]]
local list: { Quest } = {
	{
		id = "collect_first",
		kind = "collect",
		text = "Collect 5 leaves",
		target = 5,
		reward = 25,
	},
	{
		id = "sell_first",
		kind = "sell",
		text = "Sell 5 leaves",
		target = 5,
		reward = 40,
	},
	{
		id = "open_journal",
		kind = "journal",
		text = "Open your journal (TAB)",
		target = 1,
		reward = 30,
	},
	{
		id = "first_upgrade",
		kind = "upgrade",
		text = "Buy your first upgrade",
		target = 1,
		reward = 75,
	},
	{
		id = "open_garage",
		kind = "zone",
		text = "Find the switch and open the garage",
		target = 1,
		reward = 250,
		subject = "garage",
	},
	{
		id = "collect_hundred",
		kind = "collect",
		text = "Collect 100 leaves",
		target = 100,
		reward = 200,
	},
	{
		id = "first_tool",
		kind = "tool",
		text = "Buy a proper tool from the shed",
		target = 1,
		reward = 300,
	},
	{
		id = "clear_front",
		kind = "clearZone",
		text = "Clear the Front Yard completely",
		target = 1,
		reward = 900,
		subject = "front_yard",
	},
	{
		id = "first_stripe",
		kind = "stripe",
		text = "Bank a clean stripe",
		target = 1,
		reward = 400,
	},
	{
		id = "sell_thousand",
		kind = "sell",
		text = "Sell 1,000 units in total",
		target = 1000,
		reward = 1500,
	},
}

Quests.list = list

local byId: { [string]: Quest } = {}
for _, quest in list do
	byId[quest.id] = quest
end
Quests.byId = byId

function Quests.get(id: string): Quest?
	return byId[id]
end

--- Position of a quest in the chain, or nil if unknown.
function Quests.indexOf(id: string): number?
	for index, quest in list do
		if quest.id == id then
			return index
		end
	end
	return nil
end

return Quests
