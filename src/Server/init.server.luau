--!strict
--[[
	Server entry point.

	Remotes are created before any service starts so that no service has to wait
	for them, then services start in dependency order, then the first property is
	generated. A client joining mid-boot simply waits on the remote folder.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Properties = require(Shared.Config.Properties)
local Remotes = require(Shared.Remotes)

Remotes.init()

local Services = script.Services
local AtmosphereService = require(Services.AtmosphereService)
local DataService = require(Services.DataService)
local WorldService = require(Services.WorldService)
local ReplicationService = require(Services.ReplicationService)
local EconomyService = require(Services.EconomyService)
local BagService = require(Services.BagService)
local TileService = require(Services.TileService)
local PlayerService = require(Services.PlayerService)
local ShopService = require(Services.ShopService)
local TreeService = require(Services.TreeService)
local ZoneGateService = require(Services.ZoneGateService)
local FuelService = require(Services.FuelService)
local VehicleService = require(Services.VehicleService)
local CollectibleService = require(Services.CollectibleService)
local HazardService = require(Services.HazardService)
local RoundService = require(Services.RoundService)
local BoostService = require(Services.BoostService)
local MonetizationService = require(Services.MonetizationService)
local AutoCollectService = require(Services.AutoCollectService)
local RewardService = require(Services.RewardService)
local StripeService = require(Services.StripeService)
local SweepService = require(Services.SweepService)

-- Order matters: data before anything that reads a profile, world before
-- anything that reads the grid, replication before anything that marks tiles.
AtmosphereService.start()
DataService.start()
EconomyService.start()
ReplicationService.start()
BagService.start()
TileService.start()
PlayerService.start()
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

WorldService.load(Properties.STARTER_ID)
ReplicationService.broadcastWorldInfo()

-- Started after the first world exists so their generators have something to
-- populate; each also re-runs on every rotation.
CollectibleService.start()
HazardService.start()
ZoneGateService.start()
RoundService.start()

print(`[Mow] server ready on {Properties.expect(Properties.STARTER_ID).name}`)
