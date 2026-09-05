--!strict
--[[
	Palette — the autumn look, in one place.

	Colours sampled from reference screenshots of the genre this game sits in:
	a hard amber sky, vivid yellow-green lawn, cream lap siding with teal trim,
	tan picket fencing over red brick, and leaves in three golds.

	Kept as plain RGB triples so config modules stay free of Roblox globals; call
	`Palette.color` to turn one into a Color3.
]]

local Types = require(script.Parent.Parent.Types)

local Palette = {}

export type Rgb = Types.Color3Like

local function rgb(r: number, g: number, b: number): Rgb
	return { r / 255, g / 255, b / 255 }
end

Palette.rgb = rgb

--------------------------------------------------------------------
-- Sky and light
--------------------------------------------------------------------

Palette.sky = {
	--- Warm haze that sits over everything and does most of the work.
	fog = rgb(252, 186, 96),
	ambient = rgb(126, 96, 66),
	--[[
		Daylight, warm but not orange.

		These two were a strong orange, on the theory that an autumn afternoon
		is orange light. It is, but a saturated green lit by strongly orange
		light is not a green lawn, it is a khaki one: every stretch of grass in
		direct sun came out the colour of dead straw, and only the parts in
		shadow looked like grass at all. The warmth lives in the haze and the
		sky now, where it belongs, and the light itself is close enough to
		neutral to leave the palette's own colours recognisable.
	]]
	outdoorAmbient = rgb(150, 148, 136),
	--- Late-afternoon sun: warm, but not so warm it repaints the lawn.
	tint = rgb(240, 228, 208),
	cloud = rgb(255, 250, 242),
}

--------------------------------------------------------------------
-- Debris
--------------------------------------------------------------------

--[[
	Leaves are drawn from these at random so a drift is never one flat colour.

	Weighted towards orange with golds either side and a few deep reds, which is
	what a real drift looks like and what stops a carpet of them reading as a
	single painted surface.
]]
Palette.leaves = {
	rgb(255, 206, 74),
	rgb(252, 176, 46),
	rgb(248, 148, 36),
	rgb(240, 124, 30),
	rgb(228, 96, 34),
	rgb(255, 228, 120),
	rgb(246, 160, 40),
	--- The occasional red one, scattered through the reference's yards.
	rgb(196, 58, 38),
	rgb(214, 76, 40),
}

--- Underside of a leaf, used on the ones that land face down.
Palette.leafPale = rgb(252, 214, 142)

--[[
	The average of the nine shades above.

	Used to work out what a drift reads as from across a property. Far enough
	away to be a surface rather than separate leaves, a leafy lot is not the
	colour of a leaf — it is ground with litter on it, so the renderer carries
	its world's own ground colour a short way toward this one rather than
	painting the distance in a leaf colour. Doing the latter put a band of
	flat, fully saturated gold across the middle of every property: a solid
	sheet with straight chunk edges, looking nothing like the drift you walk
	into when you reach it.

	The blend has to start from the ground rather than from grass, because not
	every lot is a lawn. The Gas Station is a stone yard, and a green-derived
	drift laid over dark stone is just as wrong as gold over grass.
]]
Palette.leafAverage = rgb(237, 141, 51)

Palette.grass = {
	blade = rgb(142, 194, 76),
	bladeDark = rgb(108, 162, 56),
	cut = rgb(160, 206, 92),
}

Palette.weeds = rgb(154, 178, 62)
Palette.hedge = rgb(58, 128, 54)
Palette.sticks = rgb(122, 84, 50)
Palette.log = rgb(134, 92, 54)
Palette.chips = rgb(186, 146, 92)

--------------------------------------------------------------------
-- Ground
--------------------------------------------------------------------

Palette.ground = {
	lawn = rgb(138, 188, 74),
	lawnDark = rgb(112, 160, 58),
	--- Irregular flagstone, the surface most of the reference is paved with.
	stone = rgb(158, 142, 122),
	stoneDark = rgb(132, 116, 98),
	path = rgb(178, 162, 140),
	road = rgb(84, 80, 82),
	soil = rgb(112, 84, 58),
}

--------------------------------------------------------------------
-- Buildings
--------------------------------------------------------------------

Palette.house = {
	--- Horizontal lap siding.
	siding = rgb(232, 222, 196),
	sidingShade = rgb(212, 200, 172),
	--- The teal roof trim that gives the reference its identity.
	trim = rgb(74, 156, 142),
	trimDark = rgb(56, 122, 112),
	roof = rgb(124, 82, 60),
	roofDark = rgb(96, 62, 46),
	door = rgb(122, 74, 48),
	window = rgb(140, 196, 210),
	garage = rgb(236, 230, 214),
	garageLine = rgb(206, 198, 180),
	porch = rgb(154, 110, 64),
	porchRail = rgb(198, 154, 96),
	column = rgb(238, 230, 210),
	brick = rgb(150, 88, 70),
	brickDark = rgb(124, 70, 56),
}

