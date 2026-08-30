--!strict
--[[
	DefaultData — the shape of a saved player profile.

	`template()` returns a fresh deep copy; `migrate()` brings an older save up to
	the current VERSION. Adding a field means adding it to the template and, if
	old saves need a sensible value, handling it in migrate().
]]

local GameConfig = require(game:GetService("ReplicatedStorage").Shared.Config.GameConfig)
local Properties = require(game:GetService("ReplicatedStorage").Shared.Config.Properties)
local Tools = require(game:GetService("ReplicatedStorage").Shared.Config.Tools)
local Upgrades = require(game:GetService("ReplicatedStorage").Shared.Config.Upgrades)

local DefaultData = {}

DefaultData.VERSION = 1

export type Stats = {
	tilesCut: number,
	unitsSold: number,
	stripes: number,
	roundsCompleted: number,
	goldenBlades: number,
	treesFelled: number,
}

export type Profile = {
	version: number,
	cash: number,
	tips: number,
	lifetimeCash: number,
	ownedTools: { [string]: boolean },
	equippedTool: string,
	upgrades: { [string]: number },
	--- unlockedZones[propertyId][zoneId] = true
	unlockedZones: { [string]: { [string]: boolean } },
	fuel: number,
	stats: Stats,
	--- Progress counter per quest id, and the ids already finished.
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
	local upgrades: { [string]: number } = {}
	for _, def in Upgrades.list do
		upgrades[def.id] = 0
	end

	-- Every account starts owning the starter tool and the free front yard of
	-- the first property, so a brand new player can mow within seconds of joining.
	local starter = Properties.expect(Properties.STARTER_ID)
	local unlockedZones: { [string]: { [string]: boolean } } = {}
	unlockedZones[starter.id] = { [starter.zones[1].id] = true }

	return {
		version = DefaultData.VERSION,
		cash = GameConfig.STARTING_CASH,
		tips = GameConfig.STARTING_TIPS,
		lifetimeCash = 0,
		ownedTools = { [Tools.STARTER_ID] = true },
		equippedTool = Tools.STARTER_ID,
		upgrades = upgrades,
		unlockedZones = unlockedZones,
		fuel = GameConfig.BASE_FUEL,
		stats = {
			tilesCut = 0,
			unitsSold = 0,
			stripes = 0,
			roundsCompleted = 0,
			goldenBlades = 0,
			treesFelled = 0,
		},
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

	Runs on every load, not just on a version bump, so a save that predates a new
	upgrade line or was truncated by an old bug still comes back usable rather
	than erroring deep inside a service.
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

	-- Fill in upgrade lines and stat counters added since this profile was saved.
	for _, def in Upgrades.list do
		if type(data.upgrades[def.id]) ~= "number" then
			data.upgrades[def.id] = 0
		end
	end
	for key, value in fresh.stats do
		if type(data.stats[key]) ~= "number" then
			data.stats[key] = value
		end
	end

	-- An equipped tool that no longer exists (removed or renamed) falls back to
	-- the starter rather than leaving the player holding nothing.
	if not Tools.get(data.equippedTool) or not data.ownedTools[data.equippedTool] then
		data.equippedTool = Tools.STARTER_ID
		data.ownedTools[Tools.STARTER_ID] = true
	end

	data.version = DefaultData.VERSION
	return data
end

return DefaultData
