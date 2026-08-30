--!strict
--[[
	VehicleController — mounting and dismounting a rideable mower.

	One key toggles it, and equipping a vehicle tool tells the player how to get
	on it, because a mower you cannot find the seat for is worse than no mower.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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

--- The seat the local player is riding, if it is a vehicle seat.
local function ridingSeat(): VehicleSeat?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if seat and seat:IsA("VehicleSeat") then
		return seat
	end
	return nil
end

--[[
	Turns the seat's throttle into actual movement.

	A `VehicleSeat` only drives parts joined to it through a motor, and these
	mowers are welded to it — so the seat gathered the rider's input into
	`Throttle` and `Steer` and nothing whatsoever consumed it. Every rideable
	mower in the game sat dead still, which made the three most expensive tools
	on the ladder props you could sit on, and a bought one strictly worse than
	bare hands: an equipped vehicle you are not riding cuts nothing at all.

	Driving the assembly directly is the smallest fix that keeps the arcade
	feel the deck widths are designed around. The seat is network-owned by
	whoever is sitting on it, so this runs on their own client and the mower
	still collides with fences, walls and the house like any other object.
]]
local function drive()
	local seat = ridingSeat()
	if not seat then
		return
	end

	local look = seat.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		return
	end

	-- Vertical velocity is left alone, so gravity, kerbs and the drop off the
	-- end of a rooftop all still behave.
	local current = seat.AssemblyLinearVelocity
	local wanted = flat.Unit * (seat.ThrottleFloat * seat.MaxSpeed)
	seat.AssemblyLinearVelocity = Vector3.new(wanted.X, current.Y, wanted.Z)

	-- Steer is +1 to the right, and a right turn is clockwise seen from above.
	seat.AssemblyAngularVelocity = Vector3.new(0, -seat.SteerFloat * seat.TurnSpeed, 0)

	--[[
		Keep it level.

		Zeroing the angular velocity stops a mower spinning but does nothing
		about one that has already been knocked over, and a mower on its back
		reads its throttle perfectly while going nowhere. A lawn machine on a
		lawn has no business being at an angle, so past a few degrees of tilt
		its heading is kept and the rest is put back upright.
	]]
	local up = seat.CFrame.UpVector
	if up:Dot(Vector3.yAxis) < 0.985 then
		seat.CFrame = CFrame.lookAt(seat.CFrame.Position, seat.CFrame.Position + flat.Unit)
	end
end

function VehicleController.start()
	remote = Remotes.event(Remotes.VEHICLE)

	RunService.Heartbeat:Connect(drive)

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
