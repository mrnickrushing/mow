--!strict
--[[
	HazardService — sprinklers, wasps and the neighbour's dog.

	These exist to break the rhythm rather than to punish. Grinding one enormous
	lawn is hypnotic for about ten minutes and dull after twenty; something that
	occasionally goes wrong is what keeps a player present.

	Every hazard is opt-in per section through the `hazards` list in Worlds.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkCodec = require(Shared.ChunkCodec)
local Format = require(Shared.Util.Format)
local Grid = require(Shared.Grid)
local Sprites = require(Shared.Config.Sprites)
local Types = require(Shared.Types)
local BagService = require(script.Parent.BagService)
local Build = require(script.Parent.Parent.Lib.Build)
local Structures = require(script.Parent.Parent.Lib.Structures)
local EconomyService = require(script.Parent.EconomyService)
local ReplicationService = require(script.Parent.ReplicationService)
local WorldService = require(script.Parent.WorldService)
local PlayerService = require(script.Parent.PlayerService)

local HazardService = {}

--- Seconds between sprinkler cycles.
local SPRINKLER_PERIOD = 42
--- Tiles a sprinkler wets, as a radius.
local SPRINKLER_RADIUS = 7
--- Seconds a wasp sting slows the player.
local STING_SECONDS = 3

--- Players still shaking off a sting, mapped to when it wears off.
local stung: { [Player]: number } = {}
--- Fraction of the bag the dog makes off with.
local DOG_THEFT = 0.15

local container: Folder? = nil
local rng = Random.new()
local running = false

--------------------------------------------------------------------
-- Sprinklers
--------------------------------------------------------------------

--- Wets a disc of tiles, which halves cut rate and stalls the early tools.
local function wetArea(centreTx: number, centreTz: number, radius: number, wet: boolean)
	local grid = WorldService.grid
	local tiles = WorldService.tiles
	if not grid or not tiles then
		return
	end

	for tz = centreTz - radius, centreTz + radius do
		for tx = centreTx - radius, centreTx + radius do
			local dx, dz = tx - centreTx, tz - centreTz
			if dx * dx + dz * dz <= radius * radius and Grid.inBounds(grid, tx, tz) then
				local index = Grid.toIndex(grid, tx, tz)
				local byte = buffer.readu8(tiles, index - 1)
				local updated = ChunkCodec.withWet(byte, wet)
				if updated ~= byte then
					buffer.writeu8(tiles, index - 1, updated)
					ReplicationService.markTileDirty(index)
				end
			end
		end
	end
end

local function makeSprinkler(tx: number, tz: number, parent: Instance)
	local at = WorldService.tilePointToWorld(tx, tz)
	local head = Build.mesh({
		prop = "Sprinkler",
		name = "Sprinkler",
		size = Vector3.new(2.2, 2.2, 2.2),
		collisionSize = Vector3.new(1.2, 1.6, 1.2),
		cframe = CFrame.new(at + Vector3.new(0, 1.1, 0)),
		canCollide = false,
		parent = parent,
	})

	local spray = Instance.new("ParticleEmitter")
	spray.Enabled = false
	-- Drawn for this game rather than Roblox's default particle, which is the
	-- same soft blob every other place on the platform sprays. See `Sprites`.
	local droplet = Sprites.get("WaterDroplet")
	if droplet then
		spray.Texture = droplet.id
	end
	spray.Rate = 90
	spray.Lifetime = NumberRange.new(0.8, 1.4)
	spray.Speed = NumberRange.new(18, 26)
	spray.SpreadAngle = Vector2.new(70, 70)
	spray.Color = ColorSequence.new(Color3.fromRGB(180, 214, 236))
	spray.Size = NumberSequence.new(0.35)
	spray.Transparency = NumberSequence.new(0.35)
	spray.Parent = head

	-- Held on the head and switched with the water, so it fades with distance
	-- and a lawn full of sprinklers does not drown the property.
	local hiss = Build.sound(head, "Sprinkler", false)

	task.spawn(function()
		-- Stagger, so a world full of sprinklers does not fire in unison.
		task.wait(rng:NextNumber(0, SPRINKLER_PERIOD))
		while running and head.Parent do
			spray.Enabled = true
			if hiss then
				hiss:Play()
			end
			wetArea(tx, tz, SPRINKLER_RADIUS, true)
			task.wait(12)

			spray.Enabled = false
			if hiss then
				hiss:Stop()
			end
			-- The ground stays wet for a while after the water stops, which is
			-- what actually forces a detour rather than a twelve-second pause.
			task.wait(16)
			wetArea(tx, tz, SPRINKLER_RADIUS, false)

			task.wait(SPRINKLER_PERIOD)
		end
	end)
end

--------------------------------------------------------------------
-- Wasps
--------------------------------------------------------------------

local function makeWaspNest(tx: number, tz: number, parent: Instance)
	local at = WorldService.tilePointToWorld(tx, tz)
	local nest = Build.mesh({
		prop = "WaspNest",
		name = "WaspNest",
		size = Vector3.new(3, 3.9, 3),
		collisionSize = Vector3.new(3, 3.6, 3),
		cframe = CFrame.new(at + Vector3.new(0, 9, 0)),
		canCollide = false,
		parent = parent,
	})

	local prompt = Build.prompt(nest, "Knock down", "Wasp Nest", 12)
	prompt.HoldDuration = 1.2
	prompt.Triggered:Connect(function(player: Player)
		if not nest.Parent then
			return
		end
		nest:Destroy()

		-- The sting is a modifier rather than a value written straight onto the
		-- humanoid. Writing it directly meant anything that recomputed walk
		-- speed while you were stung — buying a Stride level was the easy one —
		-- cancelled the penalty, and worse, the delayed restore then put back a
		-- speed from before the upgrade and left it wrong for the rest of the
		-- run.
		stung[player] = os.clock() + STING_SECONDS
		PlayerService.applyCharacterStats(player)
		EconomyService.notify(player, "stall", "Stung! Shake it off", nil)
		task.delay(STING_SECONDS, function()
			local until_ = stung[player]
			if until_ and os.clock() >= until_ - 0.05 then
				stung[player] = nil
				if player.Parent then
					PlayerService.applyCharacterStats(player)
				end
			end
		end)

		-- Worth doing anyway: a cleared nest pays a tip.
		EconomyService.awardTips(player, 1)
	end)
end

--------------------------------------------------------------------
-- The dog
--------------------------------------------------------------------

local function makeDog(tx: number, tz: number, parent: Instance)
	local at = WorldService.tilePointToWorld(tx, tz)
	local dog = Build.mesh({
		prop = "Dog",
		name = "Dog",
		size = Vector3.new(2.4, 3.4, 4.5),
		collisionSize = Vector3.new(2.4, 2.4, 4.5),
		cframe = CFrame.new(at + Vector3.new(0, 1.7, 0)),
		canCollide = false,
		parent = parent,
	})

	local home = dog.Position

	task.spawn(function()
		while running and dog.Parent do
			task.wait(rng:NextNumber(18, 34))

			-- Find someone carrying enough to be worth stealing.
			local target: Player? = nil
			for _, player in Players:GetPlayers() do
				if BagService.weight(player) > 40 then
					local character = player.Character
					local root = character and character:FindFirstChild("HumanoidRootPart")
					if root and root:IsA("BasePart") and (root.Position - home).Magnitude < 220 then
						target = player
						break
					end
				end
			end

			if target then
				local character = target.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") and dog.Parent then
					local run = TweenService:Create(dog, TweenInfo.new(1.6, Enum.EasingStyle.Sine), {
						CFrame = CFrame.new(root.Position - Vector3.new(0, 1.5, 0)),
					})
					run:Play()
					run.Completed:Wait()

					local bag = BagService.get(target)
					local stolen = 0
					for debrisId, units in bag.units do
						local take = units * DOG_THEFT
						bag.units[debrisId] = units - take
						stolen += take
					end
					bag.weight *= 1 - DOG_THEFT

					if stolen > 0 then
						EconomyService.notify(
							target,
							"stall",
							`The dog got away with {Format.count(stolen)} of your load`,
							nil
						)
					end

					if dog.Parent then
						TweenService:Create(dog, TweenInfo.new(2, Enum.EasingStyle.Sine), {
							CFrame = CFrame.new(home),
						}):Play()
					end
				end
			end
		end
	end)
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

--[[
	A tile in the section that a hazard can stand on.

	The pick used to be any tile in the rect, and the middle of a pool
	section's rect is water: The House put both of its sprinklers in the deep
	end, where they stood on the surface watering the swimming pool. The same
	rectangle the ground builder cuts the basin with is the one the pick now
	avoids, which is how the clutter scatter already works.
]]
local function dryTile(section: Types.ZoneDef): (number, number)
	local r = section.rect
	local water = if (section.kind or "open") == "pool" then Structures.poolRect(section) else nil
	local tx = rng:NextInteger(r.x + 2, r.x + r.w - 3)
	local tz = rng:NextInteger(r.z + 2, r.z + r.d - 3)
	for _ = 1, 20 do
		if
			not water
			or tx < water.x
			or tx >= water.x + water.w
			or tz < water.z
			or tz >= water.z + water.d
		then
			break
		end
		tx = rng:NextInteger(r.x + 2, r.x + r.w - 3)
		tz = rng:NextInteger(r.z + 2, r.z + r.d - 3)
	end
	return tx, tz
end

function HazardService.generate(world: Types.WorldDef)
	running = false
	if container then
		container:Destroy()
	end

	local container_ = WorldService.container()
	if not container_ then
		return
	end
	container = Build.folder("Hazards", container_)
	local parent = container :: Folder
	running = true

	for _, section in world.sections do
		local hazards = section.hazards
		if hazards then
			for _, kind in hazards do
				local tx, tz = dryTile(section)

				if kind == "sprinkler" then
					-- Two per section, so there is somewhere dry to retreat to.
					makeSprinkler(tx, tz, parent)
					local bx, bz = dryTile(section)
					makeSprinkler(bx, bz, parent)
				elseif kind == "wasps" then
					makeWaspNest(tx, tz, parent)
				elseif kind == "dog" then
					makeDog(tx, tz, parent)
				end
			end
		end
	end
end

function HazardService.start()
	EconomyService.addModifierSource(function(player: Player)
		return { stung = stung[player] ~= nil }
	end)

	Players.PlayerRemoving:Connect(function(player)
		stung[player] = nil
	end)

	WorldService.Loaded:Connect(HazardService.generate)

	local world = WorldService.world
	if world then
		HazardService.generate(world)
	end
end

return HazardService
