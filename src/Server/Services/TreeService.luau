--!strict
--[[
	TreeService — trees, stumps and the wood they leave behind.

	Trees are the one thing in the game that is a real Instance rather than a
	byte in a buffer, because there are dozens of them rather than thousands and
	felling one wants to be a visible event. They are also the best money on the
	world: a log takes fifteen units of bag space against a clipping's one but
	pays far more per unit, so hiking to the orchard is a decision rather than a
	strict upgrade.

	A felled tree leaves a stump, which only a stump grinder removes, and the
	world is not at 100% until both are gone.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DebrisConfig = require(Shared.Config.Debris)
local Format = require(Shared.Util.Format)
local Tools = require(Shared.Config.Tools)
local Types = require(Shared.Types)
local Worlds = require(Shared.Config.Worlds)
local BagService = require(script.Parent.BagService)
local Build = require(script.Parent.Parent.Lib.Build)
local DataService = require(script.Parent.DataService)
local RunState = require(script.Parent.RunState)
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
	sectionId: string,
	felled: boolean,
}

export type Stump = {
	part: BasePart,
	health: number,
	sectionId: string,
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

local function makeStump(position: Vector3, sectionId: string, parent: Instance): BasePart
	local part = Build.mesh({
		prop = "Stump",
		name = "Stump",
		size = Vector3.new(5, 2.4, 4.6),
		collisionSize = Vector3.new(4.5, 2.2, 4.5),
		cframe = CFrame.new(position + Vector3.new(0, 1.1, 0)),
		parent = parent,
	})

	-- Repeated presses rather than one long hold: a prompt fires once per press,
	-- and grinding a stump should feel like several goes at it.
	local prompt = Build.prompt(part, "Grind", "Stump", 14)
	prompt.Triggered:Connect(function(player: Player)
		onGrind(player, part)
	end)

	stumps[part] = { part = part, health = STUMP_HEALTH, sectionId = sectionId }
	return part
end

--[[
	Plants one tree, with the prompt that fells it.

	A tree does not count towards clearing the section it stands in, and this is
	deliberate rather than an oversight. It used to: four units of timber were
	added to the section's demand when the tree was planted and taken off again
	when it was felled. Felling needs a saw, the cheapest of which is $3,200,
	and every scrap of debris in the whole of The House is worth $2,013 — so the
	three trees in its backyard added twelve units that could not be removed at
	any price, to a section the world cannot be finished without. Worse, felling
	one left a stump, and the stump added three more units of its own that only
	a $140,000 grinder could take away, so buying the saw made the section
	harder rather than finishing it. The first world of the game was unwinnable.

	Everything that lies on a tile can be cleared with bare hands, so a section
	is always finishable by the work the run is actually balanced around. Trees
	and stumps sit on top of that: they pay, they count for quests, and they are
	there for anyone who wants them.
]]
local function makeTree(position: Vector3, sectionId: string, parent: Instance)
	local model = Instance.new("Model")
	model.Name = "Tree"

	local height = rng:NextNumber(22, 30)

	--[[
		One mesh for the whole tree, on a slim collision column.

		The tree used to be a brown box with a green box balanced on it. The
		model carries its own trunk and canopy, so the part underneath only has
		to be something to walk into and hang the Chop prompt on — a column the
		width of the trunk, rather than a block the width of the leaves.
	]]
	local trunk = Build.mesh({
		prop = "Tree",
		name = "Trunk",
		-- Proportions of the source mesh, so a taller tree is not a fatter one.
		size = Vector3.new(height * 0.666, height, height * 0.703),
		collisionSize = Vector3.new(3.4, height, 3.4),
		cframe = CFrame.new(position + Vector3.new(0, height * 0.5, 0)),
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
		sectionId = sectionId,
		felled = false,
	}
end

--- Scatters `count` points inside a section, keeping clear of the house.
--[[
	Whether something already built stands where a tree wants to go.

	The scatter knew about the house rect, the spawn, the trailer and the
	paving — every one of them a rectangle somebody remembered to write down.
	The Gas Station's shop is not in that list, so a maple grew against its
	back wall and stood in front of the service door. Trees are planted after
	the world is built, so rather than keeping a list of what exists, this
	asks: the box starts three studs up, which lets the lawn, the paving and
	the road pass underneath it and catches anything standing on them.
]]
local structureParams = OverlapParams.new()
structureParams.FilterType = Enum.RaycastFilterType.Include

local function blockedByStructure(at: Vector3): boolean
	local root = WorldService.container()
	if not root then
		return false
	end
	structureParams.FilterDescendantsInstances = { root }
	local parts = workspace:GetPartBoundsInBox(
		CFrame.new(at + Vector3.new(0, 11, 0)),
		Vector3.new(16, 16, 16),
		structureParams
	)
	for _, part in parts do
		if part.CanCollide then
			return true
		end
	end
	return false
end

local function scatter(world: Types.WorldDef, section: Types.ZoneDef, count: number): { Vector3 }
	local points: { Vector3 } = {}
	local r = section.rect
	local house = world.houseRect

	local attempts = 0
	while #points < count and attempts < count * 20 do
		attempts += 1
		local tx = rng:NextInteger(r.x, r.x + r.w - 1)
		local tz = rng:NextInteger(r.z, r.z + r.d - 1)

		local clear = true
		if house and tx >= house.x and tz >= house.z and tx < house.x + house.w and tz < house.z + house.d then
			clear = false
		end

		--[[
			Nothing grows on the doorstep.

			The house was the only thing kept clear, so a tree could take root
			on the spawn pad or against the trailer — the two places a run
			begins and ends, and the two places something in the way is most
			expensive.
		]]
		for _, keepOut in { world.spawn, world.trailer } do
			if keepOut and math.abs(tx - keepOut.x) < 7 and math.abs(tz - keepOut.z) < 7 then
				clear = false
				break
			end
		end

		if clear then
			local at = WorldService.tilePointToWorld(tx, tz)
			-- Not through the paving: a trunk in the middle of the driveway
			-- reads as a mistake, not a chore.
			if Worlds.onPaving(world, at.X, at.Z, 3) or blockedByStructure(at) then
				clear = false
			end
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
	local run = RunState.find(player)
	if not run or not run.ownedTools[run.equippedTool] then
		return nil
	end
	return Tools.get(run.equippedTool)
end

--- Awards debris to the bag, leaving anything that will not fit on the ground.
--[[
	Hands over a tree's worth of wood, dropping whatever will not fit in the bag.

	This used to also count the wood off the section's total, because the wood
	had been counted onto it when the tree was planted. Neither happens now: a
	tree and its stump are worth cash and count for the quests that ask for
	them, but they are not part of what "clear" means. See `makeTree`.
]]
local function awardOrDrop(player: Player, debrisId: number, units: number, position: Vector3): number
	local taken = BagService.add(player, debrisId, units)
	local left = units - taken

	if left > 0 then
		local def = DebrisConfig.get(debrisId)
		-- Timber looks like timber; everything else drops as a heap of leaves.
		local pile = Build.mesh({
			prop = if debrisId == DebrisConfig.Log then "Log" else "LeafPile",
			name = "Pile",
			size = Vector3.new(5, 2.4, 4),
			collisionSize = Vector3.new(5, 2, 3),
			cframe = CFrame.new(position + Vector3.new(0, 1, 0)),
			canCollide = false,
			parent = container,
		})
		pile:SetAttribute("DebrisId", debrisId)
		pile:SetAttribute("Units", left)
		CollectionService:AddTag(pile, "MowPile")

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

	--[[
		The tree is destroyed a second after it lands, and a sound dies with the
		instance it hangs on, so the noise of it coming down gets its own anchor
		that outlives the tree.
	]]
	if container then
		Build.soundAt(base, "Timber", container)
	end

	local logUnits = LOGS_PER_TREE * DebrisConfig.get(DebrisConfig.Log).unitsPerLevel
	awardOrDrop(player, DebrisConfig.Log, logUnits, base)

	if container then
		makeStump(base, tree.sectionId, container)
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

	-- On the trunk, so everyone nearby hears it from the tree rather than from
	-- wherever they happen to be standing.
	Build.sound(tree.trunk, "Chop", true)

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
	Build.sound(part, "Grind", true)
	if stump.health > 0 then
		return
	end

	stumps[part] = nil
	local chips = CHIPS_PER_STUMP * DebrisConfig.get(DebrisConfig.Chips).unitsPerLevel
	awardOrDrop(player, DebrisConfig.Chips, chips, part.Position)
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

function TreeService.generate(world: Types.WorldDef)
	clear()

	local root = WorldService.container()
	if not root then
		return
	end
	container = Build.folder("Trees", root)
	local parent = container :: Folder

	for _, section in world.sections do
		local treeCount = section.trees or 0
		if treeCount > 0 then
			for _, point in scatter(world, section, treeCount) do
				makeTree(point, section.id, parent)
			end
		end

		local stumpCount = section.stumps or 0
		if stumpCount > 0 then
			for _, point in scatter(world, section, stumpCount) do
				makeStump(point, section.id, parent)
			end
		end
	end
end

function TreeService.start()
	-- On `Built` rather than `Loaded`: the tile pass that hides what stands
	-- on a tile runs between the two, and a trunk is something standing on
	-- a tile.
	WorldService.Built:Connect(function(world: Types.WorldDef)
		TreeService.generate(world)
	end)

	local world = WorldService.world
	if world then
		TreeService.generate(world)
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
