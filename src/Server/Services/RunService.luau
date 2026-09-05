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
local Balance = require(Shared.Config.Balance)
local Format = require(Shared.Util.Format)
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)
local Worlds = require(Shared.Config.Worlds)
local BagService = require(script.Parent.BagService)
local Loop = require(Shared.Util.Loop)
local BoostService = require(script.Parent.BoostService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local PlayerService = require(script.Parent.PlayerService)
local RewardService = require(script.Parent.RewardService)
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

--- When the current run began, so wave counts are not relaxed before the team
--- that justified them has finished teleporting in.
local runStartedAt = 0
--- Waves already cleared, per section.
local wavesCleared: { [string]: number } = {}
--- Waves needed, fixed when the run starts so a late joiner cannot inflate it.
local wavesNeeded: { [string]: number } = {}
--- True once the last required section is clear and the grate is open.
local exitOpen = false
--- Sections fully finished (all waves), which is what earns the cash boost.
local sectionsFinished = 0

local roundState: RemoteEvent
--- How often run state is broadcast, in Hz. The client interpolates the clock.
local BROADCAST_HZ = 2
--- Seconds after a run begins before the live player count is trusted over the
--- party size the lobby sent. Long enough for four teleports to land.
local WAVE_RELAX_GRACE = 45
local LOBBY_SECONDS = 20
--- How long past the lobby's clock to wait for a pick before giving up and
--- loading the starter world, so an empty server never sits on the menu.
local LOBBY_IDLE_RESTART = 100

--------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------

function RunService.phase(): Phase
	return phase
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

--- The run-wide cash bonus earned so far: 0.3 per finished section.
function RunService.sectionBoost(): number
	return sectionsFinished * GameConfig.SECTION_CASH_BOOST
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
			open = WorldService.isSectionOpen(section.id),
			optional = section.optional == true,
			wave = wavesCleared[section.id] or 0,
			waves = wavesNeeded[section.id] or 1,
			remaining = if state then state.remainingUnits else 0,
			total = if state then state.totalUnits else 0,
		})
	end
	return out
end

--- The worlds a level select can offer, with what each player has unlocked
--- resolved per player by the client from `beaten`.
local function worldChoices(): { { id: string, name: string, tagline: string, difficulty: string, requires: string? } }
	local out = {}
	for _, world in Worlds.list do
		table.insert(out, {
			id = world.id,
			name = world.name,
			tagline = world.tagline,
			difficulty = world.difficulty,
			requires = world.requiresWorld,
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
		worlds = worldChoices(),
		sections = sectionSnapshot(),
	})
end

RunService.broadcast = broadcast

--------------------------------------------------------------------
-- Gates
--------------------------------------------------------------------

local function openSection(sectionId: string, announce: boolean)
	if WorldService.isSectionOpen(sectionId) then
		return
	end
	WorldService.setSectionOpen(sectionId, true)

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

--- Sections on the critical path that still owe waves, in world order.
local function remainingRequired(world: Types.WorldDef): { Types.ZoneDef }
	local out = {}
	for _, section in Worlds.requiredSections(world) do
		if (wavesCleared[section.id] or 0) < (wavesNeeded[section.id] or 1) then
			table.insert(out, section)
		end
	end
	return out
end

--- True once every section on the critical path has had all its waves cleared.
local function requiredSectionsDone(world: Types.WorldDef): boolean
	return #remainingRequired(world) == 0
end

