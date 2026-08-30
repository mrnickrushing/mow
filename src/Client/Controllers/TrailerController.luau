--!strict
--[[
	TrailerController — sells the bag the moment the player reaches the trailer.

	No prompt, no hold, no animation lock. The reference game funnels every
	player through a single vent with a 1.5 second lock, which queues badly on a
	busy server; here walking into range is the whole interaction, and the server
	still validates the distance itself.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local PlayerState = require(script.Parent.Parent.PlayerState)

local TrailerController = {}

local player = Players.LocalPlayer
local dumpRemote: RemoteEvent
local lastAttempt = 0

--- Never ask to sell more than this often, even while standing in range.
local ATTEMPT_INTERVAL = 0.35

local function trailerPart(): BasePart?
	local world = Workspace:FindFirstChild("MowWorld")
	local trailer = world and world:FindFirstChild("Trailer")
	local bed = trailer and trailer:FindFirstChild("TrailerBed")
	if bed and bed:IsA("BasePart") then
		return bed
	end
	return nil
end

local function step()
	local state = PlayerState.get()
	if state.bagWeight <= 0 then
		return
	end

	local now = os.clock()
	if now - lastAttempt < ATTEMPT_INTERVAL then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local bed = trailerPart()
	if not root or not root:IsA("BasePart") or not bed then
		return
	end

	local offset = root.Position - bed.Position
	local radius = state.dumpRadius
	if offset.X * offset.X + offset.Z * offset.Z <= radius * radius then
		lastAttempt = now
		dumpRemote:FireServer()
	end
end

function TrailerController.start()
	dumpRemote = Remotes.event(Remotes.DUMP)
	RunService.Heartbeat:Connect(step)
end

return TrailerController
