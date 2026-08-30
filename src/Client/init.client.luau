--!strict
--[[
	Client entry point.

	PlayerState first, because every controller reads from it, then rendering,
	then input and UI.
]]

local PlayerState = require(script.PlayerState)

local Controllers = script.Controllers
local GrassRenderer = require(Controllers.GrassRenderer)
local MowController = require(Controllers.MowController)
local ShedController = require(Controllers.ShedController)
local VehicleController = require(Controllers.VehicleController)
local TrailerController = require(Controllers.TrailerController)

local Hud = require(script.UI.Hud)
local RoundBar = require(script.UI.RoundBar)
local Shop = require(script.UI.Shop)
local Store = require(script.UI.Store)

PlayerState.start()
GrassRenderer.start()
MowController.start()
ShedController.start()
VehicleController.start()
TrailerController.start()
Shop.start()
RoundBar.start()
Store.start()
Hud.start()

-- Locked zones render desaturated, so the renderer needs to know what the
-- player owns whenever that changes.
PlayerState.Changed:Connect(function()
	GrassRenderer.setUnlockedZones(PlayerState.get().unlockedZones)
end)

GrassRenderer.setUnlockedZones(PlayerState.get().unlockedZones)
