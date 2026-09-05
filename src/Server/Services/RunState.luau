--!strict
--[[
	RunState — everything a player owns for the length of one run.

	Cash, tools, upgrade levels and the bag all live here and nowhere else. They
	are created when a run starts and thrown away when it ends, which is what
	makes each world a race from nothing rather than a save file you top up.

	Nothing here is ever written to a datastore. The saved profile keeps only
	what should outlive a run — best times, totals, which worlds are beaten —
	so a disconnect mid-run can never bank progress, and a run can never be
	duplicated by rejoining.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Tools = require(Shared.Config.Tools)
local Upgrades = require(Shared.Config.Upgrades)
local DataService = require(script.Parent.DataService)

local RunState = {}

export type State = {
	cash: number,
	--- Cash earned across the whole run, for the end screen.
	earned: number,
	ownedTools: { [string]: boolean },
	equippedTool: string,
	upgrades: { [string]: number },
	fuel: number,
	--- Debris units cleared, for the contribution split and the scoreboard.
	contribution: number,
	unitsSold: number,
}

local states: { [Player]: State } = {}

--[[
	A fresh loadout: the starter tool, no money, nothing bought.

	The one exception is a tool bought outright with Robux, which is handed back
	at the start of every run — that is what "permanent" was sold as, and a
	permanent unlock that had to be re-earned each run would be a rental with a
	misleading label.
]]
function RunState.fresh(player: Player?): State
	local upgrades: { [string]: number } = {}
	for _, def in Upgrades.list do
		upgrades[def.id] = 0
	end

	local owned: { [string]: boolean } = { [Tools.STARTER_ID] = true }
	local profile = if player then DataService.get(player) else nil
	if profile then
		for toolId, bought in profile.permanentTools do
			if bought and Tools.get(toolId) then
				owned[toolId] = true
			end
		end
	end

	return {
		cash = GameConfig.STARTING_CASH,
		earned = 0,
		ownedTools = owned,
		equippedTool = Tools.STARTER_ID,
		upgrades = upgrades,
		fuel = GameConfig.BASE_FUEL,
		contribution = 0,
		unitsSold = 0,
	}
end

--[[
	Run-only tools bought while no run was under way, waiting for the next one.

	The store is open in the lobby, and a tool bought there "for this run" had no
	run to be bought for. `beginRun` calls `resetAll`, which rebuilds every
	loadout from `permanentTools` alone, so the grant was written to a state that
	was about to be thrown away — the player paid Robux, was told the tool was
	unlocked, and started the run without it. Nothing said so.

	Rentals already had this problem and already solved it, in `carryRentals`;
	this is the same fix for the other thing you can buy that outlives a reset.
	Held tools are applied to the fresh loadout the moment a run begins and then
	forgotten, so "this run" means the next run rather than every run.
]]
local held: { [Player]: { [string]: boolean } } = {}

--- Remembers a run-only tool until a run exists to put it in.
function RunState.holdTool(player: Player, toolId: string)
	local mine = held[player]
	if not mine then
		mine = {}
		held[player] = mine
	end
	mine[toolId] = true
end

--- Whether anything is waiting for this player, so the caller can say so.
function RunState.hasHeldTools(player: Player): boolean
	return held[player] ~= nil
end

--[[
	Hands the held tools to the loadouts a round rotation has just rebuilt.

	Called after `resetAll`, beside `carryRentals`, for the same reason.
]]
function RunState.applyHeldTools()
	for player, tools in held do
		local state = states[player]
		if state then
			local bestId: string? = nil
			local bestTier = -math.huge
			for toolId in tools do
				state.ownedTools[toolId] = true
				local tool = Tools.get(toolId)
				if tool and tool.tier > bestTier then
					bestTier = tool.tier
					bestId = toolId
				end
			end
			-- Equipped, because a tool you paid for and cannot find is the
			-- complaint this whole thing exists to answer.
			if bestId then
				state.equippedTool = bestId
			end
		end
	end
	table.clear(held)
end

--- The player's run state, creating one if the run has already started.
function RunState.get(player: Player): State
	local state = states[player]
	if not state then
		state = RunState.fresh(player)
		states[player] = state
	end
	return state
end

function RunState.find(player: Player): State?
	return states[player]
end

--- Wipes everyone back to a fresh loadout. Called when a run begins.
function RunState.resetAll()
	table.clear(states)
	for _, player in Players:GetPlayers() do
		states[player] = RunState.fresh(player)
	end
end

function RunState.reset(player: Player)
	states[player] = RunState.fresh(player)
end

function RunState.all(): { [Player]: State }
	return states
end

--[[
	Hands back tools bought outright, once the profile saying so has arrived.

	A run state is built the moment a player joins, and a profile takes a
	round trip to a datastore to appear — so a player quick enough to join and
	stand on a pad before their save lands was handed a loadout built from no
	profile at all, which is a loadout with none of the tools they paid Robux
	for. They would have bought a permanent unlock and spent the run with bare
	hands.

	Nothing else in the state is touched: cash, upgrades and progress within
	the run stay exactly as they were. This only adds back what was already
	owned.
]]
local function grantPermanentTools(player: Player)
	local state = states[player]
	local profile = DataService.get(player)
	if not state or not profile then
		return
	end
	for toolId, bought in profile.permanentTools do
		if bought and Tools.get(toolId) then
			state.ownedTools[toolId] = true
		end
	end
end

function RunState.start()
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
		held[player] = nil
	end)

	-- Someone arriving mid-run starts from nothing like everyone else did.
	Players.PlayerAdded:Connect(function(player)
		states[player] = RunState.fresh(player)
	end)

	-- The profile lands after the state is built, so it is applied when it does.
	DataService.ProfileLoaded:Connect(grantPermanentTools)
end

return RunState
