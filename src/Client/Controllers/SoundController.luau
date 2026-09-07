--!strict
--[[
	SoundController — what the player who did it hears.

	Two kinds of noise in this game. A tree falling belongs to a place, and
	everyone near it should hear it fade with distance; that is `Build.sound`,
	on the server. Everything here is the other kind: your own cut, your own
	sale, the sting when you clear a property. It plays flat in your ears at
	the same volume wherever you are standing, because it is about you rather
	than about somewhere.

	One-shots come from a pool. Cutting fires up to ten times a second and each
	`Sound` is an instance the engine has to build and collect, so they are
	reused; a cue that is still audible is left alone and the next free one is
	taken, which is what lets two rustles overlap instead of one cutting the
	other off mid-sample.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Audio = require(Shared.Config.Audio)
local Remotes = require(Shared.Remotes)
local Worlds = require(Shared.Config.Worlds)

local SoundController = {}

--- How many one-shots can overlap before the oldest is cut off. Above this the
--- sound is a wash anyway and the parts are pure cost.
local POOL_SIZE = 8

local holder: Folder
local pool: { Sound } = {}
local nextSlot = 1
local loops: { [string]: Sound } = {}
local rng = Random.new()

--- Applies a cue's shape to a `Sound`. The pitch is rolled per play, not per
--- sound, so the same pooled instance is a different rustle each time.
local function dress(sound: Sound, def: Audio.Cue)
	sound.SoundId = def.id
	sound.Volume = def.volume
	local speed = def.speed or 1
	local spread = def.spread or 0
	sound.PlaybackSpeed = if spread > 0 then speed + rng:NextNumber(-spread, spread) else speed
end

--[[
	Whether the game is allowed to make a noise.

	One gate, here, rather than a check at every call site. Everything that
	makes a sound goes through `play` or `setLoop`, so muting is a property
	of the speaker and not something thirty callers have to remember.
]]
local muted = false

--- The background track and the routine that pauses it. Declared here because
--- `setMuted` below is written before either exists.
local music: Sound? = nil
--[[
	Which list is playing, so the round state can swap it.

	The day list is the default because the lobby is a Saturday morning and
	that is where every session starts.
]]
local activeTracks: { { id: string, name: string } } = Audio.music.tracks
local applyMusicMute: () -> ()
--- The shuffled order of `Audio.music.tracks`, and how far through it we are.
local order: { number } = {}
local atTrack = 0
--- Bumped every time a track is started, so a watchdog armed for one track
--- does not fire against the track that replaced it.
local generation = 0
local playNext: () -> ()

--- Silences or restores every cue. Loops already running are stopped at once
--- rather than left playing until whatever drives them next changes its mind.
function SoundController.setMuted(on: boolean)
	if muted == on then
		return
	end
	muted = on
	if on then
		for _, sound in loops do
			sound:Stop()
		end
	end
	applyMusicMute()
end

function SoundController.isMuted(): boolean
	return muted
end

--- Plays a cue once. Unknown names are ignored rather than raising: a missing
--- sound should never be what stops a cut from registering.
function SoundController.play(name: string)
	local def = Audio.get(name)
	if muted or not def or not holder then
		return
	end

	--[[
		Round-robin rather than "find one that is not playing".

		Looking for a free slot sounds tidier but starves under exactly the
		condition that matters: hold the mow button and every slot is always
		busy, so nothing would ever play. Taking the next slot in turn means
		the oldest overlapping sound is the one that gets cut short.
	]]
	local sound = pool[nextSlot]
	nextSlot = nextSlot % POOL_SIZE + 1
	if not sound then
		return
	end

	dress(sound, def)
	sound:Play()
end

--[[
	Starts or stops a looping cue, by name.

	Idempotent on purpose. The mower loop is driven from "am I mowing right
	now", which is asked every frame, so this is called far more often than the
	answer actually changes.
]]
function SoundController.setLoop(name: string, on: boolean)
	if muted then
		on = false
	end
	local def = Audio.get(name)
	if not def or not holder then
		return
	end

	local existing = loops[name]
	if not on then
		if existing and existing.IsPlaying then
			existing:Stop()
		end
		return
	end

	if existing and existing.IsPlaying then
		return
	end

	local sound: Sound
	if existing then
		sound = existing
	else
		sound = Instance.new("Sound")
		sound.Name = name
		sound.Parent = holder
		loops[name] = sound
	end
	dress(sound, def)
	sound.Looped = true
	sound:Play()
end

--[[
	The background track, which is not a cue.

	Cues are fired at moments and come from a round-robin pool. Music is one
	Sound that starts when the client does and never stops, so it lives
	beside the pool rather than in it — taking a pool slot would mean the
	next cut silenced the music.
]]
--[[
	The next track in the shuffle.

	`Looped` is off and this is hung on `Ended`, so the six tracks play through
	and then reshuffle. The reshuffle matters more than it sounds: without it
	the list would run in the same order for ever, and the first track would
	be the one every player heard while they were still reading the loading
	screen, every session.

	The watchdog is there because `Ended` is the only thing advancing this. If
	an id ever stops resolving — pulled, moderated, or simply a bad day for the
	CDN — `Play` quietly does nothing, `Ended` never fires, and the music is
	gone for the rest of the session with nothing in the log to say why. Fifteen
	seconds of a track that will not start is enough to give up on it and take
	the next one.
]]
function playNext()
	local track = music
	if not track then
		return
	end

	atTrack += 1
	if atTrack > #order then
		for i = #order, 2, -1 do
			local j = math.random(i)
			order[i], order[j] = order[j], order[i]
		end
		atTrack = 1
	end

	local def = activeTracks[order[atTrack]]
	if not def then
		return
	end

	generation += 1
	local mine = generation
	track.SoundId = def.id
	if not muted then
		track:Play()
	end

	task.delay(15, function()
		if mine == generation and not muted and not track.IsPlaying then
			playNext()
		end
	end)
end

function applyMusicMute()
	local track = music
	if not track then
		return
	end
	if muted then
		track:Pause()
	elseif not track.IsPlaying then
		--[[
			Resumed rather than restarted.

			`Play` on a paused Sound begins again from zero, so a player
			toggling sound off and on would hear the first bar of the track
			every time. `Resume` picks it up where it was.
		]]
		track:Resume()
	end
end

function SoundController.start()
	holder = Instance.new("Folder")
	holder.Name = "MowSounds"
	holder.Parent = SoundService

	for index = 1, POOL_SIZE do
		local sound = Instance.new("Sound")
		sound.Name = `Shot{index}`
		sound.Parent = holder
		pool[index] = sound
	end

	local track = Instance.new("Sound")
	track.Name = "Music"
	track.Volume = Audio.music.volume
	track.Looped = false
	track.Parent = holder
	music = track

	for index = 1, #activeTracks do
		order[index] = index
	end
	-- Starts at the end so the first `playNext` shuffles before it picks,
	-- rather than always opening on the first track in the config.
	atTrack = #order
	track.Ended:Connect(function()
		playNext()
	end)
	playNext()

	--[[
		The bed follows the property, but only while it is being played.

		The world def carries the mood, so the list is chosen from it — but not
		from the world alone. A run that ends does not reload the starter
		property or re-announce the world, so on a server that plays the next
		round out in place rather than teleporting everyone home, the finished
		world is still what the client thinks it is standing in. Keyed on the
		world by itself, a game of the Cemetery would leave its drones playing
		over the lobby for as long as anybody stayed. The phase says whether
		the property is actually underfoot.
	]]
	Remotes.event(Remotes.ROUND_STATE).OnClientEvent:Connect(function(state: any)
		if type(state) ~= "table" then
			return
		end
		local world = if type(state.worldId) == "string" then Worlds.get(state.worldId) else nil
		local night = state.phase == "running" and world ~= nil and world.mood == "night"
		local wanted = if night then Audio.music.night else Audio.music.tracks
		if wanted == activeTracks then
			return
		end
		activeTracks = wanted
		table.clear(order)
		for index = 1, #activeTracks do
			order[index] = index
		end
		-- At the end, so the next call shuffles before it picks rather than
		-- always opening a night on the same drone.
		atTrack = #order
		playNext()
	end)
end

return SoundController
