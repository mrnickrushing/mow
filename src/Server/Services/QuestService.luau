--!strict
--[[
	QuestService — tracks the starter chain.

	Counting happens here, driven by signals the rest of the game already emits,
	so no service has to know quests exist. The player works one objective at a
	time; finishing it pays out and advances to the next.

	Progress is kept per quest id rather than as a single index, so reordering or
	inserting a quest later never rewinds anyone's save.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DebrisConfig = require(Shared.Config.Debris)
local Format = require(Shared.Util.Format)
local Quests = require(Shared.Config.Quests)
local Remotes = require(Shared.Remotes)
local BagService = require(script.Parent.BagService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local TileService = require(script.Parent.TileService)
local WorldService = require(script.Parent.WorldService)

local QuestService = {}

local questRemote: RemoteEvent

--- Guards `catchUp` against re-entering itself through `advance`.
local catchingUp: { [Player]: boolean } = {}

--- The quest a player is currently on, or nil once the chain is finished.
function QuestService.current(player: Player): Quests.Quest?
	local profile = DataService.get(player)
	if not profile then
		return nil
	end
	for _, quest in Quests.list do
		if not profile.questsDone[quest.id] then
			return quest
		end
	end
	return nil
end

function QuestService.progressOf(player: Player, questId: string): number
	local profile = DataService.get(player)
	if not profile then
		return 0
	end
	return profile.questProgress[questId] or 0
end

--- What the client needs to draw the objective list.
function QuestService.snapshot(player: Player): { any }
	local profile = DataService.get(player)
	if not profile then
		return {}
	end

	local out = {}
	for _, quest in Quests.list do
		table.insert(out, {
			id = quest.id,
			text = quest.text,
			target = quest.target,
			progress = math.min(profile.questProgress[quest.id] or 0, quest.target),
			done = profile.questsDone[quest.id] == true,
			reward = quest.reward,
		})
	end
	return out
end

function QuestService.push(player: Player)
	if questRemote then
		questRemote:FireClient(player, QuestService.snapshot(player))
	end
end

--[[
	Advances any active quest matching `kind`.

	Only the quest the player is currently on counts, so a later objective can
	never be completed early by incidental play — the chain is meant to be a
	guided path, not a checklist that fills itself in.
]]
function QuestService.advance(player: Player, kind: Quests.Kind, amount: number, subject: string?)
	local profile = DataService.get(player)
	if not profile or amount <= 0 then
		return
	end

	local quest = QuestService.current(player)
	if not quest or quest.kind ~= kind then
		return
	end
	if quest.subject and quest.subject ~= subject then
		return
	end

	local progress = (profile.questProgress[quest.id] or 0) + amount
	profile.questProgress[quest.id] = progress

	if progress < quest.target then
		QuestService.push(player)
		return
	end

	profile.questsDone[quest.id] = true
	EconomyService.awardRaw(player, quest.reward)
	EconomyService.notify(player, "quest", `Quest complete — {Format.cash(quest.reward)}`, quest.reward)
	QuestService.push(player)

	-- The objective this one hands over to may already be satisfied.
	QuestService.catchUp(player)
end

--[[
	Credits the current objective when the world already satisfies it.

	The chain deliberately only ever advances the quest you are on, so a later
	objective cannot fill itself in from incidental play. A one-shot world
	event breaks that rule from the other side: the garage switch can be
	flipped exactly once, so a player who found it early used to reach "Find
	the switch and open the garage" with the switch already flipped and no way
	to flip it again — and because the chain is a queue, every objective behind
	it stalled for the rest of the run too. Anything already true when you
	arrive at it is credited on arrival instead.
]]
function QuestService.catchUp(player: Player)
	if catchingUp[player] or not WorldService.isLoaded() then
		return
	end
	catchingUp[player] = true

	-- Bounded by the length of the chain: each pass either completes the
	-- current objective and moves on, or stops.
	for _ = 1, #Quests.list do
		local quest = QuestService.current(player)
		if not quest or quest.kind ~= "section" or not quest.subject then
			break
		end
		if not WorldService.isSectionOpen(quest.subject) then
			break
		end
		-- The guard stays set across this call, so the `catchUp` at the end of
		-- `advance` is a no-op and this loop stays the only thing iterating.
		QuestService.advance(player, "section", quest.target, quest.subject)
	end

	catchingUp[player] = nil
end

--------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------

function QuestService.start()
	questRemote = Remotes.event(Remotes.QUESTS)

	DataService.ProfileLoaded:Connect(function(player: Player)
		QuestService.catchUp(player)
		QuestService.push(player)
	end)

	-- Opening the journal is itself an objective, so the client tells us.
	--[[
		The only quest a client reports itself.

		Everything else here is advanced by the server watching what actually
		happened — a tile cut, a bag sold. Opening the journal has no server-side
		trace, so the client says so, and a client saying so can say it a
		thousand times a second. It cannot grant the quest twice (a finished
		quest stops advancing), but it can make the server do the work of
		checking, for nothing, as fast as it likes.

		Half a second between reports. A player opening their journal that often
		is not opening their journal.
	]]
	local lastOpened: { [Player]: number } = {}
	local OPENED_INTERVAL = 0.5

	questRemote.OnServerEvent:Connect(function(player: Player, action: any)
		if action ~= "opened" then
			return
		end
		local now = os.clock()
		if now - (lastOpened[player] or -math.huge) < OPENED_INTERVAL then
			return
		end
		lastOpened[player] = now
		QuestService.advance(player, "journal", 1)
	end)

	--[[
		The opening chain used to read "Collect 5 leaves" and count anything at
		all, in a game whose whole subject is grass. The cut signal has always
		carried what was cut and this handler threw it away, so the first thing
		the game ever asks a player to do could be finished without touching a
		lawn. It names the debris now, and the grass quests ask for grass.
	]]
	TileService.Cut:Connect(function(player: Player, _index: number, debrisId: number, levels: number)
		local subject = if debrisId == DebrisConfig.Grass then "grass" else nil
		QuestService.advance(player, "collect", levels, subject)
	end)

	BagService.Sold:Connect(function(player: Player, units: number)
		QuestService.advance(player, "sell", units)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastOpened[player] = nil
	end)
end

return QuestService