--[[
	Writes what is still holding the grate shut onto the grate.

	Named while there is one left, counted while there are several. The one
	that matters is the last: The House's Pool Deck is required and sits off
	the completion chain behind a paid gate, so following the chain to its
	end leaves exactly one section outstanding and no indication anywhere of
	which. "Locked — clear the Pool Deck" is the whole fix.
]]
local function refreshExitSign(world: Types.WorldDef)
	local left = remainingRequired(world)
	if #left == 0 then
		-- `openExit` writes the open line; saying it twice is not this job.
		return
	elseif #left == 1 then
		WorldService.setExitStatus(`Locked — clear the {left[1].name}`)
	else
		WorldService.setExitStatus(`Locked — {#left} places left`)
	end
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

	--[[
		Every wave used to tick this, and the quest reads "Clear the Front Yard
		completely" — so on a four-player server, where every section owes four
		waves, the objective completed at a quarter of the section. Below the
		early return now, where the section really is finished.
	]]
	for _, player in Players:GetPlayers() do
		QuestService.advance(player, "clearSection", 1, section.id)
	end

	-- Its own notice kind, because finishing a whole section is the one moment
	-- in a run that earns the middle of everyone's screen rather than a line in
	-- the corner.
	EconomyService.notifyAll(
		"sectionClear",
		`Congratulations! You cleared the whole {section.name}!`,
		nil
	)

	-- The world pays better the more of it you have cleaned. This is the run's
	-- progression spine: the boost applies to everyone, forever, this run —
	-- which is also what makes helping a slower player worth a fast one's time.
	sectionsFinished += 1
	EconomyService.notifyAll(
		"quest",
		`{section.name} completed! Cash boost is now +{math.floor(RunService.sectionBoost() * 100 + 0.5)}%!`,
		nil
	)

	local openedNames = {}
	for _, dependent in dependentsOf(world, section.id) do
		if Worlds.unlockKind(dependent) == "completion" then
			openSection(dependent.id, false)
			table.insert(openedNames, dependent.name)
		end
	end
	-- The unlock rides the completion card rather than being its own toast, as
	-- one moment: you finished this, so you get that.
	for _, name in openedNames do
		EconomyService.notifyAll("sectionUnlock", name, nil)
	end

	if not exitOpen and requiredSectionsDone(world) then
		exitOpen = true
		WorldService.openExit()
		EconomyService.notifyAll("round", "The grate is open. Get out.", nil)
	else
		refreshExitSign(world)
	end

	broadcast()
end

--------------------------------------------------------------------
-- Flow
--------------------------------------------------------------------

