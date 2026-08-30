--!strict
--[[
	Types — shared type definitions for "Mow all the lawns!".

	Kept dependency-free so that pure-logic modules (Grid, ChunkCodec, Balance)
	can be unit tested outside of Roblox.
]]

export type TileIndex = number

--- A rectangle in tile space. `x`/`z` are the minimum (inclusive) tile coords.
export type Rect = {
	x: number,
	z: number,
	w: number,
	d: number,
}

--- One entry in a zone's debris distribution.
export type FillEntry = {
	debris: number,
	weight: number,
	heightMin: number,
	heightMax: number,
}

--- How a zone is opened.
--- `cash` is bought at the shed; `completion` opens free once another zone is
--- finished; `button` opens by finding a switch hidden elsewhere on the map.
export type ZoneUnlock = "cash" | "completion" | "button"

--- Structures a zone generates around itself.
export type ZoneKind = "open" | "room" | "pool" | "maze" | "roof"

export type ZoneDef = {
	id: string,
	name: string,
	cost: number,
	rect: Rect,
	density: number,
	fill: { FillEntry },
	trees: number?,
	stumps: number?,
	hazards: { string }?,
	--- Height of this zone's floor above GROUND_Y. Lets a rooftop sit over the
	--- house and a basement sit under the lawn while the grid stays flat: zones
	--- never overlap in X/Z, so one elevation per zone is enough.
	elevation: number?,
	unlock: ZoneUnlock?,
	--- For `completion` unlocks, the zone that has to be finished first.
	requires: string?,
	--- For `button` unlocks, the zone the switch is hidden in.
	buttonIn: string?,
	kind: ZoneKind?,
	--- Props scattered through the zone for debris to hide against.
	clutter: number?,
}

export type PropertyDef = {
	id: string,
	name: string,
	tagline: string,
	unlockLifetimeCash: number,
	gridWidth: number,
	gridDepth: number,
	roundSeconds: number,
	--- Multiplies every debris value earned on this property.
	payoutMultiplier: number,
	baseGround: Color3Like,
	zones: { ZoneDef },
	shed: { x: number, z: number },
	trailer: { x: number, z: number },
	spawn: { x: number, z: number },
	houseRect: Rect?,
	--- `house` properties generate the detailed residential treatment; `lot`
	--- properties are the big open maps the wide-deck mowers are built for.
	style: ("house" | "lot")?,
}

--- Plain RGB triple so config modules never need the Roblox `Color3` global.
export type Color3Like = { number }

export type ToolCategory =
	"Shears"
	| "Rake"
	| "Mower"
	| "Trimmer"
	| "Blower"
	| "HedgeTrimmer"
	| "Saw"
	| "Chainsaw"
	| "Grinder"
	| "Chipper"

export type ToolDef = {
	id: string,
	name: string,
	tier: number,
	category: ToolCategory,
	cost: number,
	currency: "Cash" | "Tips",
	--- Swath width in tiles.
	deck: number,
	--- Height levels removed per pass.
	power: number,
	--- Passes per second.
	rate: number,
	--- Swath length ahead of the player, in studs.
	reach: number,
	--- Debris ids this tool can clear.
	clears: { number },
	--- Maximum debris height this tool can bite into (overgrowth gate).
	maxHeight: number,
	--- Fuel burned per second while active. 0 = manual tool.
	fuelBurn: number,
	--- Set for rideable tools.
	vehicle: VehicleStats?,
	description: string,
}

export type VehicleStats = {
	speed: number,
	turnSpeed: number,
	seatOffset: number,
}

export type UpgradeDef = {
	id: string,
	name: string,
	description: string,
	maxLevel: number,
	baseCost: number,
	costGrowth: number,
	--- Value at level 0.
	base: number,
	--- Multiplicative or additive step per level.
	step: number,
	mode: "add" | "mul",
	suffix: string?,
}

export type DebrisDef = {
	id: number,
	key: string,
	name: string,
	--- Cash per unit collected.
	value: number,
	--- Bag units consumed per unit collected.
	weight: number,
	--- Units yielded per height level removed.
	unitsPerLevel: number,
	color: Color3Like,
	cutColor: Color3Like,
	--- Tool categories able to clear it.
	tools: { ToolCategory },
}

export type PlayerStats = {
	bagCapacity: number,
	cutRate: number,
	yieldMultiplier: number,
	walkSpeed: number,
	cashMultiplier: number,
	fuelCapacity: number,
	dumpRadius: number,
}

export type MowIntent = {
	position: Vector3,
	look: Vector3,
	toolId: string,
}

return {}
