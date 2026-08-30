--!strict
--[[
	VehicleService — the rideable mowers.

	Sitting down on a riding mower for the first time is the biggest single jump
	in the game, so the vehicle is a real seated model rather than a speed buff:
	you mount it, it carries you, and the deck under it clears five to eleven
	tiles at a time.

	A player's vehicle is spawned on demand and belongs only to them, which keeps
	the world free of parked mowers nobody is using.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Types = require(Shared.Types)
local Build = require(script.Parent.Parent.Lib.Build)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local FuelService = require(script.Parent.FuelService)
local WorldService = require(script.Parent.WorldService)

local VehicleService = {}

export type Ride = {
	model: Model,
	seat: VehicleSeat,
	toolId: string,
}

local rides: { [Player]: Ride } = {}
local container: Folder? = nil

local COLORS: { [string]: Color3 } = {
	riding_mower = Color3.fromRGB(196, 68, 60),
	zero_turn = Color3.fromRGB(232, 156, 44),
	commercial_deck = Color3.fromRGB(48, 122, 196),
}

local function ensureContainer(): Folder?
	if container and container.Parent then
		return container
	end
	local world = WorldService.container()
	if not world then
		return nil
	end
	container = Build.folder("Vehicles", world)
	return container
end

--- Builds a mower sized to its deck, so a wider deck visibly is wider.
local function buildVehicle(tool: Types.ToolDef, at: CFrame, parent: Instance): (Model, VehicleSeat)
	local stats = assert(tool.vehicle, "not a vehicle")
	local model = Instance.new("Model")
	model.Name = tool.id

	local deckWidth = tool.deck * 4
	local color = COLORS[tool.id] or Color3.fromRGB(180, 180, 180)

	local body = Build.part({
		name = "Body",
		size = Vector3.new(deckWidth * 0.55, 2.4, 8),
		cframe = at * CFrame.new(0, 2.2, 0),
		color = color,
		material = Enum.Material.Metal,
		parent = model,
	})

	Build.part({
		name = "Deck",
		size = Vector3.new(deckWidth, 1.2, 5),
		cframe = at * CFrame.new(0, 0.9, 2.4),
		color = color:Lerp(Color3.new(0, 0, 0), 0.35),
		material = Enum.Material.DiamondPlate,
		canCollide = false,
		parent = model,
	})

	for _, offset in { Vector3.new(-deckWidth * 0.3, 1.2, -2.6), Vector3.new(deckWidth * 0.3, 1.2, -2.6) } do
		Build.part({
			name = "Wheel",
			size = Vector3.new(1.6, 3.2, 3.2),
			cframe = at * CFrame.new(offset),
			color = Color3.fromRGB(32, 32, 34),
			material = Enum.Material.Rubber,
			canCollide = false,
			parent = model,
		})
	end

	local seat = Instance.new("VehicleSeat")
	seat.Name = "Seat"
	seat.Size = Vector3.new(4, 1.2, 4)
	seat.CFrame = at * CFrame.new(0, stats.seatOffset + 2.4, -1)
	seat.Anchored = false
	seat.CanCollide = true
	seat.MaxSpeed = stats.speed
	seat.TurnSpeed = stats.turnSpeed
	seat.Torque = 24
	seat.Color = color:Lerp(Color3.new(0, 0, 0), 0.5)
	seat.Parent = model

	-- Everything hangs off the seat, which is the part the player drives.
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and part ~= seat then
			part.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = seat
			weld.Part1 = part
			weld.Parent = seat
		end
	end

	body.Massless = true
	model.PrimaryPart = seat
	model.Parent = parent
	return model, seat
end

--------------------------------------------------------------------
-- Mount and dismount
--------------------------------------------------------------------

function VehicleService.dismount(player: Player)
	local ride = rides[player]
	if not ride then
		return
	end
	rides[player] = nil
	if ride.model.Parent then
		ride.model:Destroy()
	end
end

--- True when the player is currently sitting on their mower.
function VehicleService.isRiding(player: Player): boolean
	local ride = rides[player]
	if not ride then
		return false
	end
	return ride.seat.Occupant ~= nil
end

function VehicleService.ridingTool(player: Player): Types.ToolDef?
	local ride = rides[player]
	if not ride or ride.seat.Occupant == nil then
		return nil
	end
	return Tools.get(ride.toolId)
end

local function onMount(player: Player)
	local profile = DataService.get(player)
	if not profile then
		return
	end

	local tool = Tools.get(profile.equippedTool)
	if not tool or not tool.vehicle then
		EconomyService.notify(player, "denied", "Equip a riding mower first", nil)
		return
	end
	if not profile.ownedTools[tool.id] then
		return
	end

	if FuelService.remaining(player) <= 0 then
		EconomyService.notify(player, "denied", "Out of fuel — refill at the shed", nil)
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid then
		return
	end

	local parent = ensureContainer()
	if not parent then
		return
	end

	-- Replace any mower they left behind rather than littering the lawn.
	VehicleService.dismount(player)

	local at = CFrame.new(root.Position - Vector3.new(0, 1.5, 0)) * CFrame.Angles(0, math.atan2(-root.CFrame.LookVector.X, -root.CFrame.LookVector.Z), 0)
	local model, seat = buildVehicle(tool, at, parent)
	rides[player] = { model = model, seat = seat, toolId = tool.id }

	seat:Sit(humanoid)

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if seat.Occupant == nil then
			-- Give the character a moment to stand before clearing the mower.
			task.delay(0.4, function()
				local current = rides[player]
				if current and current.seat == seat and seat.Occupant == nil then
					VehicleService.dismount(player)
				end
			end)
		end
	end)
end

local function onVehicleRemote(player: Player, action: any)
	if action == "mount" then
		onMount(player)
	elseif action == "dismount" then
		VehicleService.dismount(player)
	end
end

function VehicleService.start()
	local remote = Remotes.event(Remotes.VEHICLE)
	remote.OnServerEvent:Connect(onVehicleRemote)

	Players.PlayerRemoving:Connect(VehicleService.dismount)

	-- A respawn leaves the old mower orphaned; clear it.
	Players.PlayerAdded:Connect(function(player)
		player.CharacterRemoving:Connect(function()
			VehicleService.dismount(player)
		end)
	end)

	WorldService.Loaded:Connect(function()
		for player in rides do
			VehicleService.dismount(player)
		end
		container = nil
	end)
end

return VehicleService
