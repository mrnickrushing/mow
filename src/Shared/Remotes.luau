--!strict
--[[
	Remotes — lazily created, named remote instances shared by both sides.

	The server creates the folder and the instances; clients wait for them. Every
	remote is listed here so the network surface is one readable file rather than
	scattered WaitForChild calls.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

local FOLDER_NAME = "MowRemotes"

--- Fired by the client ~10x/second while mowing. Server validates and applies.
Remotes.MOW_INTENT = "MowIntent"
--- Server -> client: a batch of dirty chunks as a packed buffer.
Remotes.CHUNK_DELTA = "ChunkDelta"
--- Client -> server: "I need the full state of these chunks."
Remotes.REQUEST_CHUNKS = "RequestChunks"
--- Server -> client: world metadata (grid size, property id) on join/rotate.
Remotes.WORLD_INFO = "WorldInfo"
--- Server -> client: this player's bag, cash, tips, fuel and stats.
Remotes.PLAYER_STATE = "PlayerState"
--- Client -> server: buy an upgrade, tool or zone.
Remotes.PURCHASE = "Purchase"
--- Client -> server: equip a tool the player owns.
Remotes.EQUIP = "Equip"
--- Client -> server: dump the bag at a nearby trailer.
Remotes.DUMP = "Dump"
--- Server -> client: round timer, completion percentage and scoreboard.
Remotes.ROUND_STATE = "RoundState"
--- Server -> client: transient feedback (stripe banked, tool stalled, sale made).
Remotes.NOTIFY = "Notify"
--- Client -> server: prompt a Robux purchase.
Remotes.PROMPT_PURCHASE = "PromptPurchase"
--- Client -> server: park or recall the portable trailer.
Remotes.PLACE_TRAILER = "PlaceTrailer"
--- Client -> server: mount or dismount a vehicle.
Remotes.VEHICLE = "Vehicle"
--- Client -> server: interact with a tree, stump or chipper.
Remotes.INTERACT = "Interact"

local UNRELIABLE: { [string]: boolean } = {
	[Remotes.MOW_INTENT] = true,
}

local EVENTS = {
	Remotes.MOW_INTENT,
	Remotes.CHUNK_DELTA,
	Remotes.REQUEST_CHUNKS,
	Remotes.WORLD_INFO,
	Remotes.PLAYER_STATE,
	Remotes.PURCHASE,
	Remotes.EQUIP,
	Remotes.DUMP,
	Remotes.ROUND_STATE,
	Remotes.NOTIFY,
	Remotes.PROMPT_PURCHASE,
	Remotes.PLACE_TRAILER,
	Remotes.VEHICLE,
	Remotes.INTERACT,
}

local folder: Folder? = nil

--- Server-side: build the remote folder. Safe to call more than once.
function Remotes.init(): Folder
	assert(RunService:IsServer(), "Remotes.init must run on the server")
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		folder = existing
		return existing
	end

	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME

	for _, name in EVENTS do
		-- Mow intents are a high-frequency stream where a dropped packet costs
		-- nothing, so they ride an unreliable channel and stay out of the way of
		-- ordered traffic like purchases.
		local remote: Instance
		if UNRELIABLE[name] then
			remote = Instance.new("UnreliableRemoteEvent")
		else
			remote = Instance.new("RemoteEvent")
		end
		remote.Name = name
		remote.Parent = created
	end

	created.Parent = ReplicatedStorage
	folder = created
	return created
end

local function container(): Folder
	if folder then
		return folder
	end
	local found = ReplicatedStorage:WaitForChild(FOLDER_NAME, 30)
	assert(found and found:IsA("Folder"), "MowRemotes folder never appeared")
	folder = found
	return found
end

--- A reliable remote by name. Yields on the client until the server creates it.
function Remotes.event(name: string): RemoteEvent
	local remote = container():WaitForChild(name, 30)
	assert(remote and remote:IsA("RemoteEvent"), `remote {name} is missing or the wrong class`)
	return remote
end

--- The unreliable mow-intent channel.
function Remotes.unreliable(name: string): UnreliableRemoteEvent
	local remote = container():WaitForChild(name, 30)
	assert(remote and remote:IsA("UnreliableRemoteEvent"), `remote {name} is missing or the wrong class`)
	return remote
end

return Remotes
