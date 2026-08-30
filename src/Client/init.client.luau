--!strict
--[[
	Client entry point.

	PlayerState first, because every controller reads from it, then rendering,
	then input and UI.
]]

local PlayerState = require(script.PlayerState)

local Controllers = script.Controllers
local GrassRenderer = require(Controllers.GrassRenderer)
local MissedSpotController = require(Controllers.MissedSpotController)
local MowController = require(Controllers.MowController)
local ShedController = require(Controllers.ShedController)
local TargetController = require(Controllers.TargetController)
local ViewController = require(Controllers.ViewController)
local VehicleController = require(Controllers.VehicleController)
local TrailerController = require(Controllers.TrailerController)

local Hud = require(script.UI.Hud)
local RoundBar = require(script.UI.RoundBar)
local Hotbar = require(script.UI.Hotbar)
local Journal = require(script.UI.Journal)
local Store = require(script.UI.Store)

PlayerState.start()
GrassRenderer.start()
MowController.start()
MissedSpotController.start()
TargetController.start()
ViewController.start()
ShedController.start()
VehicleController.start()
TrailerController.start()
Journal.start()
Hotbar.start()
RoundBar.start()
Store.start()
Hud.start()

-- Sections behind a shut gate render desaturated, so the renderer follows the
-- run's open set rather than anything on the player.
PlayerState.SectionsChanged:Connect(function()
	GrassRenderer.setOpenSections(PlayerState.openSections())
end)
