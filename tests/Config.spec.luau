--!strict
--[[
	Config integrity.

	These are design assertions rather than code tests: they catch a tool priced
	out of order, a zone that overlaps the house, or a debris type nothing can
	clear — the sort of mistake that is invisible in a diff and painful in a
	playtest.
]]

local Debris = require("./.build/Shared/Config/Debris")
local Monetization = require("./.build/Shared/Config/Monetization")
local Properties = require("./.build/Shared/Config/Properties")
local Tools = require("./.build/Shared/Config/Tools")
local Types = require("./.build/Shared/Types")
local Upgrades = require("./.build/Shared/Config/Upgrades")
local h = require("./harness")

local function rectsOverlap(a: Types.Rect, b: Types.Rect): boolean
	return a.x < b.x + b.w and b.x < a.x + a.w and a.z < b.z + b.d and b.z < a.z + a.d
end

local function pointInRect(x: number, z: number, r: Types.Rect): boolean
	return x >= r.x and z >= r.z and x < r.x + r.w and z < r.z + r.d
end

return function()
	h.describe("Config — tools", function()
		h.it("has unique ids and tiers", function()
			local ids, tiers = {}, {}
			for _, tool in Tools.list do
				h.expectFalse(ids[tool.id] == true, `duplicate tool id {tool.id}`)
				h.expectFalse(tiers[tool.tier] == true, `duplicate tier {tool.tier}`)
				ids[tool.id] = true
				tiers[tool.tier] = true
			end
		end)

		h.it("is listed in tier order with non-decreasing prices", function()
			local previousTier, previousCost = -1, -1
			for _, tool in Tools.list do
				h.expectTrue(tool.tier > previousTier, `{tool.id} is out of tier order`)
				h.expectTrue(tool.cost >= previousCost, `{tool.id} costs less than the tier below it`)
				previousTier, previousCost = tool.tier, tool.cost
			end
		end)

		h.it("starts the player on a tool that is free and owned", function()
			local starter = Tools.expect(Tools.STARTER_ID)
			h.expectEqual(starter.cost, 0, "the starter tool must be free")
			h.expectEqual(starter.tier, 0, "the starter tool must be tier 0")
		end)

		h.it("gives every cutting tool something it can clear", function()
			for _, tool in Tools.list do
				-- Grinders and chippers act on trees and stumps, not on tiles.
				if tool.category ~= "Grinder" and tool.category ~= "Chipper" then
					h.expectTrue(#tool.clears > 0, `{tool.id} cannot clear anything`)
				end
			end
		end)

		h.it("only clears debris its category is allowed to handle", function()
			for _, tool in Tools.list do
				for _, debrisId in tool.clears do
					h.expectTrue(
						Debris.canClear(debrisId, tool.category),
						`{tool.id} lists debris {debrisId} that a {tool.category} cannot clear`
					)
				end
			end
		end)

		h.it("refuses tiles taller than the tool can bite", function()
			local shears = Tools.expect("shears")
			h.expectTrue(Tools.canCut(shears, Debris.Grass, shears.maxHeight))
			h.expectFalse(Tools.canCut(shears, Debris.Grass, shears.maxHeight + 1), "overgrowth gate")
			h.expectFalse(Tools.canCut(shears, Debris.Grass, 0), "a clean tile is not cuttable")
			h.expectFalse(Tools.canCut(shears, Debris.Leaves, 1), "shears must not clear leaves")
		end)

		h.it("marks exactly the rideable tools as vehicles", function()
			for _, tool in Tools.list do
				local expected = tool.id == "riding_mower" or tool.id == "zero_turn" or tool.id == "commercial_deck"
				h.expectEqual(Tools.isVehicle(tool), expected, `{tool.id} vehicle flag`)
			end
		end)
	end)

	h.describe("Config — debris", function()
		h.it("can be cleared by at least one real tool", function()
			for id = 1, Debris.MAX_ID do
				local reachable = false
				for _, tool in Tools.list do
					for _, clears in tool.clears do
						if clears == id then
							reachable = true
						end
					end
				end
				-- Logs and chips come from trees and stumps rather than tiles.
				if id ~= Debris.Log and id ~= Debris.Chips then
					h.expectTrue(reachable, `nothing in the game can clear {Debris.get(id).name}`)
				end
			end
		end)

		h.it("pays more per bag unit the harder it is to reach", function()
			local grass = Debris.get(Debris.Grass)
			local log = Debris.get(Debris.Log)
			local grassPerUnit = grass.value / grass.weight
			local logPerUnit = log.value / log.weight
			h.expectTrue(logPerUnit > grassPerUnit * 5, "hauling logs must clearly beat mowing grass")
		end)

		h.it("fits every id in the three bits the wire format allows", function()
			h.expectTrue(Debris.MAX_ID <= 7, `MAX_ID {Debris.MAX_ID} will not fit in three bits`)
			for id = 0, Debris.MAX_ID do
				h.expectTrue(Debris.defs[id] ~= nil, `debris id {id} has no definition`)
			end
		end)
	end)

	h.describe("Config — upgrades", function()
		h.it("has unique ids and a reachable maximum", function()
			local ids = {}
			for _, def in Upgrades.list do
				h.expectFalse(ids[def.id] == true, `duplicate upgrade id {def.id}`)
				ids[def.id] = true
				h.expectTrue(def.maxLevel > 0, `{def.id} has no levels`)
				h.expectTrue(def.costGrowth > 1, `{def.id} must get more expensive`)
			end
		end)

		h.it("changes the value at every level it sells", function()
			for _, def in Upgrades.list do
				local previous = Upgrades.valueAt(def, 0)
				for level = 1, def.maxLevel do
					local value = Upgrades.valueAt(def, level)
					h.expectTrue(value > previous, `{def.id} level {level} is worth no more than level {level - 1}`)
					previous = value
				end
			end
		end)
	end)

	h.describe("Config — properties", function()
		h.it("keeps every zone inside the grid", function()
			for _, property in Properties.list do
				for _, zone in property.zones do
					local r = zone.rect
					h.expectTrue(r.x >= 0 and r.z >= 0, `{property.id}/{zone.id} starts outside the grid`)
					h.expectTrue(
						r.x + r.w <= property.gridWidth and r.z + r.d <= property.gridDepth,
						`{property.id}/{zone.id} runs off the grid`
					)
					h.expectTrue(r.w > 0 and r.d > 0, `{property.id}/{zone.id} is empty`)
				end
			end
		end)

		h.it("never overlaps two zones", function()
			for _, property in Properties.list do
				local zones = property.zones
				for i = 1, #zones do
					for j = i + 1, #zones do
						h.expectFalse(
							rectsOverlap(zones[i].rect, zones[j].rect),
							`{property.id}: {zones[i].id} overlaps {zones[j].id}`
						)
					end
				end
			end
		end)

		h.it("only lets a zone sit on the house footprint if it is a roof", function()
			-- The rooftop deliberately takes the house's own footprint. Anything
			-- else overlapping the house would be debris buried inside a wall.
			for _, property in Properties.list do
				local house = property.houseRect
				if house then
					for _, zone in property.zones do
						if rectsOverlap(zone.rect, house) then
							h.expectTrue(
								(zone.elevation or 0) > 0,
								`{property.id}: {zone.id} overlaps the house at ground level`
							)
							h.expectEqual(zone.kind, "roof", `{property.id}: {zone.id} is on the house but not a roof`)
						end
					end
				end
			end
		end)

		h.it("prices cash zones and gives away the rest", function()
			for _, property in Properties.list do
				h.expectEqual(property.zones[1].cost, 0, `{property.id}: the first zone must be free`)

				for index, zone in property.zones do
					local kind = Properties.unlockKind(zone)
					if kind == "cash" then
						if index > 1 then
							h.expectTrue(zone.cost > 0, `{property.id}: {zone.id} is a cash zone costing nothing`)
						end
					else
						-- Earned, not bought: charging as well would be a double gate.
						h.expectEqual(zone.cost, 0, `{property.id}: {zone.id} unlocks by {kind} but also charges`)
					end
				end
			end
		end)

		h.it("points every non-cash unlock at a zone that exists", function()
			for _, property in Properties.list do
				for _, zone in property.zones do
					local kind = Properties.unlockKind(zone)
					if kind == "completion" then
						h.expectTrue(zone.requires ~= nil, `{property.id}: {zone.id} unlocks on completion of nothing`)
						h.expectTrue(
							Properties.zone(property, zone.requires :: string) ~= nil,
							`{property.id}: {zone.id} requires unknown zone {zone.requires}`
						)
						h.expectFalse(
							zone.requires == zone.id,
							`{property.id}: {zone.id} requires itself`
						)
					elseif kind == "button" then
						h.expectTrue(zone.buttonIn ~= nil, `{property.id}: {zone.id} has no button location`)
						h.expectTrue(
							Properties.zone(property, zone.buttonIn :: string) ~= nil,
							`{property.id}: {zone.id} hides its button in unknown zone {zone.buttonIn}`
						)
						h.expectFalse(
							zone.buttonIn == zone.id,
							`{property.id}: {zone.id} hides its own button inside itself`
						)
					end
				end
			end
		end)

		h.it("never gates a zone behind one that is itself harder to reach", function()
			-- A completion gate has to depend on something already reachable, or
			-- the player is locked out of both forever.
			for _, property in Properties.list do
				local order: { [string]: number } = {}
				for index, zone in property.zones do
					order[zone.id] = index
				end
				for _, zone in property.zones do
					if zone.requires then
						h.expectTrue(
							order[zone.requires] < order[zone.id],
							`{property.id}: {zone.id} depends on {zone.requires}, which comes later`
						)
					end
				end
			end
		end)

		h.it("reports the elevation of a tile in each zone", function()
			for _, property in Properties.list do
				for _, zone in property.zones do
					local tx = zone.rect.x + zone.rect.w // 2
					local tz = zone.rect.z + zone.rect.d // 2
					h.expectClose(
						Properties.elevationAt(property, tx, tz),
						zone.elevation or 0,
						1e-9,
						`{property.id}/{zone.id} elevation`
					)
				end
			end
		end)

		h.it("keeps the shed, trailer and spawn on open ground", function()
			for _, property in Properties.list do
				for label, point in
					{ shed = property.shed, trailer = property.trailer, spawn = property.spawn } :: { [string]: any }
				do
					h.expectTrue(
						point.x >= 0 and point.z >= 0 and point.x < property.gridWidth and point.z < property.gridDepth,
						`{property.id}: {label} is off the grid`
					)
					for _, zone in property.zones do
						h.expectFalse(
							pointInRect(point.x, point.z, zone.rect),
							`{property.id}: {label} is buried inside {zone.id}`
						)
					end
					local house = property.houseRect
					if house then
						h.expectFalse(
							pointInRect(point.x, point.z, house),
							`{property.id}: {label} is inside the house`
						)
					end
				end
			end
		end)

		h.it("climbs in price across the cash zones of a property", function()
			for _, property in Properties.list do
				local previous = 0
				for _, zone in property.zones do
					if Properties.unlockKind(zone) == "cash" and zone.cost > 0 then
						h.expectTrue(
							zone.cost > previous,
							`{property.id}: {zone.id} is not dearer than the cash zone before it`
						)
						previous = zone.cost
					end
				end
			end
		end)

		h.it("climbs in unlock cost, payout and size across the rotation", function()
			local previousUnlock, previousPayout, previousArea = -1, 0, 0
			for _, property in Properties.list do
				h.expectTrue(property.unlockLifetimeCash > previousUnlock, `{property.id} unlocks out of order`)
				h.expectTrue(property.payoutMultiplier >= previousPayout, `{property.id} pays less than the last map`)
				local area = property.gridWidth * property.gridDepth
				h.expectTrue(area >= previousArea, `{property.id} is smaller than the last map`)
				previousUnlock, previousPayout, previousArea = property.unlockLifetimeCash, property.payoutMultiplier, area
			end
		end)

		h.it("starts the rotation on a property that costs nothing to reach", function()
			local starter = Properties.expect(Properties.STARTER_ID)
			h.expectEqual(starter.unlockLifetimeCash, 0)
			h.expectEqual(#Properties.unlockedFor(0), 1, "a new player should see exactly one map")
		end)

		h.it("uses a density that leaves some bare ground", function()
			for _, property in Properties.list do
				for _, zone in property.zones do
					h.expectTrue(
						zone.density > 0 and zone.density <= 1,
						`{property.id}/{zone.id} density {zone.density} is out of range`
					)
				end
			end
		end)
	end)

	h.describe("Config — monetization", function()
		h.it("has unique keys across passes and products", function()
			local keys = {}
			for _, pass in Monetization.passes do
				h.expectFalse(keys[pass.key] == true, `duplicate key {pass.key}`)
				keys[pass.key] = true
			end
			for _, product in Monetization.products do
				h.expectFalse(keys[product.key] == true, `duplicate key {product.key}`)
				keys[product.key] = true
			end
		end)

		h.it("ships with placeholder ids so nothing charges by accident", function()
			for _, pass in Monetization.passes do
				h.expectFalse(Monetization.isConfigured(pass.id), `{pass.key} has a real id committed`)
			end
			for _, product in Monetization.products do
				h.expectFalse(Monetization.isConfigured(product.id), `{product.key} has a real id committed`)
			end
		end)

		h.it("points every rental at a tool that exists", function()
			for _, product in Monetization.products do
				if product.kind == "rental" then
					h.expectTrue(product.toolId ~= nil, `{product.key} is a rental with no tool`)
					h.expectTrue(
						Tools.get(product.toolId :: string) ~= nil,
						`{product.key} rents unknown tool {product.toolId}`
					)
					h.expectTrue((product.seconds or 0) > 0, `{product.key} rents for no time`)
				end
			end
		end)

		h.it("gives every timed product a duration and every boost a multiplier", function()
			for _, product in Monetization.products do
				if product.kind == "cashBoost" or product.kind == "serverBoost" then
					h.expectTrue((product.multiplier or 0) > 1, `{product.key} boosts by nothing`)
					h.expectTrue((product.seconds or 0) > 0, `{product.key} lasts no time`)
				end
			end
		end)

		h.it("keeps the free reward loops meaningful", function()
			local rewards = Monetization.rewards
			h.expectTrue(#rewards.dailyStreak >= 7, "a daily streak should run at least a week")
			local previous = 0
			for _, amount in rewards.dailyStreak do
				h.expectTrue(amount > previous, "each streak day must beat the last")
				previous = amount
			end
			h.expectTrue(
				Tools.get(rewards.freeRentalToolId) ~= nil,
				`free rental names unknown tool {rewards.freeRentalToolId}`
			)
		end)
	end)
end