--[[
	The Mansion, which is a different building and not a bigger one.

	Every colour above belongs to the first property: cream lap siding, a teal
	eaves band, a brown shingle roof, a wooden porch. The Mansion was built by
	the same builder out of the same palette, so it arrived as The House at
	twice the size — reported as "the mansion looks identical to the first
	level".

	An estate is stone, lead and iron. Pale ashlar with lighter quoins at the
	corners, a grey slate roof rather than a brown one, gutters and a cornice
	in weathered lead, black railings, and a gravel carriage drive instead of
	a flagstone path. The planting is dark clipped yew instead of the bright
	garden hedge, because a parterre is a shape cut out of something almost
	black.
]]
Palette.estate = {
	stone = rgb(224, 216, 196),
	stoneShade = rgb(198, 188, 166),
	--- The dressed corners and window surrounds, a shade lighter than the wall.
	quoin = rgb(240, 234, 218),
	roof = rgb(78, 82, 92),
	roofDark = rgb(58, 62, 72),
	--- Cornice, gutters, the capping on the parapet.
	lead = rgb(118, 124, 134),
	--- Railings, gates and lamp standards.
	iron = rgb(36, 38, 42),
	gravel = rgb(202, 190, 168),
	gravelDark = rgb(176, 164, 142),
	--- Clipped yew, much darker than a garden hedge.
	yew = rgb(38, 76, 50),
	door = rgb(58, 46, 40),
	window = rgb(150, 190, 206),
	water = rgb(120, 172, 194),
	--- The glazing on the orangery, and the only translucent surface in the
	--- game that is meant to be looked through rather than at.
	glass = rgb(196, 226, 226),
}

--- The tennis court, which is the one hard-surfaced place you mow.
Palette.court = {
	tarmac = rgb(58, 104, 148),
	apron = rgb(126, 96, 82),
	line = rgb(244, 244, 238),
	net = rgb(30, 32, 36),
	mesh = rgb(96, 112, 108),
}

Palette.fence = {
	picket = rgb(214, 168, 108),
	picketShade = rgb(184, 138, 84),
	rail = rgb(168, 122, 74),
	lattice = rgb(200, 156, 100),
}

Palette.props = {
	bin = rgb(52, 56, 58),
	binLid = rgb(64, 122, 62),
	crate = rgb(178, 134, 84),
	planter = rgb(146, 92, 66),
	chair = rgb(226, 222, 212),
	barrel = rgb(102, 112, 118),
	shed = rgb(226, 214, 186),
	pool = rgb(78, 168, 214),
}

--[[
	The gas station's livery: cream body, a red fascia band, storefront glass.

	Red and cream rather than the house palette, because a filling station is
	commercial architecture — it should read as a different kind of building
	from across the lot, and the fascia stripe is the thing that says so.
]]
Palette.station = {
	body = rgb(242, 238, 228),
	fascia = rgb(206, 56, 44),
	trim = rgb(248, 246, 240),
	glass = rgb(148, 202, 218),
	dark = rgb(56, 58, 60),
}

Palette.tree = {
	trunk = rgb(116, 80, 52),
	canopy = {
		rgb(246, 168, 44),
		rgb(232, 132, 36),
		rgb(252, 198, 62),
	},
}

--------------------------------------------------------------------
-- Interface
--------------------------------------------------------------------

Palette.ui = {
	text = rgb(255, 255, 255),
	outline = rgb(24, 18, 10),
	cash = rgb(126, 226, 108),
	tips = rgb(255, 206, 74),
	warn = rgb(255, 148, 52),
	danger = rgb(238, 84, 74),
	panel = rgb(38, 28, 20),
	panelLight = rgb(62, 46, 32),
	accent = rgb(252, 176, 46),
	progress = rgb(255, 232, 224),
	--- The outline on the pile a pickup tool is pointed at. Deliberately white
	--- rather than the amber accent: it has to read against leaves in every
	--- shade the autumn palette runs to, and only white does.
	target = rgb(255, 255, 255),
	--- The blue underline on the selected hotbar slot.
	selected = rgb(92, 178, 255),
}

--------------------------------------------------------------------

function Palette.color(value: Rgb): Color3
	return Color3.new(value[1], value[2], value[3])
end

--- A deterministic-ish pick from a list, for scattering variation.
function Palette.pick(list: { Rgb }, roll: number): Rgb
	local index = (math.floor(roll * #list) % #list) + 1
	return list[index]
end

return Palette
