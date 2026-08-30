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

--- How a section is opened.
--- `start` is where the run begins; `completion` opens when the section it
--- names is fully cleared; `button` opens by finding a switch hidden elsewhere;
--- `cash` is the rare one you simply buy.
export type ZoneUnlock = "start" | "completion" | "button" | "cash"

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
	--[[
		Waves needed to finish this section.

		`nil` means one per player: clear it, it fills back up, and it is only
		done when everyone's worth of work has been done. A number pins it
		regardless of how many are playing.
	]]
	waves: number?,
	--- Off the critical path: the exit does not wait for it.
	optional: boolean?,
}

--[[
	A world is a chain of sections you clear in order.

	Not a sandbox: you start at the first section with nothing, each one you
	finish opens the gate to the next, and clearing the last opens the way out.
	Beating a world is a real ending, and the clock makes it a race.
]]
export type WorldDef = {
	id: string,
	name: string,
	tagline: string,
	difficulty: string,
	--- Worlds beaten before this one appears in the lobby.
	requiresWorld: string?,
	gridWidth: number,
	gridDepth: number,
	--- Seconds on the clock for the whole run.
	runSeconds: number,
	--- Multiplies every debris value earned here, so later worlds reach further
	--- up the tool ladder within a single run.
	payoutMultiplier: number,
	baseGround: Color3Like,
	--- Ordered. The first is where the run starts.
	sections: { ZoneDef },
	shed: { x: number, z: number },
	trailer: { x: number, z: number },
	spawn: { x: number, z: number },
	--- Where the grate opens once the last section is clear.
	exit: { x: number, z: number },
	houseRect: Rect?,
	style: ("house" | "lot")?,
}

--- Plain RGB triple so config modules never need the Roblox `Color3` global.
export type Color3Like = { number }

export type ToolCategory =
	"Hand"
	| "Shears"
	| "Rake"
	| "Mower"
	| "Trimmer"
	| "Blower"
	| "HedgeTrimmer"
	| "Saw"
	| "Chainsaw"
	| "Grinder"
	| "Chipper"

--[[
	How a tool is used.

	`pickup` targets one thing at a time — you look at a leaf, it lights up, you
	take it. `swath` sweeps everything in a rectangle ahead of you. The first is
	what bare hands and a rake do; the second is what a mower or a blower does,
	and the jump between them is most of what buying a blower feels like.
]]
export type ToolMode = "pickup" | "swath"

export type ToolDef = {
	id: string,
	name: string,
	tier: number,
	category: ToolCategory,
	mode: ToolMode?,
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
	--- Held rather than tapped: the blower runs until you switch it off.
	toggle: boolean?,
	description: string,
	--- Robux to rent the tool for the current run only.
	robuxOnce: number?,
	--- Robux to keep it across every future run.
	robuxPermanent: number?,
	--- Struck-through "was" price shown beside the permanent option.
	robuxWas: number?,
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
