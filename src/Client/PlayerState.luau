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
local Grid = require(Shared.Grid)
local Worlds = require(Shared.Config.Worlds)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)

local PlayerState = {}

--- How often, and how many times, to ask the server which world this is.
local WORLD_INFO_ASK_INTERVAL = 1
local WORLD_INFO_ASK_TRIES = 30

export type State = {
	cash: number,
	tips: number,
	earned: number,
	bagWeight: number,
	bagCapacity: number,
	bagValue: number,
	--- Upgrades, passes and boosts stacked. Shown next to the cash so a bought
	--- upgrade is visible as a number that went up, not only as faster earning.
	cashMultiplier: number,
	fuel: number,
	fuelCapacity: number,
	equippedTool: string,
	ownedTools: { [string]: boolean },
	permanentTools: { [string]: boolean },
	upgrades: { [string]: number },

	walkSpeed: number,
	dumpRadius: number,
	hasPortableTrailer: boolean,
	rentalSecondsLeft: number,
	rentalToolId: string,
	--- Worlds finished, which is what the level select locks its rows on.
	worldsBeaten: { [string]: boolean },
}

local state: State = {
	cash = 0,
	tips = 0,
	earned = 0,
	bagWeight = 0,
	bagCapacity = 0,
	bagValue = 0,
	cashMultiplier = 1,
	fuel = 0,
	fuelCapacity = 0,
	equippedTool = "",
	ownedTools = {},
	permanentTools = {},
	upgrades = {},

	walkSpeed = 16,
	dumpRadius = 12,
	hasPortableTrailer = false,
	rentalSecondsLeft = 0,
	rentalToolId = "",
	worldsBeaten = {},
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

--- The loaded world's grid, for anything that needs to turn a position into a
--- tile. Nil until the first world info arrives.
function PlayerState.grid(): Grid.Grid?
	return grid
end

--- The section containing a world position, or "" when outside every section.
function PlayerState.sectionIdAtPosition(position: Vector3): string
	local currentGrid = grid
	if not currentGrid then
		return ""
	end
	local tx, tz = Grid.worldToTile(currentGrid, position.X, position.Z)
	if not Grid.inBounds(currentGrid, tx, tz) then
		return ""
	end
	return PlayerState.sectionIdAt(Grid.toIndex(currentGrid, tx, tz))
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
	local FAST = {
		"cash",
		"tips",
		"earned",
		"bagWeight",
		"bagCapacity",
		"bagValue",
		"cashMultiplier",
		"fuel",
		"rentalSecondsLeft",
	}
	for _, key in FAST do
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
		if type(payload.permanentTools) == "table" then
			state.permanentTools = payload.permanentTools
		end
		if type(payload.ownedTools) == "table" then
			state.ownedTools = payload.ownedTools
		end
		if type(payload.upgrades) == "table" then
			state.upgrades = payload.upgrades
		end
		if type(payload.worldsBeaten) == "table" then
			state.worldsBeaten = payload.worldsBeaten
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

	-- The server sends this once when you join and once when a run begins, and
	-- the handler above may well not exist yet at either moment. Ask for it,
	-- and keep asking until it arrives, rather than run the whole session
	-- without ever knowing which world this is.
	task.spawn(function()
		for _ = 1, WORLD_INFO_ASK_TRIES do
			if world then
				return
			end
			worldInfo:FireServer()
			task.wait(WORLD_INFO_ASK_INTERVAL)
		end
	end)
end

return PlayerState
