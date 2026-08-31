--!strict
--[[
	Audio — every sound the game makes.

	The game was silent. Not quietly mixed: there was not one `Sound` instance
	anywhere in it, so a mower cut grass in perfect silence and a felled tree
	landed without a noise. This is the list that fixed that.

	Every cue is a Roblox first-party asset — Pro Sound Effects or APM Music,
	both of which Roblox publishes free for any place. That is a deliberate
	restriction rather than a shortage of choice: audio uploaded by another
	player can be private, or can be taken down, and either way it goes silent
	in someone else's game with nothing in the log to say why. First-party
	assets play anywhere, which is the same reasoning that put mesh ids rather
	than `InsertService` models in the prop catalogue.

	A cue names an asset and how it should sound, not where it comes from. Two
	callers use them: the client, for what only the player who did it should
	hear, and `Build.sound`, for a noise that belongs to a place in the world
	and should get quieter as you walk away from it.
]]

local Audio = {}

export type Cue = {
	id: string,
	volume: number,
	--- Loops until stopped. Engine noise does; a chop does not.
	looped: boolean?,
	--- Base playback speed, for pitching a sample away from its recording.
	speed: number?,
	--- Random pitch either side of `speed`, so a sound repeated many times a
	--- second does not turn into a machine-gun of the identical waveform.
	spread: number?,
	--- How far away a positional cue can still be heard, in studs. Absent for
	--- cues that play flat in the player's ears.
	range: number?,
}

local function cue(id: string, volume: number, extra: { [string]: any }?): Cue
	local it: Cue = { id = `rbxassetid://{id}`, volume = volume }
	if extra then
		it.looped = extra.looped
		it.speed = extra.speed
		it.spread = extra.spread
		it.range = extra.range
	end
	return it
end

local cues: { [string]: Cue } = {
	--[[
		The work itself.

		Cutting fires up to ten times a second while the button is held, which
		is why these two alternate and why both are pitched about randomly: one
		rustle on repeat at a fixed pitch stops sounding like leaves within a
		second and starts sounding like a fault.
	]]
	Cut = cue("9114519078", 0.35, { speed = 1.6, spread = 0.22 }),
	CutAlt = cue("9114518577", 0.35, { speed = 1.5, spread = 0.22 }),
	--- Held under a mower for as long as one is cutting.
	MowerLoop = cue("9112787518", 0.28, { looped = true, speed = 0.85 }),

	-- Trees, which are the loudest thing a player does.
	Chop = cue("9120950231", 0.75, { speed = 0.9, spread = 0.12, range = 90 }),
	Timber = cue("9113581598", 0.9, { speed = 0.75, range = 150 }),
	Grind = cue("9118629291", 0.6, { speed = 0.8, spread = 0.15, range = 70 }),

	--- A sprinkler, running for as long as its head is up.
	Sprinkler = cue("9114438571", 0.35, { looped = true, speed = 1.1, range = 60 }),

	-- Money and menus.
	Sell = cue("9117273512", 0.5, { speed = 1.15 }),
	Click = cue("9119730203", 0.45, { speed = 1.0 }),
	Win = cue("1839881844", 0.5, {}),
}

Audio.cues = cues

--- The cue by name, or nil when nothing answers to it.
function Audio.get(name: string): Cue?
	return cues[name]
end

return Audio
