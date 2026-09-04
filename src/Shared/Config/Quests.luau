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
	--- Opened a section by any means.
	| "section"
	--- Cleared a whole section.
	| "clearSection"
	--- Banked a Clean Stripe.
	| "stripe"

export type Quest = {
	id: string,
	kind: Kind,
	text: string,
	target: number,
	--- Cash paid on completion.
	reward: number,
	--- Restricts the objective to one zone, debris type or upgrade where it
	--- matters. `collect` reads it as a debris kind: "grass" counts only grass.
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
		text = "Mow 5 tufts of grass",
		target = 5,
		reward = 0.5,
		subject = "grass",
	},
	{
		id = "sell_first",
		kind = "sell",
		text = "Sell 5 units of clippings",
		target = 5,
		reward = 1,
	},
	{
		id = "open_journal",
		kind = "journal",
		-- No key named: nearly every player is on a tablet, where the journal
		-- is the Book on the right of the screen and there is no TAB to press.
		text = "Open your journal",
		target = 1,
		reward = 1,
	},
	{
		id = "first_upgrade",
		kind = "upgrade",
		text = "Buy your first upgrade",
		target = 1,
		reward = 2,
	},
	{
		id = "open_garage",
		kind = "section",
		text = "Find the switch and open the garage",
		target = 1,
		reward = 6,
		subject = "garage",
	},
	{
		id = "collect_hundred",
		kind = "collect",
		text = "Mow 100 patches of grass",
		target = 100,
		reward = 5,
		subject = "grass",
	},
	{
		id = "first_tool",
		kind = "tool",
		-- Not "from the shed" any more: walking up to the shed used to fling the
		-- journal open and no longer does, so a player following that sentence
		-- walks the length of the property to a building that does nothing. The
		-- book is where tools are bought, from wherever you are standing.
		text = "Buy a proper tool from your book",
		target = 1,
		reward = 8,
	},
	{
		id = "clear_front",
		kind = "clearSection",
		text = "Clear the Front Yard completely",
		target = 1,
		reward = 25,
		subject = "front_yard",
	},
	{
		id = "first_stripe",
		kind = "stripe",
		text = "Bank a clean stripe",
		target = 1,
		reward = 12,
	},
	{
		id = "sell_thousand",
		kind = "sell",
		text = "Sell 1,000 units in total",
		target = 1000,
		reward = 40,
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
