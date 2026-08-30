--!strict
--[[
	PlayerState — the client's view of itself and the world.

	The server pushes a full payload when something structural changes and a
	small partial payload several times a second for cash and bag weight. This
	module merges the two, derives the values every controller keeps asking for,
	and fires one signal when anything moves.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Grid = require(Shared.Grid)
local Worlds = require(Shared.Config.Worlds)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)

local PlayerState = {}

export type State = {
	cash: number,
	tips: number,
	earned: number,
	bagWeight: number,
	bagCapacity: number,
	bagValue: number,
	fuel: number,
	fuelCapacity: number,
	equippedTool: string,
	ownedTools: { [string]: boolean },
	upgrades: { [string]: number },

	walkSpeed: number,
	dumpRadius: number,
	hasPortableTrailer: boolean,
	rentalSecondsLeft: number,
	rentalToolId: string,
	--- Derived locally from `upgrades`.
	cutRateMultiplier: number,
}

local state: State = {
	cash = 0,
	tips = 0,
	earned = 0,
	bagWeight = 0,
	bagCapacity = 0,
	bagValue = 0,
	fuel = 0,
	fuelCapacity = 0,
	equippedTool = "",
	ownedTools = {},
	upgrades = {},

	walkSpeed = 16,
	dumpRadius = 12,
	hasPortableTrailer = false,
	rentalSecondsLeft = 0,
	rentalToolId = "",
	cutRateMultiplier = 1,
}

local world: Types.WorldDef? = nil
local grid: Grid.Grid? = nil
local totalUnits = 0

local changedSignal = Instance.new("BindableEvent")
PlayerState.Changed = changedSignal.Event

local worldSignal = Instance.new("BindableEvent")
PlayerState.WorldChanged = worldSignal.Event

local sectionsSignal = Instance.new("BindableEvent")
PlayerState.SectionsChanged = sectionsSignal.Event

function PlayerState.get(): State
	return state
end

function PlayerState.world(): Types.WorldDef?
	return world
end

function PlayerState.totalUnits(): number
	return totalUnits
end

--- The section a tile belongs to, or "" for ground outside every section.
--- Derived from the shared world config rather than replicated per tile.
function PlayerState.sectionIdAt(index: number): string
	local currentGrid = grid
	local currentWorld = world
	if not currentGrid or not currentWorld then
		return ""
	end
	local tx, tz = Grid.fromIndex(currentGrid, index)
	local section = Worlds.sectionAt(currentWorld, tx, tz)
	return if section then section.id else ""
end

--[[
	Sections whose gate is open this run.

	Replicated with the run state rather than the player state, because gates
	open for everyone at once — there is no per-player ownership any more.
]]
local openSections: { [string]: boolean } = {}

function PlayerState.setOpenSections(sections: { [string]: boolean })
	openSections = sections
	sectionsSignal:Fire(openSections)
end

function PlayerState.openSections(): { [string]: boolean }
	return openSections
end

function PlayerState.isSectionOpen(sectionId: string): boolean
	return sectionId ~= "" and openSections[sectionId] == true
end

function PlayerState.bagFraction(): number
	if state.bagCapacity <= 0 then
		return 0
	end
	return math.clamp(state.bagWeight / state.bagCapacity, 0, 1)
end

local function applyPayload(payload: any)
	if type(payload) ~= "table" then
		return
	end

	-- A partial push carries only the fast-moving numbers; everything else on
	-- the state is left exactly as the last full push set it.
	for _, key in { "cash", "tips", "earned", "bagWeight", "bagCapacity", "bagValue", "fuel", "rentalSecondsLeft" } do
		if type(payload[key]) == "number" then
			(state :: any)[key] = payload[key]
		end
	end

	if not payload.partial then
		for _, key in { "fuelCapacity", "walkSpeed", "dumpRadius" } do
			if type(payload[key]) == "number" then
				(state :: any)[key] = payload[key]
			end
		end
		if type(payload.equippedTool) == "string" then
			state.equippedTool = payload.equippedTool
		end
		if type(payload.rentalToolId) == "string" then
			state.rentalToolId = payload.rentalToolId
		end
		if type(payload.ownedTools) == "table" then
			state.ownedTools = payload.ownedTools
		end
		if type(payload.upgrades) == "table" then
			state.upgrades = payload.upgrades
			state.cutRateMultiplier = Balance.cutRateMultiplier(payload.upgrades)
		end

		state.hasPortableTrailer = payload.hasPortableTrailer == true
	end

	changedSignal:Fire(state)
end

function PlayerState.start()
	local playerState = Remotes.event(Remotes.PLAYER_STATE)
	local worldInfo = Remotes.event(Remotes.WORLD_INFO)

	playerState.OnClientEvent:Connect(applyPayload)

	worldInfo.OnClientEvent:Connect(function(info: any)
		if type(info) ~= "table" or type(info.worldId) ~= "string" then
			return
		end
		world = Worlds.get(info.worldId)
		if type(info.width) == "number" and type(info.depth) == "number" then
			grid = Grid.new(info.width, info.depth)
		end
		totalUnits = if type(info.totalUnits) == "number" then info.totalUnits else 0
		worldSignal:Fire(world)
	end)
end

return PlayerState
