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
	--[[
		A bush, which the bush was not.

		The old one was a cylinder with a leaf texture wrapped round it — eight
		studs tall, flat topped, and identical however it was turned. A hedge
		is a row of these, so every hedge in the game was a run of matching
		green cylinders that read as a chequerboard from any distance, and the
		tennis court's chain-link was one of them squashed to two fifths of a
		stud thick. This one is a dome of clustered foliage, which is what a
		clipped shrub actually looks like.
	]]
	Bush = prop("rbxassetid://107891693819793", "rbxassetid://78295314342685", 3.327, 3.200, 3.303),
	Hedge = prop("rbxassetid://107891693819793", "rbxassetid://78295314342685", 3.327, 3.200, 3.303),
	Tree = prop("rbxassetid://131361580865388", "rbxassetid://92687150630349", 15.156, 22.768, 16.000),
	Stump = prop("rbxassetid://132967367565646", "rbxassetid://88604401051093", 1.683, 2.500, 1.560),
	Log = prop("rbxassetid://135854002039541", "rbxassetid://136724661905485", 2.500, 0.985, 1.650),
	LeafPile = prop("rbxassetid://130494819737391", "rbxassetid://97469677584763", 4.596, 2.000, 4.592),

	-- Structures.
	Fence = prop("rbxassetid://109120828950770", "rbxassetid://99346791051845", 5.272, 3.059, 0.600),
	Shed = prop("rbxassetid://136505549556407", "rbxassetid://130296685263073", 15.868, 18.000, 15.692),
	--[[
		The trailer you dump your bag into, which is the most-visited object in
		the game and was a green wooden hand-cart — a tub on cart wheels, drawn
		twenty-four studs wide with its long axis turned sideways, so it stood
		taller than the gas pumps and read as furniture from a cartoon quarry.
		This one is the thing a landscaping crew actually tows: a flatbed on
		tandem rubber wheels with side rails and an a-frame hitch.
	]]
	Trailer = prop("rbxassetid://135220375508208", "rbxassetid://97134128130312", 6.834, 4.200, 10.387),

	-- The gas station's own furniture.
	GasPump = prop("rbxassetid://77359286982223", "rbxassetid://129997331021782", 2.000, 3.827, 1.000),
	--- A white winged horse, which stands on a red disc to make the station's
	--- emblem. Generated as a badge and arrived as the horse alone, which is
	--- better: the disc is two cylinders, and the horse can stand proud of it.
	PonyEmblem = prop("rbxassetid://105093577196676", "rbxassetid://100374841746838", 0.468, 0.539, 0.700),

	-- Things that move or matter.
	RidingMower = prop("rbxassetid://89706697093178", "rbxassetid://120136128501167", 5.476, 6.000, 9.364),
	Dog = prop("rbxassetid://74175582988973", "rbxassetid://77296052752514", 1.527, 4.000, 3.141),
	Sprinkler = prop("rbxassetid://133265868962502", "rbxassetid://140459804380273", 1.568, 2.000, 1.575),
	WaspNest = prop("rbxassetid://109192227690970", "rbxassetid://91421064853539", 2.784, 4.000, 2.774),
	GoldenBlade = prop("rbxassetid://76860455179857", "rbxassetid://118765026020204", 0.993, 1.974, 1.000),

	--[[
		Built structure: the pieces the house, shed and gates are assembled
		from.

		There were four more here — lap siding, a brick course, a concrete
		panel and a roof shingle — and every one of them was a picture of a
		surface rather than a thing. A picture of a surface is the one kind of
		model that cannot be used at world scale: a mesh texture stretches when
		the mesh is scaled, it does not repeat, so a shingle panel a stud
		across pulled over a sixty by a hundred and eighty stud roof came out
		as a chequerboard you could see from the road, and the lap siding over
		a hundred and eighty stud frontage came out as five flat bands.

		Every surface that size is a plain part with a Roblox material now,
		which does tile. The models are gone rather than left unused, because
		an asset that only works below about four times its own size is a trap
		for whoever reaches for it next.
	]]
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

	-- What the lawn itself is made of, scattered a few clumps to a tile.
	--[[
		Grass, with nothing underneath it.

		The old clump had a square patch of ground modelled into it, four studs
		across — exactly one tile. The renderer drew one per tile, so the lawn
		came out as a grid of slightly lighter squares you could count from the
		porch, and scattering the clumps only turned the grid into a square
		dragged along behind every tuft. This one is blades and nothing else,
		so what shows between them is the lawn.
	]]
	GrassTuft = prop("rbxassetid://138521272241538", "rbxassetid://102784417042984", 2.000, 1.399, 1.933),
	Weeds = prop("rbxassetid://97566895867036", "rbxassetid://100631337116622", 3.995, 3.809, 4.000),
	Twigs = prop("rbxassetid://131001130360981", "rbxassetid://135819322286106", 2.061, 2.000, 2.112),

	--[[
		The two leaves a drift is made of.

		A raked pile is thousands of these on screen at once, so they were the
		last thing still drawn with built-in shapes — a sphere squashed flat and
		a prism, which read as orange pebbles and orange wedges rather than as
		leaves. Two shapes rather than one because a drift of a single repeated
		leaf tiles visibly.

		Note the native sizes disagree about which way is up: the maple is a
		standing card (thin in Z) and the oak is already lying down (thin in Y).
		The renderer works out which from the shape itself rather than carrying
		a flag, so a leaf swapped in later lands the right way up on its own.
	]]
	LeafMaple = prop("rbxassetid://71916107034086", "rbxassetid://74826574473670", 0.277, 0.300, 0.018),
	LeafOak = prop("rbxassetid://73631604724135", "rbxassetid://84336160333767", 0.189, 0.064, 0.300),

	-- Ground and roofing, the surfaces underfoot and overhead.
	Paving = prop("rbxassetid://118911737218481", "rbxassetid://75203797606065", 2.483, 0.500, 2.503),
	HungTools = prop("rbxassetid://137801002725741", "rbxassetid://114893461231752", 1.613, 1.513, 0.600),
	Lantern = prop("rbxassetid://117371342269426", "rbxassetid://103361847724409", 1.991, 3.000, 1.769),

	-- What you see in your own hands, which is on screen every frame.
	Gloves = prop("rbxassetid://102351792013112", "rbxassetid://121367423728441", 0.557, 0.500, 0.213),
	RakeTool = prop("rbxassetid://136422927727853", "rbxassetid://88404546052055", 0.612, 0.400, 1.276),
	Handlebar = prop("rbxassetid://82490801193149", "rbxassetid://85871570751435", 0.625, 1.000, 1.138),
	TrimmerTool = prop("rbxassetid://71503917518651", "rbxassetid://104755838161955", 0.355, 0.800, 0.643),
	SawTool = prop("rbxassetid://109634814327719", "rbxassetid://117884093500395", 0.781, 0.900, 1.471),
	HedgeTool = prop("rbxassetid://100172995462295", "rbxassetid://97933613185397", 0.143, 0.800, 0.892),
	GrinderTool = prop("rbxassetid://130280705075193", "rbxassetid://74077511096748", 1.527, 1.200, 1.445),
	ChipperTool = prop("rbxassetid://84533763020814", "rbxassetid://110674468060386", 0.779, 1.400, 0.782),

	--[[
		The icons, which are models like everything else.

		The whole interface was emoji: a glove for bare hands, a broom for the
		rake, a tractor for the mower, a coin for your money, a padlock on
		anything you had not unlocked. An emoji is a font glyph, so it is drawn
		by whatever the player's device happens to ship — the same screen is a
		different picture on a phone, a console and a PC, and none of them are
		the game's own art. These are, and they are shown in viewport frames, so
		the icon for a tool is the tool.
	]]
	Coin = prop("rbxassetid://76322956476502", "rbxassetid://105081756236173", 0.908, 0.886, 0.300),
	Journal = prop("rbxassetid://87614061994120", "rbxassetid://79358286968081", 0.636, 0.887, 0.500),
	Padlock = prop("rbxassetid://130942971715023", "rbxassetid://132672323950414", 1.025, 1.671, 0.600),
	Shears = prop("rbxassetid://71636174258723", "rbxassetid://127073519402737", 1.200, 1.873, 0.171),
	MapPin = prop("rbxassetid://133341600847886", "rbxassetid://94199733035450", 1.365, 2.000, 1.350),
	Toolbox = prop("rbxassetid://112706816871275", "rbxassetid://127876097432280", 1.995, 1.600, 1.169),
	UpArrow = prop("rbxassetid://128060605098219", "rbxassetid://111066637200078", 1.178, 1.403, 0.500),
	Scroll = prop("rbxassetid://118113022200836", "rbxassetid://134224931906361", 1.510, 1.388, 1.000),
	QuestionSign = prop("rbxassetid://90537364692984", "rbxassetid://134330319773516", 1.800, 2.076, 0.388),
	Tick = prop("rbxassetid://125217432482528", "rbxassetid://102708394051568", 0.189, 0.390, 0.400),
	Cross = prop("rbxassetid://99413284614654", "rbxassetid://71908766239251", 1.574, 1.575, 0.400),

	-- The stock on the shed shelf.
	Sack = prop("rbxassetid://138022973254032", "rbxassetid://92817985554289", 2.943, 4.000, 3.277),
	LeafBlower = prop("rbxassetid://120198329733477", "rbxassetid://127839085444983", 2.114, 3.000, 4.231),
}

