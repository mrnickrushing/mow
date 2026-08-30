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
local DataService = require(Services.DataService)
local WorldService = require(Services.WorldService)
local ReplicationService = require(Services.ReplicationService)
local EconomyService = require(Services.EconomyService)
local BagService = require(Services.BagService)
local TileService = require(Services.TileService)
local PlayerService = require(Services.PlayerService)
local ShopService = require(Services.ShopService)
local TreeService = require(Services.TreeService)

-- Order matters: data before anything that reads a profile, world before
-- anything that reads the grid, replication before anything that marks tiles.
DataService.start()
EconomyService.start()
ReplicationService.start()
BagService.start()
TileService.start()
PlayerService.start()
ShopService.start()
TreeService.start()

WorldService.load(Properties.STARTER_ID)
ReplicationService.broadcastWorldInfo()

print(`[Mow] server ready on {Properties.expect(Properties.STARTER_ID).name}`)
