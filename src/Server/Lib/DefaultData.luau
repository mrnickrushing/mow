--!strict
--[[
	DefaultData — the shape of a saved player profile.

	`template()` returns a fresh deep copy; `migrate()` brings an older save up to
	the current VERSION. Adding a field means adding it to the template and, if
	old saves need a sensible value, handling it in migrate().
]]


local DefaultData = {}

--- Bumped: the opening plays once and the profile remembers it.
DefaultData.VERSION = 5

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
	--[[
		Tips: the currency you earn by turning up and by playing well.

		Four things paid these out — clean stripes, Golden Blades,
		the daily login streak and a trickle for time played — into `RunState`,
		which a run start wipes, and nothing in the game had a price in them.
		A login streak that is gone by the next round is not a login streak,
		so they live here, where they last, and they buy permanent tools.

		Deliberately not cash. Every run starts from nothing and the ladder is
		priced in single dollars because of it; handing a returning player a
		pile of money would buy the first half of that ladder before they had
		cut a blade of grass.
	]]
	tips: number,
	--- Tools bought outright with Robux. Handed back at the start of every run,
	--- which is the only thing besides records that outlives one.
	permanentTools: { [string]: boolean },
	--[[
		Robux receipts already granted, newest last.

		Roblox retries `ProcessReceipt` until it is told the purchase was
		granted, and a server that dies in the moment between granting and
		answering will be asked again by the next one. Without a record of what
		has already been paid out, that second ask grants the product a second
		time — free goods, on a real transaction. Keeping the ids is what makes
		granting idempotent.

		Trimmed to the most recent `RECEIPT_MEMORY`: Roblox stops retrying long
		before that, and a profile that grows forever eventually stops saving.
	]]
	receipts: { string },
	questProgress: { [string]: number },
	questsDone: { [string]: boolean },
	dailyStreak: number,
	dailyLastClaim: number,
	playtime: number,
	firstCompletionClaimed: boolean,
	--- Whether this player has seen the opening. Shown once, then never again.
	introSeen: boolean,
	--- True once the game has explained what tips are, which it does the first
	--- time one is earned.
	tipsExplained: boolean,
	musicEnabled: boolean,
	sfxEnabled: boolean,
}

--- How many past receipts a profile remembers. Roblox gives up retrying a
--- receipt within a day; this is far more than enough to outlast that.
DefaultData.RECEIPT_MEMORY = 50

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
		tips = 0,
		permanentTools = {},
		receipts = {},
		questProgress = {},
		questsDone = {},
		dailyStreak = 0,
		dailyLastClaim = 0,
		playtime = 0,
		firstCompletionClaimed = false,
		introSeen = false,
		tipsExplained = false,
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

	--[[
		Backfill anything missing, and replace anything of the wrong shape.

		A missing field was the only case this handled, which is the common
		one — a save written before a field existed. The dangerous one is a
		field that is present and wrong: `stats` arriving as anything but a
		table makes the loop below index a non-table and throw, and a profile
		that throws while loading is a profile that never loads. In the lobby
		that player is `waiting` forever, standing on a pad that will not
		start, with no way to tell why. Matching the template's type costs one
		comparison and takes the whole class off the table.
	]]
	for key, value in fresh :: any do
		if typeof(data[key]) ~= typeof(value) then
			data[key] = value
		end
	end

	if type(data.permanentTools) ~= "table" then
		data.permanentTools = {}
	end

	if type(data.receipts) ~= "table" then
		data.receipts = {}
	end

	for key, value in fresh.stats do
		if type(data.stats[key]) ~= "number" then
			data.stats[key] = value
		end
	end

	-- Cash, tools and upgrades used to be saved here. Strip them: leaving them
	-- behind would be a silent second economy nothing reads. Tips came off this
	-- list when they became the thing that outlives a run.
	for _, stale in { "cash", "lifetimeCash", "ownedTools", "equippedTool", "upgrades", "unlockedZones", "fuel" } do
		data[stale] = nil
	end

	if type(data.tips) ~= "number" then
		data.tips = 0
	end

	data.version = DefaultData.VERSION
	return data
end

return DefaultData