Props.catalogue = catalogue

--[[
	The model that stands for a kind of tool, wherever one has to be shown.

	The hotbar, the badge on the HUD and every upgrade tile in the book all
	need a picture of a tool, and all three used to keep their own list of
	emoji — which is how the hotbar came to show a household broom for the rake
	while the HUD showed a leaf. One list, and it names models.
]]
local TOOL_ICON: { [string]: string } = {
	Hand = "Gloves",
	Shears = "Shears",
	Rake = "RakeTool",
	Mower = "RidingMower",
	Trimmer = "TrimmerTool",
	Blower = "LeafBlower",
	HedgeTrimmer = "HedgeTool",
	Saw = "SawTool",
	Chainsaw = "SawTool",
	Grinder = "GrinderTool",
	Chipper = "ChipperTool",
}

--- Shown for a tool category nothing has been drawn for yet, so adding one
--- cannot leave a blank slot in the bar.
Props.FALLBACK_TOOL_ICON = "Toolbox"

--- The catalogue name of the model for a tool category.
function Props.forToolCategory(category: string): string
	return TOOL_ICON[category] or Props.FALLBACK_TOOL_ICON
end

--- The prop by name, or nil when nothing in the catalogue answers to it.
function Props.get(name: string): Prop?
	return catalogue[name]
end

return Props
