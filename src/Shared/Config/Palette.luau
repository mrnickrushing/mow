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
	outdoorAmbient = rgb(196, 148, 96),
	--- Late-afternoon sun, low and orange.
	tint = rgb(255, 214, 150),
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
	What a drift of leaves reads as from across a property.

	Far enough away to be a surface rather than separate leaves, a leafy lawn
	is not the colour of a leaf. It is ground with litter on it: roughly half
	the lawn's green, half the average of the nine shades above. Painting the
	distance in a leaf colour instead put a band of flat, fully saturated gold
	across the middle of every property — a solid sheet, with straight chunk
	edges, that looked nothing like the drift you walk into when you reach it.
]]
Palette.leafDrift = rgb(173, 172, 66)

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
