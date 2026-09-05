--!strict
--[[
	Trees — the real ones, built once at boot and cloned.

	Two things about this file are scar tissue, and both are load-bearing.

	The first is that the meshes are fetched at runtime rather than written
	into the place. They were written into the place, as `.model.json` under
	ServerStorage, and what a player got was a leafy box: `MeshSize` is the
	engine telling you whether a mesh actually arrived, and a MeshPart whose
	mesh never arrives draws as a plain block at its full `Size` while its
	texture loads anyway and paints leaves on it. `CreateMeshPartAsync` was
	measured against the live universe and resolves all of them, so that is
	the road taken; and `usable` checks `MeshSize` on every layer before a
	template is handed out, so if that ever stops being true the callers get
	nil and plant their bush tree instead of a hundred boxes.

	The second is `plant` taking a height rather than a scale. The first
	version took a multiplier, and the two species are not the same size —
	the red maple is sixty studs tall out of the box and the sugar maple
	twenty-three. One multiplier across both made a seventy-eight-stud tree
	in a hundred-and-sixty-stud yard, which is what "leaves covering
	everything" turned out to mean. A caller says how tall it wants the tree
	and gets that, whatever the mesh happens to measure.

	One species, not two. The red maple was here and is gone: its crown is a
	sparse fan of leaf cards that reads as flat red cardboard from every angle,
	and its own trunk is a toothpick offset from the model origin, so a drawn
	one stands beside it rather than under it. Two trees where one of them
	looks wrong is worse than one that looks right, and a handful of real
	looking trees was the whole point of this file.

	The Japanese maple is not here either. Its crown carries no texture, only
	a PBR `SurfaceAppearance`, and a server cannot write one of those —
	`ColorMap` needs Plugin capability and throws.
]]

local AssetService = game:GetService("AssetService")

local Trees = {}

type Layer = {
	mesh: number,
	texture: number?,
	--- The size the layer is drawn at, before the tree is scaled to height.
	size: Vector3,
	--- Where it sits, measured from the tree's feet on the ground.
	at: Vector3,
	--- YXZ Euler degrees, as `ToEulerAnglesYXZ` reports them.
	turn: Vector3?,
	colour: Color3?,
}
--[[
	A trunk to stand the crown on, for a species whose meshes have none.

	Nothing in either Creator Store model reaches the ground. The red maple
	gets away with it because its crown mesh carries its own trunk all the
	way down; the sugar maple's lowest piece is the top of a trunk and starts
	six studs up, so what a player actually saw was a ball of leaves hanging
	in the air over an empty lawn — reported as trees "with no stump to them,
	only the weird looking leaves".

	The obvious place to fix that is the layer offsets, and it is the wrong
	one: no offset can draw geometry the mesh does not contain. So the missing
	length of trunk is drawn here, in the species' own unscaled studs, and is
	scaled along with everything else when the tree is planted.
]]
type Trunk = {
	--- How far up the trunk reaches. Overlap the lowest mesh a little.
	height: number,
	--- Across the shaft, and across the flare where it meets the ground.
	across: number,
	flare: number,
	colour: Color3,
}

type Species = { name: string, layers: { Layer }, trunk: Trunk? }

--- Transcribed layer by layer from the Creator Store models they came from,
--- so the assembly is the author's and only the placement is ours.
local SPECIES: { Species } = {
	{
		name = "SugarMaple",
		-- Up to 7.2, where the lowest mesh begins at 6.23, so the two meet
		-- with a stud of overlap rather than a seam.
		trunk = { height = 7.2, across = 2.7, flare = 3.5, colour = Color3.fromRGB(104, 74, 51) },
		layers = {
			{ mesh = 10066618419, texture = 10066748571, size = Vector3.new(3.0, 5.0, 2.8), at = Vector3.new(0.74, 8.73, 1.38) },
			{ mesh = 10066618421, texture = 3919199672, size = Vector3.new(11.3, 14.5, 13.2), at = Vector3.new(1.38, 15.48, 0.23) },
			{ mesh = 10066618436, texture = 3919199672, size = Vector3.new(22.0, 23.4, 24.7), at = Vector3.new(0, 17.88, 0) },
		},
	},
}

--- How far a trunk is sunk below the ground it stands on, to hide the seam.
local SINK = 0.5

local templates: { [string]: Model } = {}
local heights: { [string]: number } = {}
local warmed, warming = false, false

