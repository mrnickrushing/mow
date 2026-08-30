--!strict
--[[
	ShedController — opens the shop when the player walks up to the shed, and
	binds a key so they never have to walk back just to check a price.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shop = require(script.Parent.Parent.UI.Shop)

local ShedController = {}

local player = Players.LocalPlayer
local ACTION_NAME = "MowAllTheLawns_Shop"
--- Studs within which the shed counter opens the shop by itself.
local AUTO_OPEN_RADIUS = 16
local wasInRange = false

local function shedPart(): BasePart?
	local world = Workspace:FindFirstChild("MowWorld")
	local shed = world and world:FindFirstChild("Shed")
	local counter = shed and shed:FindFirstChild("ShedCounter")
	if counter and counter:IsA("BasePart") then
		return counter
	end
	return nil
end

local function step()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local counter = shedPart()
	if not root or not root:IsA("BasePart") or not counter then
		wasInRange = false
		return
	end

	local offset = root.Position - counter.Position
	local inRange = offset.X * offset.X + offset.Z * offset.Z <= AUTO_OPEN_RADIUS * AUTO_OPEN_RADIUS

	-- Only act on the transition, so a player who closes the shop while still
	-- standing at the counter is not fighting it reopening every frame.
	if inRange and not wasInRange then
		Shop.setOpen(true)
	elseif not inRange and wasInRange and Shop.isOpen() then
		Shop.setOpen(false)
	end
	wasInRange = inRange
end

function ShedController.start()
	ContextActionService:BindAction(ACTION_NAME, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			Shop.toggle()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.B, Enum.KeyCode.ButtonY)

	RunService.Heartbeat:Connect(step)
end

return ShedController
