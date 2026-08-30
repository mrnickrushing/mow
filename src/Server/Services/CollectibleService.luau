--!strict
--[[
	CollectibleService — Golden Blades.

	One hidden collectible per section, worth a large lump of cash and a tip. They
	exist because a completion bar alone makes players sweep systematically; a
	prize hidden in the long grass makes them look. Each is respawned fresh every
	round, so the hunt renews with the map.

	Deliberately never required for 100%. The reference game leaves solo players
	permanently stuck at 99% behind co-op-only pickups, and that is the single
	most common complaint about it.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Types = require(Shared.Types)
local Build = require(script.Parent.Parent.Lib.Build)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local WorldService = require(script.Parent.WorldService)

local CollectibleService = {}

--- Cash a Golden Blade pays, before the world multiplier.
local BLADE_CASH = 12
local BLADE_TIPS = 3

local container: Folder? = nil
local rng = Random.new()
--- Blade part -> the function that awards it, shared with AutoCollectService.
local collectors: { [BasePart]: (Player) -> () } = {}

local function spawnBlade(position: Vector3, section: Types.ZoneDef, parent: Instance)
	local part = Build.mesh({
		prop = "GoldenBlade",
		name = "GoldenBlade",
		size = Vector3.new(2.4, 4.8, 2.4),
		collisionSize = Vector3.new(1.6, 4, 0.4),
		cframe = CFrame.new(position + Vector3.new(0, 3, 0)),
		canCollide = false,
		castShadow = false,
		parent = parent,
	})

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 214, 110)
	light.Range = 14
	light.Brightness = 1.6
	light.Parent = part

	-- Spinning and bobbing is the only thing that makes it findable in tall grass.
	TweenService:Create(
		part,
		TweenInfo.new(2.4, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
		{ CFrame = part.CFrame * CFrame.Angles(0, math.pi * 1.99, 0) }
	):Play()

	CollectionService:AddTag(part, "MowBlade")

	local prompt = Build.prompt(part, "Take", "Golden Blade", 12)
	local function take(player: Player)
		if not part.Parent then
			return
		end
		part:Destroy()

		local world = WorldService.world
		local multiplier = if world then world.payoutMultiplier else 1
		local paid = EconomyService.award(player, BLADE_CASH * multiplier)
		EconomyService.awardTips(player, BLADE_TIPS)

		DataService.withProfile(player, function(profile)
			profile.stats.goldenBlades += 1
		end)

		EconomyService.notifyAll(
			"stripe",
			`{player.DisplayName} found the Golden Blade in the {section.name} — {Format.cash(paid)}`,
			paid
		)
	end

	prompt.Triggered:Connect(take)
	-- Exposed so the Auto-Collect pass can pick one up without a prompt.
	part:SetAttribute("Collectable", true)
	collectors[part] = take
end

--- Awards the blade to `player` as though they had used its prompt.
function CollectibleService.collect(part: BasePart, player: Player)
	local take = collectors[part]
	if take then
		collectors[part] = nil
		take(player)
	end
end

function CollectibleService.generate(world: Types.WorldDef)
	table.clear(collectors)
	if container then
		container:Destroy()
	end
	local container_ = WorldService.container()
	if not container_ then
		return
	end
	container = Build.folder("Collectibles", container_)
	local parent = container :: Folder

	for _, section in world.sections do
		local r = section.rect
		local tx = rng:NextInteger(r.x, r.x + r.w - 1)
		local tz = rng:NextInteger(r.z, r.z + r.d - 1)
		spawnBlade(WorldService.tilePointToWorld(tx, tz), section, parent)
	end
end

function CollectibleService.start()
	WorldService.Loaded:Connect(CollectibleService.generate)

	local world = WorldService.world
	if world then
		CollectibleService.generate(world)
	end
end

return CollectibleService
