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

Debris.MAX_ID = 7

local defs: { [number]: Types.DebrisDef } = {
	[Debris.Empty] = {
		id = Debris.Empty,
		key = "Empty",
		name = "Bare Ground",
		value = 0,
		weight = 0,
		unitsPerLevel = 0,
		color = { 0.35, 0.29, 0.22 },
		cutColor = { 0.35, 0.29, 0.22 },
		tools = {},
	},
	[Debris.Grass] = {
		id = Debris.Grass,
		key = "Grass",
		name = "Grass Clippings",
		value = 0.10,
		weight = 1,
		unitsPerLevel = 4,
		color = { 0.29, 0.55, 0.20 },
		cutColor = { 0.42, 0.66, 0.30 },
		tools = { "Shears", "Mower", "Trimmer" },
	},
	[Debris.Leaves] = {
		id = Debris.Leaves,
		key = "Leaves",
		name = "Leaves",
		value = 0.15,
		weight = 1,
		unitsPerLevel = 4,
		color = { 0.72, 0.42, 0.14 },
		cutColor = { 0.42, 0.66, 0.30 },
		tools = { "Rake", "Blower" },
	},
	[Debris.Weeds] = {
		id = Debris.Weeds,
		key = "Weeds",
		name = "Weeds",
		value = 0.60,
		weight = 2,
		unitsPerLevel = 3,
		color = { 0.48, 0.58, 0.16 },
		cutColor = { 0.42, 0.66, 0.30 },
		tools = { "Trimmer", "Mower" },
	},
	[Debris.Hedge] = {
		id = Debris.Hedge,
		key = "Hedge",
		name = "Hedge Trimmings",
		value = 1.00,
		weight = 2,
		unitsPerLevel = 3,
		color = { 0.16, 0.38, 0.19 },
		cutColor = { 0.20, 0.45, 0.24 },
		tools = { "HedgeTrimmer" },
	},
	[Debris.Sticks] = {
		id = Debris.Sticks,
		key = "Sticks",
		name = "Fallen Branches",
		value = 1.80,
		weight = 3,
		unitsPerLevel = 2,
		color = { 0.35, 0.24, 0.14 },
		cutColor = { 0.42, 0.66, 0.30 },
		tools = { "Saw", "Chainsaw" },
	},
	[Debris.Log] = {
		id = Debris.Log,
		key = "Log",
		name = "Log",
		value = 26.00,
		weight = 15,
		unitsPerLevel = 1,
		color = { 0.40, 0.26, 0.15 },
		cutColor = { 0.40, 0.26, 0.15 },
		tools = { "Chainsaw" },
	},
	[Debris.Chips] = {
		id = Debris.Chips,
		key = "Chips",
		name = "Wood Chips",
		value = 18.00,
		weight = 10,
		unitsPerLevel = 1,
		color = { 0.55, 0.40, 0.24 },
		cutColor = { 0.55, 0.40, 0.24 },
		tools = { "Grinder" },
	},
}

Debris.defs = defs

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
