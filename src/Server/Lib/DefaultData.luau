--!strict
--[[
	DefaultData — the shape of a saved player profile.

	`template()` returns a fresh deep copy; `migrate()` brings an older save up to
	the current VERSION. Adding a field means adding it to the template and, if
	old saves need a sensible value, handling it in migrate().
]]


local DefaultData = {}

--- Bumped: run state moved out of the profile.
DefaultData.VERSION = 2

export type Stats = {
	tilesCut: number,
	unitsSold: number,
	stripes: number,
	roundsCompleted: number,
	goldenBlades: number,
	treesFelled: number,
}

--[[
	What survives a run.

	Deliberately small. Cash, tools and upgrades are per-run and live in
	RunState, so nothing here can be topped up by playing badly for a long time
	— only records, totals and the worlds you have actually beaten.
]]
export type Profile = {
	version: number,
	--- Worlds the player has finished, keyed by world id.
	worldsBeaten: { [string]: boolean },
	--- Best completion time per world, in seconds.
	bestTimes: { [string]: number },
	--- Lifetime totals, for the lobby leaderboards.
	stats: Stats,
	--- Premium currency, bought with Robux and kept forever.
	tokens: number,
	questProgress: { [string]: number },
	questsDone: { [string]: boolean },
	dailyStreak: number,
	dailyLastClaim: number,
	playtime: number,
	firstCompletionClaimed: boolean,
	musicEnabled: boolean,
	sfxEnabled: boolean,
}

function DefaultData.template(): Profile
	return {
		version = DefaultData.VERSION,
		worldsBeaten = {},
		bestTimes = {},
		stats = {
			tilesCut = 0,
			unitsSold = 0,
			stripes = 0,
			roundsCompleted = 0,
			goldenBlades = 0,
			treesFelled = 0,
		},
		tokens = 0,
		questProgress = {},
		questsDone = {},
		dailyStreak = 0,
		dailyLastClaim = 0,
		playtime = 0,
		firstCompletionClaimed = false,
		musicEnabled = true,
		sfxEnabled = true,
	}
end

--[[
	Repairs a loaded profile in place.

	Runs on every load, not just on a version bump, so a save that predates a
	field or was truncated by an old bug still comes back usable rather than
	erroring deep inside a service.
]]
function DefaultData.migrate(data: any): Profile
	local fresh = DefaultData.template()

	if type(data) ~= "table" then
		return fresh
	end

	for key, value in fresh :: any do
		if data[key] == nil then
			data[key] = value
		end
	end

	for key, value in fresh.stats do
		if type(data.stats[key]) ~= "number" then
			data.stats[key] = value
		end
	end

	-- Cash, tools and upgrades used to be saved here. Strip them: leaving them
	-- behind would be a silent second economy nothing reads.
	for _, stale in { "cash", "tips", "lifetimeCash", "ownedTools", "equippedTool", "upgrades", "unlockedZones", "fuel" } do
		data[stale] = nil
	end

	data.version = DefaultData.VERSION
	return data
end

return DefaultData
