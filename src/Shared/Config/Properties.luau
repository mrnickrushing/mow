--!strict
--[[
	Properties — the six maps in the rotation, defined as data.

	Nothing here is hand-built in Studio: WorldService reads these tables and
	generates the ground, house, shed, trailer, fences and debris at runtime, so
	tuning a yard means editing numbers rather than dragging parts.

	Every property is a variation on the same suburban lot, so `lot()` builds the
	zone layout from a handful of parameters and each map stays readable.
]]

local Debris = require(script.Parent.Debris)
local Types = require(script.Parent.Parent.Types)

local Properties = {}

--- Grass at the given height band, the staple of every zone.
local function grass(heightMin: number, heightMax: number): Types.FillEntry
	return { debris = Debris.Grass, weight = 1, heightMin = heightMin, heightMax = heightMax }
end

local function mix(debris: number, weight: number, heightMin: number, heightMax: number): Types.FillEntry
	return { debris = debris, weight = weight, heightMin = heightMin, heightMax = heightMax }
end

export type LotOptions = {
	id: string,
	name: string,
	tagline: string,
	unlockLifetimeCash: number,
	--- Multiplies the base 96x96 tile lot.
	scale: number,
	roundSeconds: number,
	--- Scales both zone unlock prices and debris payout on this property, so
	--- income and costs stay in step as the rotation climbs.
	economyScale: number,
	--- Fraction of tiles in a zone that carry debris.
	density: number,
	baseGround: Types.Color3Like,
	--- Extra fill entries mixed into the later zones.
	orchardMix: { Types.FillEntry }?,
	backLotMix: { Types.FillEntry }?,
	trees: number,
	stumps: number,
}

--[[
	Builds one suburban lot.

	The layout is fixed in proportion and scaled up per property: road along the
	south edge with the trailer at the curb, house in the middle, and six zones
	fanning out from the front yard to the overgrown back lot. Zone prices climb
	steeply enough that each unlock is a genuine goal.
]]
--- Highest fraction of a zone's tiles that may carry debris. Bare ground
--- between the clumps is what makes a cut lawn read as cut.
local MAX_DENSITY = 0.98

local function density(base: number, multiplier: number): number
	return math.min(base * multiplier, MAX_DENSITY)
end

local function lot(o: LotOptions): Types.PropertyDef
	local s = o.scale
	local function n(v: number): number
		return math.floor(v * s + 0.5)
	end
	local function price(v: number): number
		return math.floor(v * o.economyScale)
	end

	local width, depth = n(96), n(96)

	local zones: { Types.ZoneDef } = {
		{
			id = "front_yard",
			name = "Front Yard",
			cost = 0,
			rect = { x = n(24), z = n(8), w = n(48), d = n(24) },
			density = math.min(o.density, MAX_DENSITY),
			fill = { grass(1, 2) },
		},
		{
			id = "driveway",
			name = "Driveway Strip",
			cost = price(500),
			rect = { x = n(4), z = n(8), w = n(18), d = n(24) },
			density = math.min(o.density, MAX_DENSITY),
			fill = { grass(1, 2), mix(Debris.Leaves, 0.7, 1, 2) },
		},
		{
			id = "backyard",
			name = "Backyard",
			cost = price(3000),
			rect = { x = n(24), z = n(56), w = n(48), d = n(24) },
			density = density(o.density, 1.05),
			fill = { grass(2, 3), mix(Debris.Weeds, 0.25, 1, 2) },
		},
		{
			id = "side_garden",
			name = "Side Garden",
			cost = price(12000),
			rect = { x = n(74), z = n(8), w = n(18), d = n(46) },
			density = density(o.density, 1.1),
			fill = { grass(2, 3), mix(Debris.Weeds, 0.5, 2, 3), mix(Debris.Hedge, 0.4, 2, 3) },
		},
		{
			id = "orchard",
			name = "Orchard",
			cost = price(50000),
			rect = { x = n(4), z = n(34), w = n(18), d = n(46) },
			density = density(o.density, 1.15),
			fill = o.orchardMix or {
				grass(2, 3),
				mix(Debris.Leaves, 1.2, 2, 3),
				mix(Debris.Sticks, 0.5, 1, 2),
			},
			trees = math.floor(o.trees * 0.4),
			hazards = { "sprinkler", "wasps" },
		},
		{
			id = "back_forty",
			name = "The Back Forty",
			cost = price(250000),
			rect = { x = n(4), z = n(82), w = n(88), d = n(12) },
			density = density(o.density, 1.25),
			fill = o.backLotMix or {
				grass(3, 3),
				mix(Debris.Weeds, 0.8, 3, 3),
				mix(Debris.Sticks, 0.7, 2, 3),
			},
			trees = math.ceil(o.trees * 0.6),
			stumps = o.stumps,
			hazards = { "dog" },
		},
	}

	return {
		id = o.id,
		name = o.name,
		tagline = o.tagline,
		unlockLifetimeCash = o.unlockLifetimeCash,
		gridWidth = width,
		gridDepth = depth,
		roundSeconds = o.roundSeconds,
		payoutMultiplier = o.economyScale,
		baseGround = o.baseGround,
		zones = zones,
		houseRect = { x = n(28), z = n(34), w = n(40), d = n(20) },
		shed = { x = n(78), z = n(60) },
		trailer = { x = n(48), z = n(4) },
		spawn = { x = n(48), z = n(2) },
	}
