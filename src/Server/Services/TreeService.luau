--!strict
--[[
	TreeService — trees, stumps and the wood they leave behind.

	Trees are the one thing in the game that is a real Instance rather than a
	byte in a buffer, because there are dozens of them rather than thousands and
	felling one wants to be a visible event. They are also the best money on the
	property: a log takes fifteen units of bag space against a clipping's one but
	pays far more per unit, so hiking to the orchard is a decision rather than a
	strict upgrade.

	A felled tree leaves a stump, which only a stump grinder removes, and the
	property is not at 100% until both are gone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DebrisConfig = require(Shared.Config.Debris)
local Format = require(Shared.Util.Format)
local Tools = require(Shared.Config.Tools)
local Types = require(Shared.Types)
local BagService = require(script.Parent.BagService)
local Build = require(script.Parent.Parent.Lib.Build)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local WorldService = require(script.Parent.WorldService)

local TreeService = {}

--- Chops needed to fell a tree, before tool power is applied.
local TREE_HEALTH = 12
--- Log units a felled tree yields.
local LOGS_PER_TREE = 4
--- Chip units a ground stump yields.
local CHIPS_PER_STUMP = 3
--- Grinds needed to clear a stump.
local STUMP_HEALTH = 6

export type Tree = {
	model: Model,
	trunk: BasePart,
	health: number,
	maxHealth: number,
	zoneId: string,
	felled: boolean,
}

export type Stump = {
	part: BasePart,
	health: number,
	zoneId: string,
}

local trees: { [Model]: Tree } = {}
local stumps: { [BasePart]: Stump } = {}
local container: Folder? = nil
local rng = Random.new()

-- Declared up front so makeTree/makeStump can wire their own prompts.
local onChop: (Player, Model) -> ()
local onGrind: (Player, BasePart) -> ()

--------------------------------------------------------------------
-- Building
--------------------------------------------------------------------

local function makeStump(position: Vector3, zoneId: string, parent: Instance): BasePart
	local part = Build.part({
		name = "Stump",
		size = Vector3.new(4.5, 2.2, 4.5),
		cframe = CFrame.new(position + Vector3.new(0, 1.1, 0)),
		color = Color3.fromRGB(94, 68, 44),
		material = Enum.Material.Wood,
		parent = parent,
	})

	-- Repeated presses rather than one long hold: a prompt fires once per press,
	-- and grinding a stump should feel like several goes at it.
	local prompt = Build.prompt(part, "Grind", "Stump", 14)
	prompt.Triggered:Connect(function(player: Player)
		onGrind(player, part)
	end)

	stumps[part] = { part = part, health = STUMP_HEALTH, zoneId = zoneId }
	WorldService.registerExtraUnits(zoneId, CHIPS_PER_STUMP * DebrisConfig.get(DebrisConfig.Chips).unitsPerLevel)
	return part
end

local function makeTree(position: Vector3, zoneId: string, parent: Instance)
	local model = Instance.new("Model")
	model.Name = "Tree"

	local height = rng:NextNumber(20, 30)
	local trunk = Build.part({
		name = "Trunk",
		size = Vector3.new(3.4, height, 3.4),
		cframe = CFrame.new(position + Vector3.new(0, height * 0.5, 0)),
		color = Color3.fromRGB(102, 72, 48),
		material = Enum.Material.Wood,
		parent = model,
	})

	local canopyRadius = rng:NextNumber(11, 16)
	Build.part({
		name = "Canopy",
		size = Vector3.new(canopyRadius, canopyRadius * 0.8, canopyRadius),
		cframe = CFrame.new(position + Vector3.new(0, height + canopyRadius * 0.25, 0)),
		color = Color3.fromRGB(52, 108, 46),
		material = Enum.Material.Grass,
		canCollide = false,
		parent = model,
	})

	model.PrimaryPart = trunk
	model.Parent = parent

	local prompt = Build.prompt(trunk, "Chop", "Tree", 16)
	prompt.Triggered:Connect(function(player: Player)
		onChop(player, model)
	end)

	trees[model] = {
		model = model,
		trunk = trunk,
		health = TREE_HEALTH,
		maxHealth = TREE_HEALTH,
		zoneId = zoneId,
		felled = false,
	}
	WorldService.registerExtraUnits(zoneId, LOGS_PER_TREE * DebrisConfig.get(DebrisConfig.Log).unitsPerLevel)
end

--- Scatters `count` points inside a zone, keeping clear of the house.
local function scatter(property: Types.PropertyDef, zone: Types.ZoneDef, count: number): { Vector3 }
	local points: { Vector3 } = {}
	local r = zone.rect
	local house = property.houseRect

	local attempts = 0
	while #points < count and attempts < count * 20 do
		attempts += 1
		local tx = rng:NextInteger(r.x, r.x + r.w - 1)
		local tz = rng:NextInteger(r.z, r.z + r.d - 1)

		local clear = true
		if house and tx >= house.x and tz >= house.z and tx < house.x + house.w and tz < house.z + house.d then
			clear = false
		end

		if clear then
			local at = WorldService.tilePointToWorld(tx, tz)
			-- Keep trees from growing through each other.
			for _, existing in points do
				if (existing - at).Magnitude < 18 then
					clear = false
					break
				end
			end
			if clear then
				table.insert(points, at)
			end
		end
	end

	return points
end

--------------------------------------------------------------------
-- Interaction
--------------------------------------------------------------------

--- The tool a player is holding, if they own and have it equipped.
local function equippedTool(player: Player): Types.ToolDef?
	local profile = DataService.get(player)
	if not profile or not profile.ownedTools[profile.equippedTool] then
		return nil
	end
	return Tools.get(profile.equippedTool)
end

--- Awards debris to the bag, leaving anything that will not fit on the ground.
local function awardOrDrop(player: Player, debrisId: number, units: number, position: Vector3, zoneId: string): number
	local taken = BagService.add(player, debrisId, units)
	local left = units - taken

	if left > 0 then
		local def = DebrisConfig.get(debrisId)
		local pile = Build.part({
			name = "Pile",
			size = Vector3.new(5, 2, 3),
			cframe = CFrame.new(position + Vector3.new(0, 1, 0)),
			color = Color3.new(def.color[1], def.color[2], def.color[3]),
			material = Enum.Material.Wood,
			canCollide = false,
			parent = container,
		})
		pile:SetAttribute("DebrisId", debrisId)
		pile:SetAttribute("Units", left)

		-- Dropped rather than destroyed: a player who did not notice their bag
		-- was full should not silently lose a whole tree's worth of work.
		local prompt = Build.prompt(pile, "Collect", `{def.name} x{Format.count(left)}`, 14)
		prompt.Triggered:Connect(function(collector: Player)
			local remaining = pile:GetAttribute("Units")
			if type(remaining) ~= "number" or remaining <= 0 then
				return
			end
			local got = BagService.add(collector, debrisId, remaining)
			if got <= 0 then
				EconomyService.notify(collector, "bagFull", "Bag full — get to the trailer", nil)
				return
			end
			if got >= remaining then
				pile:Destroy()
			else
				pile:SetAttribute("Units", remaining - got)
			end
		end)
	end

	if zoneId ~= "" then
		-- Completion counts the wood as cleared once it leaves the tree, whether
		-- it went into a bag or onto the ground.
		WorldService.consumeUnits(zoneId, units)
	end

	return taken
end

local function fellTree(player: Player, tree: Tree)
	if tree.felled then
		return
	end
	tree.felled = true
	trees[tree.model] = nil

	local base = tree.trunk.Position - Vector3.new(0, tree.trunk.Size.Y * 0.5, 0)

	for _, descendant in tree.model:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			descendant:Destroy()
		end
	end

	-- Topple away from whoever felled it, so the tree never falls through them.
	local chopperAt = base
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		chopperAt = root.Position
	end

	local away = (tree.trunk.Position - chopperAt) * Vector3.new(1, 0, 1)
	local direction = if away.Magnitude > 0.1 then away.Unit else Vector3.new(1, 0, 0)
	local axis = Vector3.new(-direction.Z, 0, direction.X)

	local pivot = CFrame.new(base) * CFrame.fromAxisAngle(axis, math.rad(88))
	local goal = pivot * CFrame.new(0, tree.trunk.Size.Y * 0.5, 0)

	local tween = TweenService:Create(
		tree.trunk,
		TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ CFrame = goal }
	)

	-- The canopy has to travel with the trunk, so weld before tweening.
	for _, part in tree.model:GetChildren() do
		if part:IsA("BasePart") and part ~= tree.trunk then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = tree.trunk
			weld.Part1 = part
			weld.Parent = tree.trunk
			part.Anchored = false
		end
	end

	tween:Play()
	tween.Completed:Connect(function()
		task.wait(0.8)
		if tree.model.Parent then
			tree.model:Destroy()
		end
	end)

	local logUnits = LOGS_PER_TREE * DebrisConfig.get(DebrisConfig.Log).unitsPerLevel
	awardOrDrop(player, DebrisConfig.Log, logUnits, base, tree.zoneId)

	if container then
		makeStump(base, tree.zoneId, container)
	end

	DataService.withProfile(player, function(profile)
		profile.stats.treesFelled += 1
	end)
	EconomyService.notify(player, "sale", "Timber! Log it at the trailer", nil)
end

function onChop(player: Player, model: Model)
	local tree = trees[model]
	if not tree or tree.felled then
		return
	end

	local tool = equippedTool(player)
	if not tool or (tool.category ~= "Chainsaw" and tool.category ~= "Saw") then
		EconomyService.notify(player, "stall", "You need a saw for this", nil)
		return
	end

	-- A chainsaw bites harder than a pole saw, so the ladder still matters here.
	local damage = if tool.category == "Chainsaw" then 3 else 1
	tree.health -= damage

	if tree.health <= 0 then
		fellTree(player, tree)
	else
		local shake = TweenService:Create(tree.trunk, TweenInfo.new(0.08, Enum.EasingStyle.Sine), {
			CFrame = tree.trunk.CFrame * CFrame.Angles(0, 0, math.rad(1.6)),
		})
		shake:Play()
	end
end

function onGrind(player: Player, part: BasePart)
	local stump = stumps[part]
	if not stump then
		return
	end

	local tool = equippedTool(player)
	if not tool or tool.category ~= "Grinder" then
		EconomyService.notify(player, "stall", "Only a stump grinder shifts this", nil)
		return
	end

	stump.health -= 2
	if stump.health > 0 then
		return
	end

	stumps[part] = nil
	local chips = CHIPS_PER_STUMP * DebrisConfig.get(DebrisConfig.Chips).unitsPerLevel
	awardOrDrop(player, DebrisConfig.Chips, chips, part.Position, stump.zoneId)
	part:Destroy()
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

local function clear()
	table.clear(trees)
	table.clear(stumps)
	if container then
		container:Destroy()
		container = nil
	end
end

function TreeService.generate(property: Types.PropertyDef)
	clear()

	local world = WorldService.container()
	if not world then
		return
	end
	container = Build.folder("Trees", world)
	local parent = container :: Folder

	for _, zone in property.zones do
		local treeCount = zone.trees or 0
		if treeCount > 0 then
			for _, point in scatter(property, zone, treeCount) do
				makeTree(point, zone.id, parent)
			end
		end

		local stumpCount = zone.stumps or 0
		if stumpCount > 0 then
			for _, point in scatter(property, zone, stumpCount) do
				makeStump(point, zone.id, parent)
			end
		end
	end
end

function TreeService.start()
	WorldService.Loaded:Connect(function(property: Types.PropertyDef)
		TreeService.generate(property)
	end)

	local property = WorldService.property
	if property then
		TreeService.generate(property)
	end
end

--- How many trees are still standing, for the round summary.
function TreeService.standingTrees(): number
	local count = 0
	for _, tree in trees do
		if not tree.felled then
			count += 1
		end
	end
	return count
end

function TreeService.remainingStumps(): number
	local count = 0
	for _ in stumps do
		count += 1
	end
	return count
end

return TreeService
