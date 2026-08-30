--!strict
--[[
	RunService — the run: sections, gates, waves, the exit and the clock.

	A world is a chain. You arrive at the first section with nothing, clear it,
	and the gate to the next opens. Clear the last one and the grate at the back
	opens; walk through it and you have beaten the world.

	Waves are what makes a full server work rather than trivialise it: a section
	needs one clear per player, refilling in between, so eight people do eight
	times the work rather than finishing in an eighth of the time.

	Section gates open for the whole run at once, not per player. Co-op means
	everyone is working the same property.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)
local Worlds = require(Shared.Config.Worlds)
local BagService = require(script.Parent.BagService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local QuestService = require(script.Parent.QuestService)
local ReplicationService = require(script.Parent.ReplicationService)
local RunState = require(script.Parent.RunState)
local TileService = require(script.Parent.TileService)
local WorldService = require(script.Parent.WorldService)

local RunService = {}

export type Phase = "lobby" | "running" | "won" | "lost"

local phase: Phase = "lobby"
local worldId = Worlds.STARTER_ID
local endsAt = 0
local startedAt = 0
--- Section ids whose gate is open for this run.
local openSections: { [string]: boolean } = {}
--- Waves already cleared, per section.
local wavesCleared: { [string]: number } = {}
--- Waves needed, fixed when the run starts so a late joiner cannot inflate it.
local wavesNeeded: { [string]: number } = {}
--- True once the last required section is clear and the grate is open.
local exitOpen = false

local roundState: RemoteEvent
--- How often run state is broadcast, in Hz. The client interpolates the clock.
local BROADCAST_HZ = 2
local LOBBY_SECONDS = 20

--------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------

function RunService.phase(): Phase
	return phase
end

function RunService.isSectionOpen(sectionId: string): boolean
	return openSections[sectionId] == true
end

function RunService.secondsLeft(): number
	return math.max(endsAt - os.clock(), 0)
end

function RunService.elapsed(): number
	return math.max(os.clock() - startedAt, 0)
end

function RunService.isExitOpen(): boolean
	return exitOpen
end

function RunService.worldId(): string
	return worldId
end

local function sectionSnapshot(): { any }
	local world = WorldService.world
	if not world then
		return {}
	end

	local out = {}
	for _, section in world.sections do
		local state = WorldService.sections[section.id]
		table.insert(out, {
			id = section.id,
			name = section.name,
			open = openSections[section.id] == true,
			optional = section.optional == true,
			wave = wavesCleared[section.id] or 0,
			waves = wavesNeeded[section.id] or 1,
			remaining = if state then state.remainingUnits else 0,
			total = if state then state.totalUnits else 0,
		})
	end
	return out
end

local function broadcast()
	local world = WorldService.world
	roundState:FireAllClients({
		phase = phase,
		secondsLeft = RunService.secondsLeft(),
		completion = WorldService.completion(),
		worldId = if world then world.id else "",
		worldName = if world then world.name else "",
		exitOpen = exitOpen,
		sections = sectionSnapshot(),
	})
end

RunService.broadcast = broadcast

--------------------------------------------------------------------
-- Gates
--------------------------------------------------------------------

local function openSection(sectionId: string, announce: boolean)
	if openSections[sectionId] then
		return
	end
	openSections[sectionId] = true

	local world = WorldService.world
	local section = if world then Worlds.section(world, sectionId) else nil
	if announce and section then
		EconomyService.notifyAll("round", `The gate to the {section.name} is open`, nil)
	end

	for _, player in Players:GetPlayers() do
		QuestService.advance(player, "section", 1, sectionId)
	end
end

RunService.openSection = openSection

--- True once a section holds no debris at all.
local function isSectionClear(sectionId: string): boolean
	local state = WorldService.sections[sectionId]
	if not state then
		return false
	end
	return state.totalUnits <= 0 or state.remainingUnits <= 0
end

--- Sections whose prerequisite is this one.
local function dependentsOf(world: Types.WorldDef, sectionId: string): { Types.ZoneDef }
	local out = {}
	for _, section in world.sections do
		if section.requires == sectionId then
			table.insert(out, section)
		end
	end
	return out
end

--- True once every section on the critical path has had all its waves cleared.
local function requiredSectionsDone(world: Types.WorldDef): boolean
	for _, section in Worlds.requiredSections(world) do
		if (wavesCleared[section.id] or 0) < (wavesNeeded[section.id] or 1) then
			return false
		end
	end
	return true
end

--[[
	Called when a section runs out of debris.

	If it still owes waves it fills straight back up; otherwise its gate work is
	done and whatever it was holding shut opens.
]]
local function onSectionCleared(world: Types.WorldDef, section: Types.ZoneDef)
	local cleared = (wavesCleared[section.id] or 0) + 1
	wavesCleared[section.id] = cleared
	local needed = wavesNeeded[section.id] or 1

	for _, player in Players:GetPlayers() do
		QuestService.advance(player, "clearSection", 1, section.id)
	end

	if cleared < needed then
		-- More hands, more passes. Fill it again and say so plainly.
		WorldService.refillSection(section.id)
		EconomyService.notifyAll(
			"round",
			`{section.name} — wave {cleared + 1} of {needed}`,
			nil
		)
		broadcast()
		return
	end

	EconomyService.notifyAll("round", `{section.name} is clear`, nil)

	for _, dependent in dependentsOf(world, section.id) do
		if Worlds.unlockKind(dependent) == "completion" then
			openSection(dependent.id, true)
		end
	end

	if not exitOpen and requiredSectionsDone(world) then
		exitOpen = true
		WorldService.openExit()
		EconomyService.notifyAll("round", "The grate is open. Get out.", nil)
	end

	broadcast()
end

--------------------------------------------------------------------
-- Flow
--------------------------------------------------------------------

local function beginRun(id: string)
	worldId = id
	local world = Worlds.expect(id)

	ReplicationService.reset()
	WorldService.load(id)
	ReplicationService.broadcastWorldInfo()

	table.clear(openSections)
	table.clear(wavesCleared)
	table.clear(wavesNeeded)
	exitOpen = false

	-- Wave counts are fixed at the start. Letting a late joiner raise them would
	-- move the goalposts on everyone already partway through a section.
	local playerCount = math.max(#Players:GetPlayers(), 1)
	for _, section in world.sections do
		wavesNeeded[section.id] = Worlds.wavesFor(section, playerCount)
		wavesCleared[section.id] = 0
	end

	openSection(Worlds.startSection(world).id, false)

	-- Everyone starts from nothing. That is the whole shape of a run.
	RunState.resetAll()
	BagService.clearAll()

	phase = "running"
	startedAt = os.clock()
	endsAt = startedAt + world.runSeconds

	EconomyService.notifyAll("round", `{world.name} — {world.tagline}`, nil)
	broadcast()
end

RunService.beginRun = beginRun

--- Ends the run in victory and records the time.
local function winRun()
	if phase ~= "running" then
		return
	end
	phase = "won"
	local elapsed = RunService.elapsed()
	endsAt = os.clock() + GameConfig.INTERMISSION_SECONDS

	EconomyService.notifyAll("round", `Beaten in {Format.clock(elapsed)}`, nil)

	for _, player in Players:GetPlayers() do
		DataService.withProfile(player, function(profile)
			profile.worldsBeaten[worldId] = true
			profile.stats.roundsCompleted += 1

			local best = profile.bestTimes[worldId]
			if not best or elapsed < best then
				profile.bestTimes[worldId] = elapsed
				EconomyService.notify(player, "reward", `New best: {Format.clock(elapsed)}`, nil)
			end
		end)
	end

	broadcast()
end

RunService.winRun = winRun

local function loseRun()
	if phase ~= "running" then
		return
	end
	phase = "lost"
	endsAt = os.clock() + GameConfig.INTERMISSION_SECONDS
	EconomyService.notifyAll("round", "Out of time. The leaves win this one.", nil)
	broadcast()
end

--- A player reaching the open grate finishes the run for everyone.
function RunService.reachExit(player: Player)
	if phase ~= "running" or not exitOpen then
		return
	end
	EconomyService.notifyAll("round", `{player.DisplayName} made it out`, nil)
	winRun()
end

--- Adds time to the clock. Used by the round-time product.
function RunService.extend(seconds: number)
	if phase == "running" then
		endsAt += seconds
		broadcast()
	end
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

function RunService.start()
	roundState = Remotes.event(Remotes.ROUND_STATE)

	Players.PlayerAdded:Connect(function()
		task.defer(broadcast)
	end)

	-- Contribution drives the end-of-run split; it is counted from the cut
	-- signal so no other service has to know a run is being scored.
	TileService.Cut:Connect(function(player: Player, _index: number, _debrisId: number, levels: number)
		local run = RunState.find(player)
		if run then
			run.contribution += levels
		end
	end)

	beginRun(Worlds.STARTER_ID)

	task.spawn(function()
		while true do
			task.wait(1 / BROADCAST_HZ)

			local world = WorldService.world
			if phase == "running" and world then
				-- A section can also be emptied by a Clean Sweep or by someone
				-- else, so this is checked on a tick rather than driven off the
				-- cut signal alone.
				for _, section in world.sections do
					if
						openSections[section.id]
						and (wavesCleared[section.id] or 0) < (wavesNeeded[section.id] or 1)
						and isSectionClear(section.id)
					then
						onSectionCleared(world, section)
					end
				end

				if RunService.secondsLeft() <= 0 then
					loseRun()
				else
					broadcast()
				end
			elseif phase == "won" or phase == "lost" then
				if RunService.secondsLeft() <= 0 then
					phase = "lobby"
					endsAt = os.clock() + LOBBY_SECONDS
					broadcast()
				else
					broadcast()
				end
			else
				if RunService.secondsLeft() <= 0 then
					beginRun(worldId)
				else
					broadcast()
				end
			end
		end
	end)
end

return RunService
