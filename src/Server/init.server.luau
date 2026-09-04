--!strict
--[[
	Server entry point.

	Remotes are created before any service starts so that no service has to wait
	for them, then services start in dependency order, then the first property is
	generated. A client joining mid-boot simply waits on the remote folder.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)

Remotes.init()

local Services = script.Services
local AtmosphereService = require(Services.AtmosphereService)
local WorldService = require(Services.WorldService)
local DataService = require(Services.DataService)
local RunState = require(Services.RunState)
local ReplicationService = require(Services.ReplicationService)
local EconomyService = require(Services.EconomyService)
local BagService = require(Services.BagService)
local TileService = require(Services.TileService)
local PlayerService = require(Services.PlayerService)
local QuestService = require(Services.QuestService)
local ShopService = require(Services.ShopService)
local TreeService = require(Services.TreeService)
local FuelService = require(Services.FuelService)
local VehicleService = require(Services.VehicleService)
local CollectibleService = require(Services.CollectibleService)
local HazardService = require(Services.HazardService)
local RunService = require(Services.RunService)
local BoostService = require(Services.BoostService)
local MonetizationService = require(Services.MonetizationService)
local AutoCollectService = require(Services.AutoCollectService)
local RewardService = require(Services.RewardService)
local StripeService = require(Services.StripeService)
local SweepService = require(Services.SweepService)
local LobbyService = require(Services.LobbyService)
local MatchmakingService = require(Services.MatchmakingService)
local LeaderboardService = require(Services.LeaderboardService)
local PriceService = require(script.Services.PriceService)
local Trees = require(script.Lib.Trees)
local AdminService = require(Services.AdminService)

-- Order matters: data before anything that reads a profile, replication before
-- anything that marks tiles, and every listener connected before RunService
-- generates the first world at the bottom of this file.
AtmosphereService.start()

-- The haze is sized to the lot, and a run moves between lots of very different
-- sizes, so it is re-applied every time one loads.
WorldService.Loaded:Connect(function(world)
	AtmosphereService.applyWorld(world)
end)
DataService.start()
RunState.start()
EconomyService.start()
ReplicationService.start()
BagService.start()
TileService.start()
PlayerService.start()
QuestService.start()
ShopService.start()
TreeService.start()
FuelService.start()
VehicleService.start()
BoostService.start()
StripeService.start()
SweepService.start()
MonetizationService.start()
RewardService.start()
AutoCollectService.start()

-- These two populate a world when one loads, so they only need to be listening
-- before the first run begins. RunService.start generates that world, which is
-- why nothing loads a map here: doing both would build the whole property twice
-- and throw the first one away.
CollectibleService.start()
HazardService.start()
RunService.start()

--[[
	Three services that every server needs, whichever job it has.

	These sat inside the lobby branch below, and in Studio that is invisible:
	Studio is one server doing both jobs, so everything ran. In production a
	run is a reserved server of its own, and on that server none of the three
	ever started. The leaderboard loop — the only thing that writes a score —
	lived only on the lobby server, where a player's clippings never change
	and where they stand for under a minute before a pad sends them away; the
	ladders had been empty since the day the boards went up, with the owner's
	nine thousand clippings sitting unpublished in his profile. Prices fell
	back to the stale config on every run server, which is where the store is
	actually opened. And the admin's cash command, which only works inside a
	run, ran on the one kind of server that has no runs.

	The read that found it was the ordered store itself, through the Open
	Cloud execution API: zero entries against a profile that said 9,137.
]]
--[[
	The tree meshes, fetched once so no world load waits on them.

	Eight web calls in a thread of its own. Everything that plants a tree
	calls `warm` too and waits if this has not finished, so the order does
	not matter — this just means it usually has.
]]
task.spawn(Trees.warm)

PriceService.start()
LeaderboardService.start()
AdminService.start()

--[[
	One place, two jobs.

	Every team gets a server of its own, and a reserved server is another
	instance of this same place — so the last thing the server does is work out
	which of the two it is. A public server is a lobby and never starts a run
	by itself; a reserved server is a run and never builds a lobby.
]]
if MatchmakingService.isRunServer() then
	MatchmakingService.startRunServer()
else
	RunService.setAutoStart(false)
	MatchmakingService.watchFailures()
	LobbyService.start()
end

print(`[Mow] server ready — {if MatchmakingService.isRunServer() then "a run" else "the lobby"}`)
