--!strict
--[[
	VehicleController — mounting and dismounting a rideable mower.

	One key toggles it, and equipping a vehicle tool tells the player how to get
	on it, because a mower you cannot find the seat for is worse than no mower.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local PlayerState = require(script.Parent.Parent.PlayerState)

local VehicleController = {}

local player = Players.LocalPlayer
local remote: RemoteEvent
local ACTION_NAME = "MowAllTheLawns_Vehicle"

local function seated(): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.SeatPart ~= nil
end

--- True when the equipped tool is one you ride rather than carry.
function VehicleController.hasVehicleEquipped(): boolean
	local tool = Tools.get(PlayerState.get().equippedTool)
	return tool ~= nil and tool.vehicle ~= nil
end

function VehicleController.start()
	remote = Remotes.event(Remotes.VEHICLE)

	ContextActionService:BindAction(ACTION_NAME, function(_, inputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if seated() then
			remote:FireServer("dismount")
		elseif VehicleController.hasVehicleEquipped() then
			remote:FireServer("mount")
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.F, Enum.KeyCode.ButtonX)
end

return VehicleController
