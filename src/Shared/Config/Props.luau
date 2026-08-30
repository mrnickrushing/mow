--!strict
--[[
	Props — the mesh catalogue the world is built from.

	Every prop in the game used to be a rectangle: bins were boxes, hedges were
	boxes, the dog was a box, and a tree was a brown box under a green one. This
	is the list of real models that replaced them.

	Each entry is a mesh asset and the size that mesh is when Roblox imports it.
	That native size matters: a `SpecialMesh` renders at its own size times its
	`Scale` and pays no attention to the part it hangs on, so the only way to
	ask for "a bin four studs wide" is to divide the size you want by the size
	the mesh already is. `Build.mesh` does that division; everything else just
	names a prop and a size.

	Meshes rather than whole models on purpose. A model would have to be loaded
	through `InsertService` at run time, which needs the place published and the
	assets owned by whoever runs it — it fails outright in an unpublished Studio
	session. A mesh id is content, like an image: it renders anywhere, costs one
	part, and survives `rojo build` because it lives in this file rather than in
	a binary the project would have to carry.
]]

local Props = {}

export type Prop = {
	mesh: string,
	texture: string?,
	--- The size Roblox gives this mesh on import, before any scaling.
	native: Vector3,
	--- Tint applied to the part under the mesh. Untextured meshes need it.
	color: Color3?,
}

local function prop(mesh: string, texture: string?, x: number, y: number, z: number, color: Color3?): Prop
	return { mesh = mesh, texture = texture, native = Vector3.new(x, y, z), color = color }
end

