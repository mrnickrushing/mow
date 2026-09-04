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
local Structures = require(script.Parent.Parent.Lib.Structures)
local WorldService = require(script.Parent.WorldService)

local CollectibleService = {}

--[[
	What a Golden Blade pays. Flat, and not multiplied by anything.

	This was twelve "before the world multiplier", and then `award` put the
	player's whole multiplier stack on top of that as well. On the gas
	station with a couple of cash upgrades bought it came to twelve times
	2.1 times 2.5 — sixty-three cash for one pickup, when a clipping pays
	five hundredths. One trophy was worth about twelve hundred clippings,
	which is not a bonus, it is a way of skipping the game.

	A collectible is a finder's fee, not income: the same ten wherever it is
	found and whatever you have bought.
]]
local BLADE_CASH = 10
--- The blade's own box, shared so the spot it is tested for is the spot it fills.
local BLADE_SIZE = Vector3.new(2.4, 4.8, 2.4)
local BLADE_LIFT = Vector3.new(0, 3, 0)
local BLADE_TIPS = 3

local container: Folder? = nil
local rng = Random.new()
--- Blade part -> the function that awards it, shared with AutoCollectService.
local collectors: { [BasePart]: (Player) -> () } = {}

local function spawnBlade(position: Vector3, section: Types.ZoneDef, parent: Instance)
	local part = Build.mesh({
		prop = "GoldenBlade",
		name = "GoldenBlade",
		size = BLADE_SIZE,
		collisionSize = Vector3.new(1.6, 4, 0.4),
		cframe = CFrame.new(position + BLADE_LIFT),
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

		-- `awardRaw`, so neither the world's payout multiplier nor the
		-- player's upgrades inflate what is meant to be a flat finder's fee.
		local paid = EconomyService.awardRaw(player, BLADE_CASH)
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

--[[
	Somewhere in this section the blade can actually be seen.

	The tile was picked at random with nothing ruled out, and measured over
	eighteen world loads eleven blades of a hundred and eight — one in ten —
	came up inside the scenery, most often inside a wall, with two more
	hovering over a pool. None of that stops you collecting it: the sweep
	reaches 26 studs and the prompt is set not to need line of sight. It stops
	you *finding* it, which is the whole job. `spawnBlade` says as much about
	the spin and the bob: it "is the only thing that makes it findable in tall
	grass", and none of it helps from inside a wall.

	Clutter cannot check this because it is scattered mid-build. Collectibles
	are generated from `WorldService.Loaded`, when the world is finished and
	standing, so here the question simply has an answer.
]]
local ATTEMPTS = 20

local function clearSpotIn(section: Types.ZoneDef, ignore: Instance): Vector3
	local r = section.rect
	local fallback: Vector3? = nil
	local fewest = math.huge

	--[[
		The pool is the emptiest box in the level.

		Nothing stands three studs above open water, so a search that only
		asks "is this spot clear?" finds the deep end first and prefers it.
		Testing this fix without ruling the water out doubled the blades left
		hovering over a pool — a better answer to the wrong question. Clutter
		keeps off the water for the same reason and by the same rectangle.
	]]
	local water: Types.Rect? = if section.kind == "pool" then Structures.poolRect(section) else nil

	for _ = 1, ATTEMPTS do
		local tx = rng:NextInteger(r.x, r.x + r.w - 1)
		local tz = rng:NextInteger(r.z, r.z + r.d - 1)
		if
			water ~= nil
			and tx >= water.x
			and tx < water.x + water.w
			and tz >= water.z
			and tz < water.z + water.d
		then
			continue
		end
		local at = WorldService.tilePointToWorld(tx, tz)

		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { ignore }
		params.MaxParts = 4
		local hits = workspace:GetPartBoundsInBox(CFrame.new(at + BLADE_LIFT), BLADE_SIZE, params)

		if #hits == 0 then
			return at
		end
		if #hits < fewest then
			fewest = #hits
			fallback = at
		end
	end

	-- Every tile in this section had something in it. Better a blade in a
	-- crowded corner than no blade in the section at all.
	return fallback or WorldService.tilePointToWorld(r.x, r.z)
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
		spawnBlade(clearSpotIn(section, parent), section, parent)
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