end

local list: { Types.PropertyDef } = {
	lot({
		id = "starter_house",
		name = "Starter House",
		tagline = "Somebody has to cut it. Might as well be you.",
		unlockLifetimeCash = 0,
		scale = 1,
		roundSeconds = 1500,
		economyScale = 1,
		density = 0.82,
		baseGround = { 0.31, 0.45, 0.22 },
		trees = 6,
		stumps = 2,
	}),
	lot({
		id = "corner_lot",
		name = "Corner Lot",
		tagline = "Two street frontages. Twice the judgement from neighbours.",
		unlockLifetimeCash = 60000,
		scale = 1.25,
		roundSeconds = 1800,
		economyScale = 5,
		density = 0.85,
		baseGround = { 0.29, 0.44, 0.21 },
		trees = 10,
		stumps = 3,
	}),
	lot({
		id = "the_ranch",
		name = "The Ranch",
		tagline = "Flat, endless, and somehow all of it needs cutting.",
		unlockLifetimeCash = 700000,
		scale = 1.6,
		roundSeconds = 2100,
		economyScale = 26,
		density = 0.88,
		baseGround = { 0.36, 0.46, 0.20 },
		trees = 14,
		stumps = 5,
	}),
	lot({
		id = "orchard_estate",
		name = "The Orchard Estate",
		tagline = "Every tree drops leaves. Every single one.",
		unlockLifetimeCash = 5000000,
		scale = 2,
		roundSeconds = 2400,
		economyScale = 140,
		density = 0.9,
		baseGround = { 0.27, 0.42, 0.19 },
		orchardMix = {
			grass(3, 3),
			mix(Debris.Leaves, 2.2, 3, 3),
			mix(Debris.Sticks, 1.0, 2, 3),
		},
		trees = 28,
		stumps = 8,
	}),
	lot({
		id = "riverside_golf",
		name = "Riverside Golf Course",
		tagline = "Stripes here are not optional. The members are watching.",
		unlockLifetimeCash = 35000000,
		scale = 2.5,
		roundSeconds = 2700,
		economyScale = 750,
		density = 0.93,
		baseGround = { 0.24, 0.50, 0.22 },
		trees = 34,
		stumps = 10,
	}),
	lot({
		id = "overgrown_manor",
		name = "The Overgrown Manor",
		tagline = "Nobody has touched it in years. It shows.",
		unlockLifetimeCash = 150000000,
		scale = 3,
		roundSeconds = 3600,
		economyScale = 4200,
		density = 0.97,
		baseGround = { 0.22, 0.38, 0.17 },
		orchardMix = {
			grass(3, 3),
			mix(Debris.Leaves, 2.0, 3, 3),
			mix(Debris.Sticks, 1.6, 3, 3),
			mix(Debris.Weeds, 1.2, 3, 3),
		},
		backLotMix = {
			grass(3, 3),
			mix(Debris.Weeds, 1.6, 3, 3),
			mix(Debris.Sticks, 1.4, 3, 3),
			mix(Debris.Hedge, 0.8, 3, 3),
		},
		trees = 52,
		stumps = 18,
	}),
}

Properties.list = list

local byId: { [string]: Types.PropertyDef } = {}
for _, property in list do
	byId[property.id] = property
end
Properties.byId = byId

Properties.STARTER_ID = "starter_house"

function Properties.get(id: string): Types.PropertyDef?
	return byId[id]
end

function Properties.expect(id: string): Types.PropertyDef
	local property = byId[id]
	assert(property, `unknown property id {id}`)
	return property
end

--- Zone definition within a property, or nil.
function Properties.zone(property: Types.PropertyDef, zoneId: string): Types.ZoneDef?
	for _, zone in property.zones do
		if zone.id == zoneId then
			return zone
		end
	end
	return nil
end

--- The zone whose rect contains a tile, or nil for ground outside every zone.
function Properties.zoneAt(property: Types.PropertyDef, tx: number, tz: number): Types.ZoneDef?
	for _, zone in property.zones do
		local r = zone.rect
		if tx >= r.x and tz >= r.z and tx < r.x + r.w and tz < r.z + r.d then
			return zone
		end
	end
	return nil
end

--- Properties the player has earned the right to see in the rotation.
function Properties.unlockedFor(lifetimeCash: number): { Types.PropertyDef }
	local unlocked = {}
	for _, property in list do
		if lifetimeCash >= property.unlockLifetimeCash then
			table.insert(unlocked, property)
		end
	end
	return unlocked
end

return Properties
