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
local TrailerController = require(Controllers.TrailerController)

local Hud = require(script.UI.Hud)

PlayerState.start()
GrassRenderer.start()
MowController.start()
TrailerController.start()
Hud.start()

-- Locked zones render desaturated, so the renderer needs to know what the
-- player owns whenever that changes.
PlayerState.Changed:Connect(function()
	GrassRenderer.setUnlockedZones(PlayerState.get().unlockedZones)
end)

GrassRenderer.setUnlockedZones(PlayerState.get().unlockedZones)