local function buildLayer(layer: Layer): MeshPart?
	local ok, result = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromAssetId(layer.mesh), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Automatic,
		})
	end)
	if not ok then
		warn(`[Trees] mesh {layer.mesh} did not load: {result}`)
		return nil
	end
	local part = result :: MeshPart
	--[[
		The mesh has to have actually arrived.

		A MeshPart whose mesh failed still exists, still takes a texture, and
		draws as a box. `MeshSize` is zero in that case and non-zero in every
		other, which makes it the one honest question to ask.
	]]
	if part.MeshSize.Magnitude < 0.01 then
		warn(`[Trees] mesh {layer.mesh} came back empty; it would draw as a box`)
		part:Destroy()
		return nil
	end
	part.Name = "Leaves"
	part.Size = layer.size
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = true
	part.Color = layer.colour or Color3.fromRGB(163, 162, 165)
	if layer.texture then
		part.TextureID = `rbxassetid://{layer.texture}`
	end
	local turn = layer.turn or Vector3.zero
	part.CFrame = CFrame.new(layer.at)
		* CFrame.fromEulerAnglesYXZ(math.rad(turn.X), math.rad(turn.Y), math.rad(turn.Z))
	return part
end

--[[
	The length of trunk the meshes do not draw.

	A cylinder rather than a block, because a square trunk under a round
	crown reads as scaffolding; and a short wider one at the foot, because a
	shaft meeting flat grass at a right angle is the thing that makes a tree
	look posted into the ground rather than grown out of it.

	`PartType.Cylinder` runs along X, so both are turned to stand up.
]]
local function buildTrunk(trunk: Trunk, model: Model)
	local function column(height: number, across: number, base: number)
		local part = Instance.new("Part")
		part.Name = "Trunk"
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(height, across, across)
		part.CFrame = CFrame.new(0, base + height * 0.5, 0) * CFrame.Angles(0, 0, math.rad(90))
		part.Color = trunk.colour
		part.Material = Enum.Material.Wood
		part.Anchored = true
		part.CanCollide = false
		part.CastShadow = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
	end
	-- Sunk a little at the foot so the flare has no visible bottom face.
	column(trunk.height, trunk.across, 0)
	column(1.4, trunk.flare, -0.4)
end

--[[
	Builds every species once. Safe to call more than once; the second call
	does nothing. Eight web calls, so callers run it in a thread of its own.
]]
function Trees.warm()
	if warmed then
		return
	end
	--[[
		The second caller waits rather than walking past.

		Boot warms these in a thread of its own so the server does not sit on
		eight web calls, and a world built before that finishes calls it too.
		Setting a flag and returning would hand the second caller an empty
		table and a property full of fallback trees, so it waits for the
		first one instead.
	]]
	if warming then
		while not warmed do
			task.wait(0.1)
		end
		return
	end
	warming = true
	for _, species in SPECIES do
		local model = Instance.new("Model")
		model.Name = species.name
		local whole = true
		for _, layer in species.layers do
			local part = buildLayer(layer)
			if not part then
				whole = false
				break
			end
			part.Parent = model
		end
		if whole and species.trunk then
			buildTrunk(species.trunk, model)
		end
		if whole then
			model.WorldPivot = CFrame.identity
			templates[species.name] = model
			heights[species.name] = model:GetExtentsSize().Y
		else
			model:Destroy()
			warn(`[Trees] {species.name} is unusable; callers will plant their own`)
		end
	end
	warmed = true
end

--- The species that built cleanly, for a caller picking one at random.
function Trees.available(): { string }
	local out = {}
	for name in templates do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

--[[
	One tree of a species, `height` studs tall, standing at `at`.

	Nil when that species did not build, which is the caller's cue to plant
	whatever it used before rather than to leave a gap.
]]
function Trees.plant(name: string, at: Vector3, height: number, turn: number, parent: Instance): Model?
	local template = templates[name]
	local natural = heights[name]
	if not template or not natural or natural <= 0 then
		return nil
	end
	local tree = template:Clone()
	tree.WorldPivot = CFrame.identity
	tree:ScaleTo(height / natural)
	tree:PivotTo(CFrame.new(at) * CFrame.Angles(0, turn, 0))

	--[[
		Stands it on its own base rather than trusting the offsets.

		Each layer's `at` was read off the mesh in Studio, and the assumption
		underneath them was that the bottom of the lowest layer is the bottom
		of the tree. For the red maple that happens to be true — its trunk
		reaches y=0 — and for the sugar maple it is not: that trunk mesh only
		covers the upper trunk and starts six studs up, so every sugar maple
		in the lobby hung six or seven studs clear of the grass with nothing
		underneath it. From across the yard it read as a bush floating in the
		sky.

		Measuring the model is the answer rather than correcting the numbers,
		because the numbers are only right by accident either way, and the
		next species added would be a coin toss. Whatever the meshes turn out
		to contain, the lowest point of the thing ends up where the ground is.

		A little under the surface, not exactly on it: resting a trunk exactly
		on the grass leaves a visible seam where the two planes meet, and half
		a stud of sink hides it without burying the flare of the roots.
	]]
	local pivot, size = tree:GetBoundingBox()
	local base = pivot.Position.Y - size.Y * 0.5
	local drop = base - (at.Y - SINK)
	if math.abs(drop) > 0.01 then
		tree:PivotTo(CFrame.new(0, -drop, 0) * tree:GetPivot())
	end

	tree.Parent = parent
	return tree
end

return Trees
