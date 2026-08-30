--!strict
--[[
	CollectibleService — Golden Blades.

	One hidden collectible per zone, worth a large lump of cash and a tip. They
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

--- Cash a Golden Blade pays, before the property multiplier.
local BLADE_CASH = 750
local BLADE_TIPS = 3

local container: Folder? = nil
local rng = Random.new()
--- Blade part -> the function that awards it, shared with AutoCollectService.
local collectors: { [BasePart]: (Player) -> () } = {}

local function spawnBlade(position: Vector3, zone: Types.ZoneDef, parent: Instance)
	local part = Build.part({
		name = "GoldenBlade",
		size = Vector3.new(1.6, 4, 0.4),
		cframe = CFrame.new(position + Vector3.new(0, 3, 0)),
		color = Color3.fromRGB(247, 203, 74),
		material = Enum.Material.Neon,
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

		local property = WorldService.property
		local multiplier = if property then property.payoutMultiplier else 1
		local paid = EconomyService.award(player, BLADE_CASH * multiplier)
		EconomyService.awardTips(player, BLADE_TIPS)

		DataService.withProfile(player, function(profile)
			profile.stats.goldenBlades += 1
		end)

		EconomyService.notifyAll(
			"stripe",
			`{player.DisplayName} found the Golden Blade in the {zone.name} — {Format.cash(paid)}`,
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

function CollectibleService.generate(property: Types.PropertyDef)
	table.clear(collectors)
	if container then
		container:Destroy()
	end
	local world = WorldService.container()
	if not world then
		return
	end
	container = Build.folder("Collectibles", world)
	local parent = container :: Folder

	for _, zone in property.zones do
		local r = zone.rect
		local tx = rng:NextInteger(r.x, r.x + r.w - 1)
		local tz = rng:NextInteger(r.z, r.z + r.d - 1)
		spawnBlade(WorldService.tilePointToWorld(tx, tz), zone, parent)
	end
end

function CollectibleService.start()
	WorldService.Loaded:Connect(CollectibleService.generate)

	local property = WorldService.property
	if property then
		CollectibleService.generate(property)
	end
end

return CollectibleService
