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

	The Japanese maple is not here. Its crown carries no texture, only a PBR
	`SurfaceAppearance`, and a server cannot write one of those — `ColorMap`
	needs Plugin capability and throws. Two species is a handful.
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
type Species = { name: string, layers: { Layer } }

--- Transcribed layer by layer from the Creator Store models they came from,
--- so the assembly is the author's and only the placement is ours.
local SPECIES: { Species } = {
	{
		name = "SugarMaple",
		layers = {
			{ mesh = 10066618419, texture = 10066748571, size = Vector3.new(3.0, 5.0, 2.8), at = Vector3.new(0.74, 8.73, 1.38) },
			{ mesh = 10066618421, texture = 3919199672, size = Vector3.new(11.3, 14.5, 13.2), at = Vector3.new(1.38, 15.48, 0.23) },
			{ mesh = 10066618436, texture = 3919199672, size = Vector3.new(22.0, 23.4, 24.7), at = Vector3.new(0, 17.88, 0) },
		},
	},
	{
		name = "RedMaple",
		layers = {
			{
				mesh = 743205420,
				texture = 743204224,
				size = Vector3.new(25.1, 38.0, 26.4),
				at = Vector3.new(0.26, 18.99, -1.85),
				turn = Vector3.new(2, -150, -4),
			},
			{
				mesh = 743205322,
				texture = 11236617669,
				colour = Color3.fromRGB(160, 95, 53),
				size = Vector3.new(50.1, 53.4, 41.0),
				at = Vector3.new(0, 32.72, 0),
				turn = Vector3.new(4, -60, 3),
			},
		},
	},
}

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
	-- The layers are placed relative to the feet, so the feet are the origin:
	-- scale about them, then stand them where they were asked for.
	tree.WorldPivot = CFrame.identity
	tree:ScaleTo(height / natural)
	tree:PivotTo(CFrame.new(at) * CFrame.Angles(0, turn, 0))
	tree.Parent = parent
	return tree
end

return Trees
