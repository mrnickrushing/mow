--!strict
--[[
	Difficulty curve.

	Reports how much work each property actually asks for, so the ladder can be
	checked rather than assumed. A world later in the chain should demand more
	than the one before it; this is what says whether it does.

	Run with:  python3 scripts/build_tests.py && luau scripts/measure_difficulty.luau
]]

local Debris = require("../tests/.build/Shared/Config/Debris")
local Worlds = require("../tests/.build/Shared/Config/Worlds")

--- Units a single tile of this section holds on average, across its fill.
local function unitsPerTile(section): number
	local weight, units = 0, 0
	for _, entry in section.fill do
		local meanHeight = (entry.heightMin + entry.heightMax) / 2
		units += meanHeight * Debris.get(entry.debris).unitsPerLevel * entry.weight
		weight += entry.weight
	end
	return if weight > 0 then units / weight else 0
end

print(string.format("%-13s %-7s %5s %9s %9s %7s %7s", "world", "diff", "secs", "required", "total", "clock", "payout"))
for _, world in Worlds.list do
	local required, total, sections = 0, 0, 0
	for _, section in world.sections do
		sections += 1
		local units = section.rect.w * section.rect.d * section.density * unitsPerTile(section)
		total += units
		if not section.optional then
			required += units
		end
	end
	print(string.format("%-13s %-7s %5d %9d %9d %7d %7.1f",
		world.id, world.difficulty, sections, required, total, world.runSeconds, world.payoutMultiplier))
end
