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
end

return SoundController
