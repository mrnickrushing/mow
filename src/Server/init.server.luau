--!strict
--[[
	Server entry point.

	Remotes are created before any service starts so that no service has to wait
	for them, then services start in dependency order, then the first property is
	generated. A client joining mid-boot simply waits on the remote folder.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Worlds = require(Shared.Config.Worlds)
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

-- Last, because it watches the run's phase and puts people in the yard between
-- runs; it needs the run to exist before it can have an opinion about it.
LobbyService.start()

print(`[Mow] server ready on {Worlds.expect(Worlds.STARTER_ID).name}`)
