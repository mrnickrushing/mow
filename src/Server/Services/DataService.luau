--!strict
--[[
	DataService — owns every player's profile for the lifetime of their session.

	Other services never touch the datastore; they ask here for a profile and
	mutate it in place. Saving is handled by a staggered autosave loop plus a
	release on leave and on server close.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local GameConfig = require(game:GetService("ReplicatedStorage").Shared.Config.GameConfig)
local DefaultData = require(script.Parent.Parent.Lib.DefaultData)
local Store = require(script.Parent.Parent.Lib.Store)

local DataService = {}

type Profile = DefaultData.Profile

local store: Store.Store
local profiles: { [Player]: Profile } = {}
local loading: { [Player]: boolean } = {}
--- Fired whenever a profile finishes loading, so services can react on join.
local loadedSignal = Instance.new("BindableEvent")

DataService.ProfileLoaded = loadedSignal.Event

local KICK_MESSAGE = "We could not load your save. Please rejoin in a moment — "
	.. "this protects your progress from being overwritten."

local function onPlayerAdded(player: Player)
	loading[player] = true

	local raw = Store.load(store, player.UserId)

	-- A brand new player legitimately has no saved data; only a hard datastore
	-- failure returns nil after a successful lock, and load() already warned.
	if raw == nil and not store.memoryOnly and store.store ~= nil and store.active[player.UserId] == nil then
		loading[player] = nil
		if player.Parent then
			player:Kick(KICK_MESSAGE)
		end
		return
	end

	local profile = DefaultData.migrate(raw)
	loading[player] = nil

	-- They may have left while we were loading.
	if not player.Parent then
		Store.release(store, player.UserId, profile)
		return
	end

	profiles[player] = profile
	loadedSignal:Fire(player, profile)
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	profiles[player] = nil
	loading[player] = nil
	Store.release(store, player.UserId, profile)
end

--------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------

--- The player's profile, or nil while it is still loading.
function DataService.get(player: Player): Profile?
	return profiles[player]
end

--- Waits up to `timeout` seconds for a profile to finish loading.
function DataService.await(player: Player, timeout: number?): Profile?
	local deadline = os.clock() + (timeout or 15)
	while os.clock() < deadline do
		local profile = profiles[player]
		if profile then
			return profile
		end
		if not player.Parent then
			return nil
		end
		task.wait(0.1)
	end
	return nil
end

--- Runs `fn` against the profile if it is loaded. Returns whether it ran.
function DataService.withProfile(player: Player, fn: (Profile) -> ()): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	fn(profile)
	return true
end

function DataService.save(player: Player): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	return Store.save(store, player.UserId, profile)
end

--- Every currently loaded profile, for round payouts and leaderboards.
function DataService.all(): { [Player]: Profile }
	return profiles
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

function DataService.start()
	store = Store.new(GameConfig.DATASTORE_NAME)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayerAdded, player)
	end)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Autosave spreads writes across the interval rather than saving everyone on
	-- the same frame, which would spike request throughput on a full server.
	task.spawn(function()
		while true do
			local players = Players:GetPlayers()
			local count = #players
			if count == 0 then
				task.wait(5)
				continue
			end

			local spacing = GameConfig.AUTOSAVE_SECONDS / count
			for _, player in players do
				task.wait(spacing)
				if profiles[player] then
					DataService.save(player)
				end
			end
		end
	end)

	game:BindToClose(function()
		if RunService:IsStudio() then
			return
		end
		Store.releaseAll(store)
	end)
end

return DataService
