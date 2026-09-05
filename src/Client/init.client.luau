--!strict
--[[
	Client entry point.

	PlayerState first, because every controller reads from it, then rendering,
	then input and UI.
]]

local PlayerState = require(script.PlayerState)

local Controllers = script.Controllers
local GrassRenderer = require(Controllers.GrassRenderer)
local SoundController = require(Controllers.SoundController)
local GustController = require(Controllers.GustController)
local MissedSpotController = require(Controllers.MissedSpotController)
local MowController = require(Controllers.MowController)
local AffordController = require(Controllers.AffordController)
local ShedController = require(Controllers.ShedController)
local StationController = require(Controllers.StationController)
local TargetController = require(Controllers.TargetController)
local ViewController = require(Controllers.ViewController)
local TrailerController = require(Controllers.TrailerController)
local VehicleController = require(Controllers.VehicleController)

local Hud = require(script.UI.Hud)
local Admin = require(script.UI.Admin)
local RunOnly = require(script.UI.RunOnly)
local RoundBar = require(script.UI.RoundBar)
local Hotbar = require(script.UI.Hotbar)
local Journal = require(script.UI.Journal)
local Store = require(script.UI.Store)
local Intro = require(script.UI.Intro)
local Outro = require(script.UI.Outro)
local LevelSelect = require(script.UI.LevelSelect)

PlayerState.start()
-- Before the screens that register with it, so no phase change is missed.
RunOnly.start()
-- Before anything that might play a cue on its first frame.
SoundController.start()
GrassRenderer.start()
GustController.start()
MowController.start()
MissedSpotController.start()
TargetController.start()
ViewController.start()
ShedController.start()
StationController.start()
VehicleController.start()
TrailerController.start()
Journal.start()
Hotbar.start()
RoundBar.start()
Store.start()
LevelSelect.start()
Intro.start()
Outro.start()
Hud.start()
Admin.start()
AffordController.start()

-- Sections behind a shut gate render desaturated, so the renderer follows the
-- run's open set rather than anything on the player.
PlayerState.SectionsChanged:Connect(function()
	GrassRenderer.setOpenSections(PlayerState.openSections())
end)
