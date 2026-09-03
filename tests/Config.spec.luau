--!strict
--[[
	Config integrity.

	These are design assertions rather than code tests: they catch a tool priced
	out of order, a zone that overlaps the house, or a debris type nothing can
	clear — the sort of mistake that is invisible in a diff and painful in a
	playtest.
]]

local Debris = require("./.build/Shared/Config/Debris")
local GameConfig = require("./.build/Shared/Config/GameConfig")
local Monetization = require("./.build/Shared/Config/Monetization")
local Worlds = require("./.build/Shared/Config/Worlds")
local Tools = require("./.build/Shared/Config/Tools")
local Types = require("./.build/Shared/Types")
local DefaultData = require("./.build/Server/Lib/DefaultData")
local LobbyPad = require("./.build/Shared/LobbyPad")
local Props = require("./.build/Shared/Config/Props")
local Upgrades = require("./.build/Shared/Config/Upgrades")
local Quests = require("./.build/Shared/Config/Quests")
local Balance = require("./.build/Shared/Config/Balance")
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
			local hands = Tools.expect("hands")
			h.expectTrue(Tools.canCut(hands, Debris.Grass, hands.maxHeight))
			h.expectFalse(Tools.canCut(hands, Debris.Grass, hands.maxHeight + 1), "overgrowth gate")
			h.expectFalse(Tools.canCut(hands, Debris.Grass, 0), "a clean tile is not cuttable")

			-- Hands handle leaves; a mower is what should refuse them.
			h.expectTrue(Tools.canCut(hands, Debris.Leaves, 1), "hands must clear leaves")
			h.expectFalse(Tools.canCut(Tools.expect("gas_mower"), Debris.Leaves, 1), "a mower must not")
		end)

		h.it("lets bare hands shift anything a tile can hold", function()
			-- The rule that keeps a run from ever being unwinnable: if a section
			-- is full of something the starter cannot touch and the tool for it
			-- is out of reach, the run is dead. Hands are slow, never blocked.
			local starter = Tools.expect(Tools.STARTER_ID)
			local used: { [number]: boolean } = {}
			for _, world in Worlds.list do
				for _, section in world.sections do
					for _, entry in section.fill do
						used[entry.debris] = true
					end
				end
			end

			for debrisId in used do
				h.expectTrue(
					Debris.canClear(debrisId, starter.category),
					`nothing but paid gear can clear {Debris.get(debrisId).name}`
				)
				h.expectTrue(
					Tools.canCut(starter, debrisId, 3),
					`the starter cannot reach full-height {Debris.get(debrisId).name}`
				)
			end
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

		h.it("puts nothing in a required section that a broke player cannot clear", function()
			--[[
				The affordability floor for the whole game.

				A section is finished only when its demand reaches zero, so
				every kind of debris a required section can contain has to be
				removable with what a player who has just arrived owns — which
				is a pair of hands and no money. This is the invariant the
				trees broke: they added timber to a required section's demand
				that needed a $3,200 saw, in a world whose every last clipping
				is worth $2,013, and grinding the stump that felling left
				needed $140,000 more. Nothing on a tile may ever be gated like
				that again.
			]]
			local free: { [number]: boolean } = {}
			for _, tool in Tools.list do
				if tool.cost == 0 and tool.currency == "Cash" then
					for _, id in tool.clears do
						free[id] = true
					end
				end
			end
			h.expectTrue(next(free) ~= nil, "no tool costs nothing, so nobody can start")

			for _, world in Worlds.list do
				for _, section in Worlds.requiredSections(world) do
					for _, entry in section.fill do
						h.expectTrue(
							free[entry.debris] == true,
							`{world.id}/{section.id} needs {Debris.get(entry.debris).name}, `
								.. "which no free tool can clear"
						)
					end
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

	h.describe("Config — icons", function()
		h.it("has a real model for every kind of tool", function()
			--[[
				The interface used to be drawn in emoji, which cannot be wrong
				in this way: a glyph either renders or shows a box, and either
				way something appears. An icon is a mesh id now, and a name
				that misses the catalogue by one letter renders nothing at all
				— an empty slot in the hotbar with no error anywhere.
			]]
			for _, tool in Tools.list do
				local name = Props.forToolCategory(tool.category)
				h.expectTrue(
					Props.get(name) ~= nil,
					`{tool.id} is a {tool.category}, which asks for a model called `
						.. `"{name}" that the catalogue does not have`
				)
			end
			h.expectTrue(
				Props.get(Props.FALLBACK_TOOL_ICON) ~= nil,
				"the fallback icon itself is missing from the catalogue"
			)
		end)

		h.it("gives every model a native size with no zero side", function()
			-- An icon is framed by dividing by its own size, and every mesh is
			-- scaled the same way when the world is built.
			for name, def in Props.catalogue do
				h.expectTrue(def.mesh ~= "", `{name} has no mesh id`)
				h.expectTrue(
					def.native.X > 0 and def.native.Y > 0 and def.native.Z > 0,
					`{name} has a zero side in its native size, which would divide by zero`
				)
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

	h.describe("Config — worlds", function()
		h.it("keeps every section inside the grid", function()
			for _, world in Worlds.list do
				for _, section in world.sections do
					local r = section.rect
					h.expectTrue(r.x >= 0 and r.z >= 0, `{world.id}/{section.id} starts outside the grid`)
					h.expectTrue(
						r.x + r.w <= world.gridWidth and r.z + r.d <= world.gridDepth,
						`{world.id}/{section.id} runs off the grid`
					)
					h.expectTrue(r.w > 0 and r.d > 0, `{world.id}/{section.id} is empty`)
				end
			end
		end)

		h.it("never overlaps two sections", function()
			for _, world in Worlds.list do
				local sections = world.sections
				for i = 1, #sections do
					for j = i + 1, #sections do
						h.expectFalse(
							rectsOverlap(sections[i].rect, sections[j].rect),
							`{world.id}: {sections[i].id} overlaps {sections[j].id}`
						)
					end
				end
			end
		end)

		h.it("only lets a section sit on the house footprint if it is a roof", function()
			for _, world in Worlds.list do
				local house = world.houseRect
				if house then
					for _, section in world.sections do
						if rectsOverlap(section.rect, house) then
							h.expectTrue(
								(section.elevation or 0) > 0,
								`{world.id}: {section.id} overlaps the house at ground level`
							)
							h.expectEqual(section.kind, "roof", `{world.id}: {section.id} is on the house but not a roof`)
						end
					end
				end
			end
		end)

		h.it("keeps the shed, trailer, spawn and exit on open ground", function()
			for _, world in Worlds.list do
				local points: { [string]: any } = {
					shed = world.shed,
					trailer = world.trailer,
					spawn = world.spawn,
					exit = world.exit,
				}
				for label, point in points do
					h.expectTrue(
						point.x >= 0 and point.z >= 0 and point.x < world.gridWidth and point.z < world.gridDepth,
						`{world.id}: {label} is off the grid`
					)
					for _, section in world.sections do
						h.expectFalse(
							pointInRect(point.x, point.z, section.rect),
							`{world.id}: {label} is buried inside {section.id}`
						)
					end
					local house = world.houseRect
					if house then
						h.expectFalse(
							pointInRect(point.x, point.z, house),
							`{world.id}: {label} is inside the house`
						)
					end
				end
			end
		end)

		h.it("stands a rooftop on the house's roof, not inside it", function()
			--[[
				The Rooftop's floor was once a hand-written 24 that happened to
				match ROOF_HEIGHT, while the roof it stands on is a capped slab
				whose top face is four studs higher. The section was built
				inside the building and seven hundred and fifty-seven tiles of
				debris went with it, invisible from the deck the player stands
				on. Both numbers come from GameConfig now; this is the guard
				that says they still agree.
			]]
			for _, world in Worlds.list do
				for _, section in world.sections do
					if (section.kind or "open") == "roof" then
						h.expectTrue(
							(section.elevation or 0) > GameConfig.HOUSE_ROOF_TOP,
							`{world.id}: {section.id} sits at {section.elevation or 0}, `
								.. `inside a roof whose top is {GameConfig.HOUSE_ROOF_TOP}`
						)
					end
				end
			end
		end)

		h.it("gives every world exactly one starting section", function()
			for _, world in Worlds.list do
				local starts = 0
				for _, section in world.sections do
					if Worlds.unlockKind(section) == "start" then
						starts += 1
					end
				end
				h.expectEqual(starts, 1, `{world.id} should have exactly one start`)
			end
		end)

		h.it("puts a price only on cash gates, and always a real one", function()
			-- Most gates open on clearing; a few are doors with a small price on
			-- them, paid in run cash at the door itself. A price on any other
			-- kind of section would be unreachable, and a cash gate priced at
			-- zero would be a door that opens for free while claiming otherwise.
			for _, world in Worlds.list do
				for _, section in world.sections do
					if Worlds.unlockKind(section) == "cash" then
						h.expectTrue(section.cost > 0, `{world.id}/{section.id} is a free cash gate`)
					else
						h.expectEqual(section.cost, 0, `{world.id}/{section.id} has a price nothing collects`)
					end
				end
			end
		end)

		h.it("points every gate at a section that exists and comes earlier", function()
			for _, world in Worlds.list do
				local order: { [string]: number } = {}
				for index, section in world.sections do
					order[section.id] = index
				end

				for _, section in world.sections do
					local kind = Worlds.unlockKind(section)
					if kind == "completion" then
						h.expectTrue(section.requires ~= nil, `{world.id}: {section.id} opens on nothing`)
						local required = section.requires :: string
						h.expectTrue(
							Worlds.section(world, required) ~= nil,
							`{world.id}: {section.id} requires unknown section {required}`
						)
						h.expectTrue(
							order[required] < order[section.id],
							`{world.id}: {section.id} depends on {required}, which comes later`
						)
					elseif kind == "button" then
						h.expectTrue(section.buttonIn ~= nil, `{world.id}: {section.id} has no switch location`)
						local host = section.buttonIn :: string
						h.expectTrue(
							Worlds.section(world, host) ~= nil,
							`{world.id}: {section.id} hides its switch in unknown section {host}`
						)
						h.expectFalse(host == section.id, `{world.id}: {section.id} hides its own switch inside itself`)
					end
				end
			end
		end)

		h.it("leaves every required section reachable from the start", function()
			-- A gate chain that forks off an optional section would lock the run.
			for _, world in Worlds.list do
				local reachable: { [string]: boolean } = {}
				reachable[Worlds.startSection(world).id] = true

				for _, section in world.sections do
					local kind = Worlds.unlockKind(section)
					if (kind == "completion" or kind == "cash") and section.requires then
						reachable[section.id] = reachable[section.requires] == true
					elseif kind == "button" then
						reachable[section.id] = reachable[section.buttonIn :: string] == true
					end
				end

				for _, section in Worlds.requiredSections(world) do
					h.expectTrue(reachable[section.id] == true, `{world.id}: {section.id} can never be opened`)
				end
			end
		end)

		h.it("ends on a required section, not an optional one", function()
			for _, world in Worlds.list do
				local final = Worlds.finalSection(world)
				h.expectFalse(final.optional == true, `{world.id} finishes on an optional section`)
			end
		end)

		h.it("scales waves with the players present", function()
			local world = Worlds.expect(Worlds.STARTER_ID)
			local main = Worlds.startSection(world)
			h.expectEqual(Worlds.wavesFor(main, 1), 1, "solo should be one wave")
			h.expectEqual(Worlds.wavesFor(main, 3), 3, "three players, three waves")

			local garage = Worlds.section(world, "garage")
			h.expectTrue(garage ~= nil)
			h.expectEqual(Worlds.wavesFor(garage :: any, 4), 1, "a pinned section ignores headcount")
		end)

		h.it("keeps the work per player the same however many are playing", function()
			-- The point of waves. A section holds U units per wave and needs one
			-- wave per player, so the run's total work is N*U shared between N
			-- people: everyone does U regardless. A full server takes as long as
			-- a solo run rather than finishing in a fraction of the time.
			local world = Worlds.expect(Worlds.STARTER_ID)
			local section = Worlds.startSection(world)

			local solo = Worlds.wavesFor(section, 1) / 1
			for players = 2, 8 do
				local share = Worlds.wavesFor(section, players) / players
				h.expectClose(share, solo, 1e-9, `work per player changed at {players} players`)
			end
		end)

		h.it("climbs in payout and gates later worlds behind earlier ones", function()
			local previousPayout = 0
			for _, world in Worlds.list do
				h.expectTrue(world.payoutMultiplier >= previousPayout, `{world.id} pays less than the world before`)
				previousPayout = world.payoutMultiplier
				if world.requiresWorld then
					h.expectTrue(
						Worlds.get(world.requiresWorld) ~= nil,
						`{world.id} requires unknown world {world.requiresWorld}`
					)
				end
			end
		end)

		h.it("shows only the first world to a new player", function()
			local available = Worlds.availableTo({})
			h.expectEqual(#available, 1, "a new player should see exactly one world")
			h.expectEqual(available[1].id, Worlds.STARTER_ID)

			local afterHouse = Worlds.availableTo({ house = true })
			h.expectTrue(#afterHouse >= 2, "beating the house should open the next one")
		end)

		h.it("uses a density that leaves some bare ground", function()
			for _, world in Worlds.list do
				for _, section in world.sections do
					h.expectTrue(
						section.density > 0 and section.density <= 1,
						`{world.id}/{section.id} density {section.density} is out of range`
					)
				end
			end
		end)
	end)

	h.describe("Saves — receipts", function()
		--[[
			Robux is real money, so the ledger that stops a purchase being paid
			out twice is worth holding down with tests rather than trusting to
			the next person not to drop a field.
		]]
		h.it("gives a fresh profile somewhere to record receipts", function()
			local fresh = DefaultData.template()
			h.expectTrue(type(fresh.receipts) == "table", "a new profile cannot remember receipts")
			h.expectTrue(#fresh.receipts == 0, "a new profile starts owing nothing")
		end)

		h.it("gives an old save one too, rather than leaving it nil", function()
			-- A save from before receipts existed. Without a table here, the
			-- first purchase after an update indexes nil and the grant throws,
			-- which Roblox answers by retrying the same receipt forever.
			local old = { version = 1, worldsBeaten = {}, stats = {} }
			local migrated = DefaultData.migrate(old)
			h.expectTrue(type(migrated.receipts) == "table", "a migrated profile cannot remember receipts")
		end)

		h.it("replaces a receipts field of the wrong type", function()
			local corrupt = DefaultData.migrate({ version = 1, receipts = "not a table" })
			h.expectTrue(type(corrupt.receipts) == "table", "a corrupt receipts field survived migration")
		end)

		h.it("agrees with itself about where a pad ends", function()
			--[[
				The client opened its panel on a circle of radius 14; the
				server decided which game you joined on a square reaching 13,
				and checked your height where the client did not. Both numbers
				came off the same 24-stud pad and neither knew about the other.

				13.5 studs out is the gap that mattered: the panel opened, the
				green Confirm went up, and the server answered "Stand on a pad
				to set a game up" to somebody plainly standing on one.
			]]
			local PAD, SIZE = 0, 24
			h.expectTrue(LobbyPad.covers(PAD, 0, PAD, SIZE, 0, 0, 0), "the middle of a pad is not on it")
			h.expectTrue(
				not LobbyPad.covers(PAD, 0, PAD, SIZE, 13.5, 0, 0),
				"13.5 studs out still counts, which is the disagreement that opened a panel over a refusal"
			)
			h.expectTrue(
				LobbyPad.covers(PAD, 0, PAD, SIZE, 13, 0, 13),
				"the corner of a square pad reads as off it"
			)
			h.expectTrue(
				not LobbyPad.covers(PAD, 0, PAD, SIZE, 0, 20, 0),
				"standing twenty studs above a pad counts as standing on it"
			)
		end)

		h.it("keeps flanking scenery off the pads", function()
			--[[
				Shrinking the lobby from 260 studs to 160 moved the hedge rows
				without anybody asking them to: they were placed at
				`halfW - 34`, which fell from 96 to 46 while the pad row went
				on reaching 60. Eight hedge parts ended up standing inside the
				first pad and eight inside the last, so half the games in the
				lobby were advertised by a shrub.

				The flanks are measured off the pads now, and this is the
				statement that was silently false before.
			]]
			for slots = 1, 8 do
				local reach = LobbyPad.rowReach(slots)
				local flank = LobbyPad.flankX(slots)
				h.expectTrue(
					flank > reach,
					`with {slots} pads the flanks sit at {flank}, inside a row reaching {reach}`
				)
				-- The outermost pad, checked through the predicate itself.
				local outer = (slots - 1) * 0.5 * LobbyPad.SPACING
				h.expectTrue(
					not LobbyPad.covers(outer, 0, 0, LobbyPad.SPAN, flank, 0, 0),
					`with {slots} pads the hedge line at {flank} stands on the outermost pad`
				)
			end
		end)

		h.it("never puts one player on two pads at once", function()
			--[[
				The four pads sit 32 apart and are 24 across, so the margin has
				eight studs of gap to live in. Overlapping reaches would let a
				player set up one game and be counted into its neighbour.
			]]
			local FIRST, SPACING, SIZE, COUNT = -648, 32, 24, 4
			for step = 0, 1400 do
				local x = FIRST - 40 + step * 0.1
				local on = 0
				for i = 0, COUNT - 1 do
					if LobbyPad.covers(FIRST + i * SPACING, 0, -592, SIZE, x, 0, -592) then
						on += 1
					end
				end
				h.expectTrue(on <= 1, `x={x} counts as standing on {on} pads at once`)
			end
		end)

		h.it("survives every template field arriving as the wrong type", function()
			--[[
				`stats` was the one that bit: migrate indexed it directly, so a
				save holding anything but a table threw part-way through the
				load. A profile that throws while loading never loads, and a
				player without a profile waits on a lobby pad that will never
				start, with nothing on screen saying why.
			]]
			local corrupt = DefaultData.migrate({
				version = 1,
				stats = "not a table",
				worldsBeaten = 7,
				bestTimes = false,
				questProgress = "nope",
				questsDone = 0,
				permanentTools = "no",
				tips = "lots",
			})
			for _, key in { "stats", "worldsBeaten", "bestTimes", "questProgress", "questsDone", "permanentTools" } do
				h.expectTrue(type((corrupt :: any)[key]) == "table", `a corrupt {key} survived migration`)
			end
			h.expectTrue(type(corrupt.tips) == "number", "a corrupt tips field survived migration")
			h.expectTrue(corrupt.version == DefaultData.VERSION, "a repaired profile kept its old version")
		end)

		h.it("remembers enough receipts to outlast Roblox's retries", function()
			-- Roblox stops retrying a receipt within a day. The cap only exists
			-- so a profile cannot grow without bound, and has to sit well above
			-- any plausible run of purchases in that window.
			h.expectTrue(
				DefaultData.RECEIPT_MEMORY >= 20,
				`remembering only {DefaultData.RECEIPT_MEMORY} receipts risks forgetting one still being retried`
			)
		end)
	end)

	h.describe("Config — the ladder", function()
		--- Units a tile of this section holds on average, across its fill.
		local function unitsPerTile(section: Types.ZoneDef): number
			local weight, units = 0, 0
			for _, entry in section.fill do
				local meanHeight = (entry.heightMin + entry.heightMax) / 2
				units += meanHeight * Debris.get(entry.debris).unitsPerLevel * entry.weight
				weight += entry.weight
			end
			return if weight > 0 then units / weight else 0
		end

		--- What a world demands before its exit will open. Optional sections do
		--- not count: nobody has to clear them to finish.
		local function requiredUnits(world: Types.WorldDef): number
			local total = 0
			for _, section in world.sections do
				if not section.optional then
					total += section.rect.w * section.rect.d * section.density * unitsPerTile(section)
				end
			end
			return total
		end

		--- The worlds in the order they unlock, following `requiresWorld`.
		local function chain(): { Types.WorldDef }
			local byRequirement: { [string]: Types.WorldDef } = {}
			local first: Types.WorldDef? = nil
			for _, world in Worlds.list do
				if world.requiresWorld then
					byRequirement[world.requiresWorld] = world
				else
					h.expectTrue(first == nil, "two worlds unlock with nothing before them")
					first = world
				end
			end
			h.expectTrue(first ~= nil, "no world unlocks first, so the ladder has no bottom")

			local order: { Types.WorldDef } = {}
			local at = first
			while at do
				table.insert(order, at)
				at = byRequirement[at.id]
			end
			return order
		end

		h.it("unlocks in one unbroken chain that reaches every world", function()
			local order = chain()
			local count = 0
			for _ in Worlds.list do
				count += 1
			end
			h.expectTrue(
				#order == count,
				`the unlock chain reaches {#order} of {count} worlds, so one is unreachable`
			)
		end)

		h.it("asks for more work at every rung", function()
			local order = chain()
			for index = 2, #order do
				local before, after = order[index - 1], order[index]
				h.expectTrue(
					requiredUnits(after) > requiredUnits(before),
					`{after.id} demands less work than {before.id}, which comes before it`
				)
			end
		end)

		h.it("gives less of the clock per unit of work at every rung", function()
			--[[
				The invariant that actually says "harder".

				More ground alone does not make a world harder, because a later
				world also pays better and the gear that buys clears faster. The
				Mansion held twice the work of The House and a perfect run still
				finished it three and a half minutes sooner — the middle rung was
				the easiest one. What has to fall along the chain is the time you
				are given per unit of work in front of you.
			]]
			local order = chain()
			for index = 2, #order do
				local before, after = order[index - 1], order[index]
				local was = before.runSeconds / requiredUnits(before)
				local now = after.runSeconds / requiredUnits(after)
				h.expectTrue(
					now < was,
					`{after.id} gives {string.format("%.4f", now)} seconds per unit against `
						.. `{before.id}'s {string.format("%.4f", was)}, so it is not the harder world`
				)
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

		h.it("sells every paid tool three ways", function()
			-- Run cash, Robux once, Robux forever. A tool priced in Robux on the
			-- tool table but missing a product would show a dead button in the
			-- shop, and a product for a tool with no Robux price would be
			-- unreachable from anywhere.
			for _, tool in Tools.list do
				local runKey, foreverKey = Monetization.toolProductKeys(tool.id)
				local run = Monetization.productByKey[runKey]
				local forever = Monetization.productByKey[foreverKey]

				if tool.cost > 0 and tool.robuxOnce and tool.robuxPermanent then
					h.expectTrue(run ~= nil, `{tool.id} has no one-run product`)
					h.expectTrue(forever ~= nil, `{tool.id} has no permanent product`)
					h.expectEqual((run :: any).toolId, tool.id)
					h.expectEqual((forever :: any).toolId, tool.id)
					h.expectTrue(
						(forever :: any).robux > (run :: any).robux,
						`{tool.id} costs no more to own than to borrow`
					)
					h.expectTrue(
						(tool.robuxWas :: number) > (tool.robuxPermanent :: number),
						`{tool.id} claims a discount off a lower price`
					)
				else
					h.expectTrue(run == nil, `{tool.id} has a product but no Robux price`)
					h.expectTrue(forever == nil, `{tool.id} has a product but no Robux price`)
				end
			end
		end)

		h.it("prices Robux unlocks in step with the cash ladder", function()
			-- Paying should track how long the tool would otherwise take to earn.
			-- A later, dearer tool costing fewer Robux than an earlier one would
			-- make the cheap end of the ladder the worst thing to buy.
			local previousOnce, previousPermanent = 0, 0
			for _, tool in Tools.list do
				if tool.cost > 0 and tool.robuxOnce and tool.robuxPermanent then
					h.expectTrue(
						tool.robuxOnce >= previousOnce,
						`{tool.id} costs less for one run than a cheaper tool`
					)
					h.expectTrue(
						tool.robuxPermanent >= previousPermanent,
						`{tool.id} costs less to own than a cheaper tool`
					)
					previousOnce = tool.robuxOnce
					previousPermanent = tool.robuxPermanent
				end
			end
		end)

		h.it("only asks for grass where a player can find grass", function()
			--[[
				The opening chain now names grass and counts only grass, which
				is a promise about the world as much as about the quest: a
				`collect` quest with subject "grass" is unfinishable in a
				section that seeds none. Every world opens on its first
				section, so that is the one that has to carry it.
			]]
			local wantsGrass = false
			for _, quest in Quests.list do
				if quest.kind == "collect" and quest.subject == "grass" then
					wantsGrass = true
				end
			end
			h.expectTrue(wantsGrass, "the opening chain should ask for grass at all")
			for _, world in Worlds.list do
				local first = world.sections[1]
				local found = false
				for _, entry in first.fill do
					if entry.debris == Debris.Grass then
						found = true
					end
				end
				h.expectTrue(
					found,
					`{world.id} opens on {first.id}, which seeds no grass for the first quest`
				)
			end
		end)

		h.it("keeps the portable trailer a level Haul can reach", function()
			--[[
				Haul level 1 sells the portable trailer, the Journal reads it
				back, and `Economy.earnRate` shortens every walk once it is
				owned — three systems all describing a remote nobody had
				connected. The unlock level has to stay inside the ladder or
				the sentence goes back to being false.
			]]
			local haul: any = nil
			for _, upgrade in Upgrades.list do
				if upgrade.id == "trailer" then
					haul = upgrade
				end
			end
			h.expectTrue(haul ~= nil, "the Haul upgrade should exist")
			h.expectTrue(
				Upgrades.PORTABLE_TRAILER_LEVEL >= 1 and Upgrades.PORTABLE_TRAILER_LEVEL <= haul.maxLevel,
				"the portable trailer unlocks at a level Haul can actually reach"
			)
		end)

		h.it("lets every tool finish a minimum stripe on a bag it can afford", function()
			--[[
				A stripe is banked by holding a heading for STRIPE_MIN_TILES
				tiles, and cutting stops dead the moment the bag is full — so
				the bag decides whether the mechanic exists at all for a given
				tool.

				It reads the deck width because a stripe's length is a distance
				now rather than the count of tiles the mower covered. Under the
				old counting a wide deck reached the minimum sooner, which is
				backwards; under this one it fills the bag faster over the same
				ground and so needs a bigger bag to cut the same length. That
				is the right shape, but it is also a new way for the mechanic
				to become unreachable, and this is the guard on it.
			]]
			local grass = Debris.get(Debris.Grass)
			-- The lawn a new player starts on, at its average height.
			local perTile = 1.5 * grass.unitsPerLevel * grass.weight

			local bag = nil
			for _, upgrade in Upgrades.list do
				if upgrade.id == "bag" then
					bag = upgrade
				end
			end
			h.expectTrue(bag ~= nil, "there should be a Bag upgrade")
			local bagDef = bag :: any

			local levels: any = {}
			for _, upgrade in Upgrades.list do
				levels[upgrade.id] = 0
			end

			for _, tool in Tools.list do
				local needed = GameConfig.STRIPE_MIN_TILES * tool.deck * perTile
				local reached = nil
				for level = 0, bagDef.maxLevel do
					levels.bag = level
					if Balance.bagCapacity(levels, nil) >= needed then
						reached = level
						break
					end
				end
				levels.bag = 0
				h.expectTrue(
					reached ~= nil and reached <= 8,
					`{tool.name} needs {string.format("%.0f", needed)} of bag for one stripe, `
						.. "which is past the eighth Bag level — nobody holding it will bank one"
				)
			end
		end)

		h.it("beats the session lock more than once before it expires", function()
			--[[
				`Store.save` is the only thing that refreshes `lockHeartbeat`,
				and the autosave loop is the only thing that calls it while
				somebody is playing — so the autosave interval *is* the
				heartbeat interval, and it has to fit inside the timeout it is
				keeping alive.

				It did not: a hundred and twenty second autosave against a
				ninety second timeout meant every live player's own lock read
				as dead for a quarter of every cycle, and any other server
				could take their save out from under them while they were
				still playing on it. Room for a missed beat, not just one that
				lands exactly on time.
			]]
			h.expectTrue(
				GameConfig.AUTOSAVE_SECONDS * 2 <= GameConfig.SESSION_LOCK_TIMEOUT,
				`autosave every {GameConfig.AUTOSAVE_SECONDS}s cannot hold a lock that `
					.. `goes stale after {GameConfig.SESSION_LOCK_TIMEOUT}s`
			)
		end)

		h.it("prices a cash gate under what the lawn before it is worth", function()
			--[[
				A cash gate is the one place a run can end on arithmetic rather
				than on the clock. Every one of them sits on the critical path,
				so a player who has cleared everything open to them and still
				cannot pay has no way left to earn: the run is dead and the
				clock just has to run out.

				The three were priced at $1, $8 and $15 against worlds holding
				$1,826, $6,463 and $11,837 of clippings, which is a door that
				opens itself.

				This is a ceiling, not a proof. What decides a stall is what is
				*banked* when the player arrives, after everything they bought
				on the way, and no static sum can know that — `scripts/simulate.luau`
				is the thing that can, and it caught the first attempt at these
				prices stalling The Gas Station outright. The fraction below is
				set just under where that attempt sat, so raising a gate past
				it fails here and sends you to the simulator, which is the
				point.
			]]
			local function grossOf(world: any, section: any): number
				local tiles = section.rect.w * section.rect.d * section.density
				local weight, perTile = 0, 0
				for _, entry in section.fill do
					weight += entry.weight
				end
				for _, entry in section.fill do
					local def = Debris.get(entry.debris)
					local height = (entry.heightMin + entry.heightMax) * 0.5
					perTile += (entry.weight / weight) * height * def.unitsPerLevel * def.value
				end
				return tiles * perTile * world.payoutMultiplier
			end

			for _, world in Worlds.list do
				for _, section in world.sections do
					if Worlds.unlockKind(section) == "cash" then
						local required = section.requires
						h.expectTrue(
							required ~= nil,
							`{world.id}/{section.id} charges at the door but names no lawn before it`
						)
						local before = nil
						for _, other in world.sections do
							if other.id == required then
								before = other
							end
						end
						h.expectTrue(before ~= nil, `{world.id}/{section.id} requires a section that is not there`)
						local earnable = grossOf(world, before :: any)
						h.expectTrue(
							section.cost <= earnable * 0.15,
							`{world.id}/{section.id} costs {section.cost} against {required}'s `
								.. `{string.format("%.0f", earnable)} — past the ceiling, so run `
								.. "scripts/simulate.luau and check nothing stalls at the door"
						)
					end
				end
			end
		end)

		h.it("gives tips something to buy, and keeps it to the bottom of the ladder", function()
			--[[
				Tips were paid out by five different systems — clean stripes,
				wasp nests, Golden Blades, the daily login streak and a trickle
				for time played — and nothing in the game had a price in them.
				A currency with no sink is a reward loop that pays into
				nothing, so the first half of this is simply that one exists.

				The second half is the cap. A permanent tool is a head start on
				every future run, and the thing that makes it one is cutting
				rate, not price: bare hands manage 0.7 passes a second over a
				single tile. Keeping tips to the low tiers is what stops a
				season of daily logins turning into a Zero-Turn Mower on the
				first lawn.
			]]
			local sold = 0
			local previousTier, previousPrice = 0, 0
			for _, tool in Tools.list do
				local price = tool.tipsPermanent
				if price then
					sold += 1
					h.expectTrue(price > 0, `{tool.id} is sold for nothing at all`)
					h.expectTrue(
						tool.tier <= 4,
						`{tool.id} is tier {tool.tier}; tips do not reach past the fourth rung`
					)
					h.expectTrue(
						tool.tier > previousTier,
						`{tool.id} breaks the tier order of the tips ladder`
					)
					h.expectTrue(
						price > previousPrice,
						`{tool.id} costs fewer tips than a tool below it`
					)
					previousTier, previousPrice = tool.tier, price
				end
			end
			h.expectTrue(sold > 0, "nothing in the game has a price in tips, so nothing earns them a purpose")
		end)

		h.it("only names sections that exist somewhere", function()
			--[[
				A quest that names a place is held until that place is dealt
				with, and the chain is a queue, so one that names nowhere at
				all would hold every objective behind it forever.

				`QuestService.catchUp` now steps over an objective whose
				section this property does not have — which is what stops a
				player who skipped the optional garage being stuck on it for
				the rest of the game once they reach The Mansion. That fix has
				a cost: a subject with a typo in it would be stepped over too,
				silently, in every world. So the spelling is checked here.
			]]
			local known: { [string]: boolean } = {}
			for _, world in Worlds.list do
				for _, section in world.sections do
					known[section.id] = true
				end
			end

			for _, quest in Quests.list do
				if quest.kind == "section" or quest.kind == "clearSection" then
					h.expectTrue(
						quest.subject ~= nil,
						`{quest.id} is about a section but names none`
					)
					h.expectTrue(
						known[quest.subject :: string] == true,
						`{quest.id} names section "{tostring(quest.subject)}", which no world has`
					)
				end
			end
		end)

		h.it("names the lobby pad in one place", function()
			--[[
				The server builds the game pads and the client watches for them
				by name to know when to open the settings panel, so the name
				crosses the wire.

				It was written out on both sides. Renaming the pads from
				`TeamPad` to `GamePad` therefore stopped the panel opening
				at all — which is precisely the "nothing happens when I stand
				on the pad" the rebuild existed to fix, reintroduced by the
				rebuild. A shared constant is the fix; this is the guard that
				it stays shared and stays usable.
			]]
			local prefix = GameConfig.LOBBY_PAD_PREFIX
			h.expectTrue(type(prefix) == "string", "the pad prefix should be a string")
			h.expectTrue(#prefix > 0, "an empty prefix would match every part in the lobby")
			h.expectTrue(
				string.match(prefix, "^%a[%w_]*$") ~= nil,
				`pad prefix "{prefix}" should be a plain name, since it is matched against instance names`
			)
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
