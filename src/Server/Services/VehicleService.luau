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
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Types = require(Shared.Types)
local RateLimiter = require(Shared.Util.RateLimiter)
local Build = require(script.Parent.Parent.Lib.Build)
local RunState = require(script.Parent.RunState)
local EconomyService = require(script.Parent.EconomyService)
local FuelService = require(script.Parent.FuelService)
local WorldService = require(script.Parent.WorldService)

local VehicleService = {}

export type Ride = {
	model: Model,
	--- The constraints that actually move the machine. See `drive`.
	push: LinearVelocity,
	turn: AngularVelocity,
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
local function buildVehicle(
	tool: Types.ToolDef,
	at: CFrame,
	parent: Instance
): (Model, VehicleSeat, LinearVelocity, AngularVelocity)
	local stats = assert(tool.vehicle, "not a vehicle")
	local model = Instance.new("Model")
	model.Name = tool.id

	local deckWidth = tool.deck * 4
	local color = COLORS[tool.id] or Color3.fromRGB(180, 180, 180)

	--[[
		One mower mesh, on a collision box the size of the machine.

		The mower used to be a coloured slab, a thinner slab for the deck and
		two flat rectangles for wheels. The model carries all of that, and its
		width still follows the tool's deck so the expensive decks visibly are
		wider — which is the stat the whole ladder is sold on.
	]]
	local body = Build.mesh({
		prop = "RidingMower",
		name = "Body",
		size = Vector3.new(math.max(deckWidth, 6), 6, 10),
		collisionSize = Vector3.new(math.max(deckWidth * 0.6, 4), 2.6, 8),
		cframe = at * CFrame.new(0, 2.2, 0),
		color = color,
		parent = model,
	})

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
	-- The mesh draws its own seat, so this one is only somewhere to sit.
	seat.Transparency = 1
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

	--[[
		What actually moves the mower.

		Setting `AssemblyLinearVelocity` every frame does not: measured on a
		seated mower it moved it nought studs in two and a half seconds, because
		the seated character is part of the same assembly and the solver puts
		back what you write. A velocity *constraint* is the supported way to
		push an assembly around and it moves the same mower fifty-four studs in
		the same time.

		The vertical component is refreshed from the assembly each frame rather
		than held at zero, so the machine still falls off things.
	]]
	local mount = Instance.new("Attachment")
	mount.Name = "Drive"
	mount.Parent = seat

	local push = Instance.new("LinearVelocity")
	push.Name = "Push"
	push.Attachment0 = mount
	push.RelativeTo = Enum.ActuatorRelativeTo.World
	push.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	push.MaxForce = 1e6
	push.VectorVelocity = Vector3.zero
	-- Off until there is throttle; see `drive`.
	push.Enabled = false
	push.Parent = seat

	local turn = Instance.new("AngularVelocity")
	turn.Name = "Turn"
	turn.Attachment0 = mount
	turn.RelativeTo = Enum.ActuatorRelativeTo.World
	turn.MaxTorque = 1e6
	turn.AngularVelocity = Vector3.zero
	turn.Enabled = false
	turn.Parent = seat

	-- The body keeps its mass on purpose. It is the wide, low box; the seat is
	-- a small one perched above it. Making the body weightless left the whole
	-- machine balanced on the seat like an inverted pendulum, and the first
	-- push of throttle rolled it onto its back.
	model.PrimaryPart = seat
	model.Parent = parent
	return model, seat, push, turn
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
	local run = RunState.find(player)
	if not run then
		return
	end

	local tool = Tools.get(run.equippedTool)
	if not tool or not tool.vehicle then
		EconomyService.notify(player, "denied", "Equip a riding mower first", nil)
		return
	end
	if not run.ownedTools[tool.id] then
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
	local model, seat, push, turn = buildVehicle(tool, at, parent)
	rides[player] = { model = model, seat = seat, toolId = tool.id, push = push, turn = turn }

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

--[[
	Mounting builds a vehicle, so it is worth rate limiting.

	Every other remote the client can reach is behind a limiter; this one was
	not, and it is the most expensive of them per call — each mount constructs
	a mower model, seats the player and destroys the one before it. A client
	calling it in a loop would have the server building and tearing down models
	as fast as it could, for everyone on it, and a public server holds fifty
	people. Four a second is more than a person can press.
]]
local MOUNT_HZ = 4
local mountLimiters: { [Player]: RateLimiter.RateLimiter } = {}

local function mountLimiterFor(player: Player): RateLimiter.RateLimiter
	local limiter = mountLimiters[player]
	if not limiter then
		limiter = RateLimiter.new(MOUNT_HZ, MOUNT_HZ)
		mountLimiters[player] = limiter
	end
	return limiter
end

local function onVehicleRemote(player: Player, action: any)
	if not mountLimiterFor(player):tryConsume() then
		return
	end
	if action == "mount" then
		onMount(player)
	elseif action == "dismount" then
		VehicleService.dismount(player)
	end
end

--[[
	Drives the mowers, because a `VehicleSeat` on its own will not.

	A VehicleSeat turns throttle and steer into motion through the *motors* of
	the wheels attached to it. These mowers have no wheels: the model is one
	mesh welded to the seat, which is what keeps them cheap and stops them
	folding up on a kerb. So the seat's `MaxSpeed`, `TurnSpeed` and `Torque`
	were set, read by nothing, and the machine sat still — full throttle for
	three seconds moved the riding mower one stud, which is drift, not driving.
	The most expensive upgrade in the game did not work.

	So the assembly is driven by hand. Velocity is set rather than accumulated,
	which is what makes an arcade mower feel like one: it goes when you hold the
	stick and stops when you let go, with no skidding and nothing to fight on a
	slope. The vertical component is left alone so gravity still applies and a
	mower driven off the pool deck still falls into it.
]]
local function drive()
	for player, ride in rides do
		local seat = ride.seat
		if not seat.Parent or seat.Occupant == nil then
			continue
		end

		local tool = Tools.get(ride.toolId)
		local stats = tool and tool.vehicle
		if not stats then
			continue
		end

		--[[
			The constraints are switched off unless there is throttle.

			This matters more than it looks. A velocity constraint holds the
			velocity you give it, so one left enabled at zero does not merely
			fail to drive the mower — it pins it, and a parked machine could not
			then be shoved, knocked or nudged by anything. Off when idle, the
			assembly behaves exactly as it did before any of this existed, which
			is the behaviour to fall back to if the throttle never arrives.
		]]
		local throttle = seat.Throttle
		local driving = math.abs(throttle) > 0.05
		ride.push.Enabled = driving
		ride.turn.Enabled = driving
		if not driving then
			continue
		end

		local heading = seat.CFrame.LookVector
		local wanted = heading * (throttle * stats.speed)
		-- Kept from the assembly rather than zeroed, so gravity still reads
		-- through and a mower driven off the pool deck falls into it.
		local falling = seat.AssemblyLinearVelocity.Y
		ride.push.VectorVelocity = Vector3.new(wanted.X, falling, wanted.Z)

		-- Turning only bites while the machine is being driven, so a parked
		-- mower cannot be spun on the spot like a fairground ride.
		ride.turn.AngularVelocity = Vector3.new(0, -seat.Steer * stats.turnSpeed, 0)
	end
end

function VehicleService.start()
	local remote = Remotes.event(Remotes.VEHICLE)
	remote.OnServerEvent:Connect(onVehicleRemote)

	RunService.Heartbeat:Connect(drive)

	Players.PlayerRemoving:Connect(function(player: Player)
		mountLimiters[player] = nil
		VehicleService.dismount(player)
	end)

	--[[
		A respawn leaves the old mower orphaned; clear it.

		Hooked for players already here as well as ones who arrive later. Every
		other service that watches a character does both — PlayerService walks
		`GetPlayers()` before connecting `PlayerAdded` — and this one only
		connected the event, so anybody who got in before the service started
		would litter a mower on the lawn every time they respawned.
	]]
	local function watchRespawn(player: Player)
		player.CharacterRemoving:Connect(function()
			VehicleService.dismount(player)
		end)
	end

	for _, player in Players:GetPlayers() do
		watchRespawn(player)
	end
	Players.PlayerAdded:Connect(watchRespawn)

	WorldService.Loaded:Connect(function()
		for player in rides do
			VehicleService.dismount(player)
		end
		container = nil
	end)
end

return VehicleService