local function beginRun(id: string, partySize: number?)
	worldId = id
	runStartedAt = os.clock()
	local world = Worlds.expect(id)

	ReplicationService.reset()
	WorldService.load(id)
	ReplicationService.broadcastWorldInfo()

	WorldService.closeAllSections()
	table.clear(wavesCleared)
	table.clear(wavesNeeded)
	exitOpen = false
	sectionsFinished = 0

	--[[
		Wave counts are fixed at the start. Letting a late joiner raise them
		would move the goalposts on everyone already partway through a section.

		A team assembled on the lobby pads says its own size, because that is
		the whole point of standing on three pads rather than four: the work
		should be the work for three.
	]]
	local playerCount = math.max(partySize or #Players:GetPlayers(), 1)
	for _, section in world.sections do
		wavesNeeded[section.id] = Worlds.wavesFor(section, playerCount)
		wavesCleared[section.id] = 0
	end

	openSection(Worlds.startSection(world).id, false)

	--[[
		Put everybody on the property they are about to play.

		A `SpawnLocation` only places anyone when a character is *loaded*, and
		moving between worlds does not load one — so players stayed exactly
		where the last property left them. Pick The Gas Station from the level
		select after finishing The Mansion and you would arrive standing in the
		middle of nothing, two hundred studs off the new lot, with the property
		you chose somewhere over the horizon.

		Moved rather than reloaded: `LoadCharacter` would place them correctly
		too, but it throws away the character to do it, and there is no reason
		for choosing a property to cost you your avatar for a second.
	]]
	local spawnAt = WorldService.spawnPoint()
	if spawnAt then
		for _, player in Players:GetPlayers() do
			local character = player.Character
			if character and character.PrimaryPart then
				character:PivotTo(spawnAt)
			end
		end
	end

	-- Everyone starts from nothing. That is the whole shape of a run — except
	-- for a rental, which was sold as minutes rather than as a lawn.
	RunState.resetAll()
	-- Both of these outlive the reset because both were bought with Robux:
	-- a rental was sold as minutes, and a run-only tool bought in the lobby
	-- was sold for the run that is only now starting.
	RunState.applyHeldTools()
	BoostService.carryRentals()
	BagService.clearAll()

	phase = "running"
	startedAt = os.clock()
	endsAt = startedAt + world.runSeconds

	-- So the grate is honest from the first minute rather than only after the
	-- first section falls.
	refreshExitSign(world)

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

	--[[
		The contribution split, which nothing ever paid.

		`run.contribution` counts what each player has cut and describes itself
		as being "for the contribution split and the scoreboard";
		`ROUND_COMPLETION_BONUS` is the size of the pool. Neither was read by
		anything, so finishing a property paid nothing at all and a team of
		four rewarded whoever stood still exactly as well as the three who
		mowed.

		The pool scales with the number of people in the run and is divided by
		share of the work, so finishing solo pays the whole of it and a team
		pulling evenly pays it to each of them.
	]]
	local totalContribution = 0
	local runners = 0
	for _, state in RunState.all() do
		totalContribution += state.contribution
		runners += 1
	end

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

		--[[
			The reward for a first clean sweep, which nothing ever called.

			`RewardService.awardFirstCompletion` was written, tested against a
			`firstCompletionClaimed` flag on the profile, and then never
			reached from anywhere: winning a run is the only moment it can be
			paid, and this is that moment.
		]]
		RewardService.awardFirstCompletion(player)

		local run = RunState.find(player)
		if run then
			local earned = Balance.completionTips(run.contribution, totalContribution, runners)
			if earned > 0 then
				EconomyService.awardTips(player, earned)
				EconomyService.notify(
					player,
					"reward",
					`Your share of {Worlds.expect(worldId).name} — {earned} tips`,
					nil
				)
			end
		end

		-- The world just beaten is what unlocks the next one, and the level
		-- select is about to be shown, so the client needs to hear about it
		-- before it draws the rows rather than on the next full push.
		PlayerService.push(player)
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
	EconomyService.notifyAll("round", "Out of time. The grass wins this one.", nil)
	broadcast()
end

--[[
	A player paying a cash gate. Opens the section for everyone: the door is
	one door, and whoever reaches it with the money first holds it open for the
	rest — which is one more way a fast player carries a slow one.
]]
local function onGateTried(player: Player, sectionId: string)
	if phase ~= "running" then
		return
	end

	local world = WorldService.world
	local section = if world then Worlds.section(world, sectionId) else nil
	if not section or Worlds.unlockKind(section) ~= "cash" then
		return
	end
	if WorldService.isSectionOpen(sectionId) then
		return
	end

	-- A gate deeper in the chain cannot be bought early: the door is reachable
	-- only through the section before it, and a teleporting exploiter should
	-- not get further than a walking player.
	if section.requires and not WorldService.isSectionOpen(section.requires) then
		return
	end

	if not EconomyService.spend(player, section.cost) then
		EconomyService.notify(player, "denied", `You need {Format.cash(section.cost)} to open this`, nil)
		return
	end

	openSection(sectionId, false)
	EconomyService.notifyAll("sectionUnlock", section.name, nil)
	broadcast()
end

--[[
	A player flipping a hidden switch. Opens the section it belongs to.

	The switch only counts once the section hiding it is open, so a player who
	finds their way somewhere they have not earned yet cannot skip a gate with
	it. Opening goes through `openSection`, which is what advances the quest
	that waits on this.
]]
local function onSwitchTried(player: Player, sectionId: string)
	if phase ~= "running" then
		return
	end

	local world = WorldService.world
	local section = if world then Worlds.section(world, sectionId) else nil
	if not section or Worlds.unlockKind(section) ~= "button" then
		return
	end
	if WorldService.isSectionOpen(sectionId) then
		return
	end

	local hostId = section.buttonIn
	if hostId and not WorldService.isSectionOpen(hostId) then
		return
	end

	openSection(sectionId, false)
	EconomyService.notifyAll("sectionUnlock", section.name, nil)
	EconomyService.notify(player, "quest", `You found the switch for the {section.name}`, nil)
	broadcast()
end

--[[
	A player picking the next world from the level select.

	Beating a world sends everyone back here rather than dropping them into the
	same lawn again, so this is how a run actually starts once the first one has
	ended. Only worlds the picker has unlocked count — the ladder is
	`requiresWorld`, and the check lives here rather than on the client because
	the client is never trusted with what it may play.
]]

--- A player reaching the open grate finishes the run for everyone.
--[[
	Started by the lobby pads rather than by the menu.

	The pads have already checked that whoever chose the property has unlocked
	it, and they know how many are standing on the team pads, which the menu
	never could.
]]
--[[
	Whether an idle server eventually starts a run by itself.

	It should, on a server that is the game; it must not on one that is the
	lobby, where the backstop would drop everybody standing at the pads into
	The House while they were still reading the plaques.
]]
local autoStart = true

function RunService.setAutoStart(on: boolean)
	autoStart = on
end


function RunService.startFromLobby(worldId: string, partySize: number)
	if phase ~= "lobby" or not Worlds.get(worldId) then
		return
	end
	beginRun(worldId, partySize)
end

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

--[[
	Waves may fall when the hands that justified them leave.

	Wave counts are fixed at the start so a late joiner cannot move the
	goalposts on everyone already partway through a section. That rule is right
	going up and ruinous going down: a server that starts with thirty players
	and drains to five leaves those five owing thirty waves of every section
	against a clock that never moved, which is not hard, it is arithmetic they
	cannot beat. On a public game with fifty-player servers, that is a Tuesday.

	So the count is allowed to come down to what the remaining players justify,
	and never up. A section still in progress keeps at least the wave being
	worked on, so nothing completes by people leaving.
]]
local function relaxWaves()
	if phase ~= "running" then
		return
	end
	local world = WorldService.world
	if not world then
		return
	end

	local playerCount = math.max(#Players:GetPlayers(), 1)
	local changed = false
	for _, section in world.sections do
		local needed = wavesNeeded[section.id] or 1
		local cleared = wavesCleared[section.id] or 0
		if cleared < needed then
			local target = math.max(Worlds.wavesFor(section, playerCount), cleared + 1)
			if target < needed then
				wavesNeeded[section.id] = target
				changed = true
			end
		end
	end

	if changed then
		broadcast()
	end
end

function RunService.start()
	roundState = Remotes.event(Remotes.ROUND_STATE)

	Players.PlayerAdded:Connect(function()
		task.defer(broadcast)
	end)

	-- Someone leaving takes their share of the work with them.
	Players.PlayerRemoving:Connect(function()
		task.defer(relaxWaves)
	end)

	-- Contribution drives the end-of-run split; it is counted from the cut
	-- signal so no other service has to know a run is being scored.
	WorldService.ExitReached:Connect(RunService.reachExit)
	WorldService.GateTried:Connect(onGateTried)
	WorldService.SwitchTried:Connect(onSwitchTried)


	-- Every player's cash multiplier carries the run's section bonus.
	EconomyService.addModifierSource(function(_player: Player)
		return { sectionBoost = RunService.sectionBoost() }
	end)

	TileService.Cut:Connect(function(player: Player, _index: number, _debrisId: number, levels: number)
		local run = RunState.find(player)
		if run then
			run.contribution += levels
		end
	end)

	--[[
		The server opens on the level select, not mid-run.

		It used to call `beginRun` here, so the first player did not arrive at
		a game — they arrived in the middle of one, on a property they never
		picked, with the clock already moving. The menu every run *ends* on is
		the right thing to *start* on too. The starter world is still built
		underneath it, because the lobby is a place you physically stand in:
		with no world loaded there is no spawn, and a player who joined before
		one existed would drop into the void.

		The idle backstop below still starts the starter world by itself if
		nobody picks for long enough, so an unattended public server never
		sits on a menu forever.
	]]
	ReplicationService.reset()
	WorldService.load(Worlds.STARTER_ID)
	ReplicationService.broadcastWorldInfo()
	WorldService.closeAllSections()
	phase = "lobby"
	endsAt = os.clock() + LOBBY_SECONDS
	broadcast()

	Loop.forever("RunService.tick", function()
		task.wait(1 / BROADCAST_HZ)

		local world = WorldService.world
		if phase == "running" and world then
			-- A section can also be emptied by a Clean Sweep or by someone
			-- else, so this is checked on a tick rather than driven off the
			-- cut signal alone.
			for _, section in world.sections do
				if
					WorldService.isSectionOpen(section.id)
					and (wavesCleared[section.id] or 0) < (wavesNeeded[section.id] or 1)
					and isSectionClear(section.id)
				then
					onSectionCleared(world, section)
				end
			end

			--[[
				Waves came down only when somebody left, and a player who
				never arrives never leaves.

				A run server takes its party size from the first player's
				teleport data, so four pads means four waves of every
				section from the first moment — before the other three have
				finished teleporting in, and whether or not they ever do. If
				one of them falls out on the way, the three who made it owe
				a fourth player's work against a clock that never moved, and
				nothing was ever going to tell the run otherwise.

				After a grace long enough for the whole team to land, the
				live count is the honest one. `relaxWaves` only ever lowers,
				and never below the wave being cut, so running it on a tick
				cannot finish a section or move a goalpost upward.
			]]
			if os.clock() - runStartedAt > WAVE_RELAX_GRACE then
				relaxWaves()
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
				--[[
					The run is over, so the numbers from it go.

					A run resets when the next one begins, which is correct and
					is where it has to happen — but it left the gap in between
					showing the finished run's cash, tools and bag to anybody
					standing in the lobby. On the live game the team is
					teleported home to a fresh server and never sees it; play
					it out in one server, as Studio does and as a failed
					teleport would, and the lobby reads as though the last game
					had been saved. The payout is settled by now: `winRun` has
					already read every contribution it needed.
				]]
				RunState.resetAll()
				BagService.clearAll()
				for _, player in Players:GetPlayers() do
					PlayerService.push(player)
				end
				broadcast()
			else
				broadcast()
			end
		else
			-- The lobby is the level select, so it waits to be told what to
			-- play. The timer is only a backstop for an empty server, or
			-- one where nobody picks: it drops back to the starter world
			-- rather than sitting on a menu forever.
			if autoStart and RunService.secondsLeft() <= -LOBBY_IDLE_RESTART then
				beginRun(Worlds.STARTER_ID)
			else
				broadcast()
			end
		end
	end)
end

return RunService