local catalogue: { [string]: Prop } = {
	-- Yard clutter, the things debris hides against.
	Bin = prop("rbxassetid://111382182448892", "rbxassetid://122437876857070", 3.634, 6.000, 3.418),
	Crate = prop("rbxassetid://136480727286301", "rbxassetid://118895997883552", 5.000, 3.040, 4.043),
	Planter = prop("rbxassetid://132421447542728", "rbxassetid://78012514749472", 2.619, 4.000, 2.644),
	Chair = prop("rbxassetid://106467236413072", "rbxassetid://133666995767237", 3.446, 4.500, 3.576),
	Barrel = prop("rbxassetid://83356930625729", "rbxassetid://104527617496431", 4.000, 4.236, 3.980),
	Rock = prop("rbxassetid://132924624861328", "rbxassetid://89076492492334", 1.447, 4.000, 1.451),

	-- Planting.
	Bush = prop("rbxassetid://72280757885260", "rbxassetid://140562129266244", 3.736, 8.000, 3.700),
	Hedge = prop("rbxassetid://72280757885260", "rbxassetid://140562129266244", 3.736, 8.000, 3.700),
	Tree = prop("rbxassetid://131361580865388", "rbxassetid://92687150630349", 15.156, 22.768, 16.000),
	Stump = prop("rbxassetid://132967367565646", "rbxassetid://88604401051093", 1.683, 2.500, 1.560),
	Log = prop("rbxassetid://135854002039541", "rbxassetid://136724661905485", 2.500, 0.985, 1.650),
	LeafPile = prop("rbxassetid://130494819737391", "rbxassetid://97469677584763", 4.596, 2.000, 4.592),

	-- Structures.
	Fence = prop("rbxassetid://109120828950770", "rbxassetid://99346791051845", 5.272, 3.059, 0.600),
	Shed = prop("rbxassetid://136505549556407", "rbxassetid://130296685263073", 15.868, 18.000, 15.692),
	Trailer = prop("rbxassetid://72699501903410", "rbxassetid://119991357734404", 7.030, 5.706, 12.000),

	-- Things that move or matter.
	RidingMower = prop("rbxassetid://89706697093178", "rbxassetid://120136128501167", 5.476, 6.000, 9.364),
	Dog = prop("rbxassetid://74175582988973", "rbxassetid://77296052752514", 1.527, 4.000, 3.141),
	Sprinkler = prop("rbxassetid://133265868962502", "rbxassetid://140459804380273", 1.568, 2.000, 1.575),
	WaspNest = prop("rbxassetid://109192227690970", "rbxassetid://91421064853539", 2.784, 4.000, 2.774),
	GoldenBlade = prop("rbxassetid://76860455179857", "rbxassetid://118765026020204", 0.993, 1.974, 1.000),

	-- Built structure: the pieces the house, shed and gates are assembled from.
	Siding = prop("rbxassetid://75854563308151", "rbxassetid://83732768569742", 2.668, 2.549, 1.000),
	BrickWall = prop("rbxassetid://140006814129918", "rbxassetid://79095318666845", 4.153, 3.694, 1.500),
	Column = prop("rbxassetid://91990804948432", "rbxassetid://118138575646702", 2.200, 5.470, 1.427),
	Railing = prop("rbxassetid://121758695483526", "rbxassetid://72616628550520", 8.279, 3.514, 0.800),
	Window = prop("rbxassetid://97444539728739", "rbxassetid://85708816813129", 3.008, 4.450, 0.800),
	Door = prop("rbxassetid://105328951484791", "rbxassetid://71888888532368", 2.583, 4.331, 0.800),
	GarageDoor = prop("rbxassetid://97701724652211", "rbxassetid://84418560807782", 2.729, 2.288, 1.000),
	Counter = prop("rbxassetid://83666296495380", "rbxassetid://99555960161357", 8.654, 5.694, 5.000),
	StepBlock = prop("rbxassetid://106316877928108", "rbxassetid://113878058483033", 4.390, 1.754, 3.000),
	Gate = prop("rbxassetid://88429791455602", "rbxassetid://129724919454464", 7.352, 12.000, 1.830),
	Grate = prop("rbxassetid://107784319905798", "rbxassetid://123179659382912", 5.218, 7.929, 2.000),
	Sign = prop("rbxassetid://89328138606331", "rbxassetid://121079808488481", 5.186, 6.124, 1.000),
	ShopBoard = prop("rbxassetid://127953130831132", "rbxassetid://93758011506584", 4.715, 5.528, 1.000),

	-- What the lawn itself is made of, one clump per tile.
	GrassTuft = prop("rbxassetid://74167825959027", "rbxassetid://115670301597551", 3.986, 2.882, 4.000),
	Weeds = prop("rbxassetid://97566895867036", "rbxassetid://100631337116622", 3.995, 3.809, 4.000),
	Twigs = prop("rbxassetid://131001130360981", "rbxassetid://135819322286106", 2.061, 2.000, 2.112),

	-- Ground and roofing, the surfaces underfoot and overhead.
	Paving = prop("rbxassetid://118911737218481", "rbxassetid://75203797606065", 2.483, 0.500, 2.503),
	Turf = prop("rbxassetid://117425736001931", "rbxassetid://118240994936541", 6.966, 1.000, 6.963),
	Shingle = prop("rbxassetid://136161442160867", "rbxassetid://104453830463425", 1.029, 1.000, 0.661),
	ConcreteFloor = prop("rbxassetid://122093568483513", "rbxassetid://132210085782663", 1.438, 1.000, 0.512),
	HungTools = prop("rbxassetid://137801002725741", "rbxassetid://114893461231752", 1.613, 1.513, 0.600),
	Lantern = prop("rbxassetid://117371342269426", "rbxassetid://103361847724409", 1.991, 3.000, 1.769),

	-- The stock on the shed shelf.
	Sack = prop("rbxassetid://138022973254032", "rbxassetid://92817985554289", 2.943, 4.000, 3.277),
	LeafBlower = prop("rbxassetid://120198329733477", "rbxassetid://127839085444983", 2.114, 3.000, 4.231),
}

Props.catalogue = catalogue

--- The prop by name, or nil when nothing in the catalogue answers to it.
function Props.get(name: string): Prop?
	return catalogue[name]
end

return Props
