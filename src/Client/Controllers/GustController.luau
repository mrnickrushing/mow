--!strict
--[[
	GustController — leaves thrown by a blower.

	A blower that made leaves vanish from the ground would read as a delete key.
	The whole appeal of the tool is watching a drift come apart and tumble away
	down the garden, so every tile a blower clears throws a handful of leaves
	into the air along the blast.

	These are cosmetic only. The tile they came from is already gone as far as
	the server is concerned, so nothing here can be exploited and nothing here
	has to be replicated — each client throws its own leaves and they can differ
	without anyone noticing.

	Anchored parts stepped by hand rather than unanchored ones dropped into the
	physics engine: a hundred loose parts on a phone is a frame-rate problem, and
	leaves are light enough that nobody can tell the difference.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared.Config.Palette)

local GustController = {}

type Flyer = {
	part: Part,
	velocity: Vector3,
	spin: Vector3,
	age: number,
	life: number,
	--- The height it will settle at, so a leaf blown off a roof does not sink
	--- through the lawn below it.
	floor: number,
}

local flyers: { Flyer } = {}
local pool: { Part } = {}
local container: Folder? = nil

--- Beyond this many in the air at once the effect stops reading as leaves and
--- starts reading as confetti, and costs a frame besides.
local MAX_FLYERS = 90
local GRAVITY = 42
--- Air resistance. High, because a leaf is mostly surface: it should lose the
--- blast almost at once and then flutter down rather than sail like a stone.
local DRAG = 2.1

local function ensureContainer(): Folder
	local existing = container
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "MowGusts"
	folder.Parent = Workspace
	container = folder
	return folder
end

local function acquire(): Part
	local recycled = table.remove(pool)
	if recycled then
		return recycled
	end

	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Size = Vector3.new(2.6, 0.32, 1.9)

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Name = "Blade"
	mesh.Parent = part

	return part
end

local function release(flyer: Flyer)
	flyer.part.Parent = nil
	flyer.part.Transparency = 0
	table.insert(pool, flyer.part)
end

--[[
	Throws `count` leaves from a point, along a direction.

	The spread is deliberately wide and the upward component generous: a blower
	held at waist height pointing at the ground should send leaves up and over,
	not skidding along the floor like a broom.
]]
function GustController.blow(origin: Vector3, direction: Vector3, count: number, strength: number, tint: Color3?)
	local folder = ensureContainer()
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, 1)
	else
		flat = flat.Unit
	end
	local side = Vector3.new(-flat.Z, 0, flat.X)

	for _ = 1, count do
		if #flyers >= MAX_FLYERS then
			return
		end

		local part = acquire()
		local palette = Palette.leaves
		part.Color = tint or Palette.color(palette[math.random(1, #palette)])
		part.Transparency = 0
		part.CFrame = CFrame.new(origin + Vector3.new(0, 0.3, 0))
			* CFrame.Angles(math.random() * 6.28, math.random() * 6.28, math.random() * 6.28)
		part.Parent = folder

		local spread = (math.random() - 0.5) * 0.9
		local velocity = flat * (strength * (0.6 + math.random() * 0.7))
			+ side * (spread * strength * 0.4)
			+ Vector3.new(0, strength * (0.35 + math.random() * 0.4), 0)

		table.insert(flyers, {
			part = part,
			velocity = velocity,
			spin = Vector3.new(
				(math.random() - 0.5) * 14,
				(math.random() - 0.5) * 14,
				(math.random() - 0.5) * 14
			),
			age = 0,
			life = 0.9 + math.random() * 0.6,
			floor = origin.Y,
		})
	end
end

local function step(delta: number)
	local dt = math.min(delta, 1 / 30)

	for i = #flyers, 1, -1 do
		local flyer = flyers[i]
		flyer.age += dt

		if flyer.age >= flyer.life then
			release(flyer)
			table.remove(flyers, i)
			continue
		end

		-- Drag first, then gravity, so a leaf sheds the blast quickly and then
		-- falls at its own pace instead of arcing like a thrown ball.
		flyer.velocity -= flyer.velocity * DRAG * dt
		flyer.velocity -= Vector3.new(0, GRAVITY * dt, 0)

		local part = flyer.part
		local position = part.Position + flyer.velocity * dt
		local settled = position.Y <= flyer.floor + 0.2

		if settled then
			position = Vector3.new(position.X, flyer.floor + 0.18, position.Z)
			flyer.velocity = Vector3.new(flyer.velocity.X * 0.2, 0, flyer.velocity.Z * 0.2)
			flyer.spin = Vector3.zero
		end

		part.CFrame = CFrame.new(position)
			* (part.CFrame - part.CFrame.Position)
			* CFrame.Angles(flyer.spin.X * dt, flyer.spin.Y * dt, flyer.spin.Z * dt)

		-- Fade only over the last third, so most of a leaf's flight is at full
		-- colour and the disappearance is not what the eye follows.
		local remaining = 1 - flyer.age / flyer.life
		part.Transparency = if remaining < 0.34 then 1 - remaining / 0.34 else 0
	end
end

--- How hard a tool throws what it clears, or nil for tools that do not throw.
function GustController.strengthFor(category: string): number?
	if category == "Blower" then
		return 46
	elseif category == "Mower" then
		-- A mower spits clippings out of the side rather than blasting them, so
		-- it gets a fraction of the throw and no lift to speak of.
		return 14
	end
	return nil
end

function GustController.start()
	RunService.Heartbeat:Connect(step)
end

return GustController
