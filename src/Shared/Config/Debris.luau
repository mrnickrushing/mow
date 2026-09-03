--!strict
--[[
	Debris — the things that sit on a tile and can be cleared.

	A tile stores a debris id and a height (0..MAX_HEIGHT). Clearing one height
	level yields `unitsPerLevel` units; each unit is worth `value` cash and takes
	`weight` units of bag space.

	The value/weight split is deliberate: logs are heavy but pay far better per
	unit of bag, so hauling wood is a real decision rather than a strict upgrade.

	Ids are stored in three bits on the wire, so 0..7 only.
]]

local Palette = require(script.Parent.Palette)
local Types = require(script.Parent.Parent.Types)

local Debris = {}

Debris.Empty = 0
Debris.Grass = 1
Debris.Leaves = 2
Debris.Weeds = 3
Debris.Hedge = 4
Debris.Sticks = 5

--- Yielded by trees and stumps, which are Instances rather than tiles.
Debris.Log = 6
Debris.Chips = 7

local defs: { [number]: Types.DebrisDef } = {
	[Debris.Empty] = {
		id = Debris.Empty,
		key = "Empty",
		name = "Bare Ground",
		value = 0,
		weight = 0,
		unitsPerLevel = 0,
		color = Palette.ground.soil,
		cutColor = Palette.ground.soil,
		tools = {},
	},
	[Debris.Grass] = {
		id = Debris.Grass,
		key = "Grass",
		name = "Grass Clippings",
		value = 0.02,
		weight = 1,
		unitsPerLevel = 4,
		color = Palette.grass.blade,
		cutColor = Palette.grass.cut,
		tools = { "Hand", "Shears", "Mower", "Trimmer" },
	},
	[Debris.Leaves] = {
		id = Debris.Leaves,
		key = "Leaves",
		name = "Leaves",
		value = 0.02,
		weight = 1,
		unitsPerLevel = 4,
		color = Palette.leaves[2],
		cutColor = Palette.grass.cut,
		tools = { "Hand", "Rake", "Blower" },
	},
	[Debris.Weeds] = {
		id = Debris.Weeds,
		key = "Weeds",
		name = "Weeds",
		value = 0.09,
		weight = 2,
		unitsPerLevel = 3,
		color = Palette.weeds,
		cutColor = Palette.grass.cut,
		tools = { "Hand", "Trimmer", "Mower" },
	},
	[Debris.Hedge] = {
		id = Debris.Hedge,
		key = "Hedge",
		name = "Hedge Trimmings",
		value = 0.16,
		weight = 2,
		unitsPerLevel = 3,
		color = Palette.hedge,
		cutColor = Palette.grass.cut,
		tools = { "Hand", "HedgeTrimmer" },
	},
	[Debris.Sticks] = {
		id = Debris.Sticks,
		key = "Sticks",
		name = "Fallen Branches",
		value = 0.30,
		weight = 3,
		unitsPerLevel = 2,
		color = Palette.sticks,
		cutColor = Palette.grass.cut,
		tools = { "Hand", "Saw", "Chainsaw" },
	},
	[Debris.Log] = {
		id = Debris.Log,
		key = "Log",
		name = "Log",
		value = 4.20,
		weight = 15,
		unitsPerLevel = 1,
		color = Palette.log,
		cutColor = Palette.log,
		tools = { "Chainsaw" },
	},
	[Debris.Chips] = {
		id = Debris.Chips,
		key = "Chips",
		name = "Wood Chips",
		value = 3.00,
		weight = 10,
		unitsPerLevel = 1,
		color = Palette.chips,
		cutColor = Palette.chips,
		tools = { "Grinder" },
	},
}

Debris.defs = defs

--[[
	The highest debris id there is.

	Derived rather than written down. It decides how many bits a tile byte
	needs for the debris field, that field is three bits and already exactly
	full at seven, and every test that walks the debris types walks `0..MAX_ID`
	— so a hand-maintained copy left behind by a new type would have those
	tests still passing while the new type packed itself into the wet bit and
	read back as bare ground.
]]
local maxId = 0
for id in defs do
	maxId = math.max(maxId, id)
end
Debris.MAX_ID = maxId

function Debris.get(id: number): Types.DebrisDef
	local def = defs[id]
	assert(def, `unknown debris id {id}`)
	return def
end

--- True when a tool of `category` is able to clear debris `id`.
function Debris.canClear(id: number, category: Types.ToolCategory): boolean
	local def = defs[id]
	if not def then
		return false
	end
	for _, allowed in def.tools do
		if allowed == category then
			return true
		end
	end
	return false
end

return Debris
