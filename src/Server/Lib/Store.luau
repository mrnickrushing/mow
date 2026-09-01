--!strict
--[[
	Store — session-locked player saves on top of DataStoreService.

	Session locking is the whole point: without it, a player who joins two
	servers at once (or rejoins during a teleport) can have one server overwrite
	the other's save, which is exactly how duplication exploits start. Every load
	stamps a lock naming the owning server; another server refuses to load until
	the lock's heartbeat goes stale.

	When DataStores are unavailable — Studio without API access, or a live
	outage — the store falls back to memory so the game stays playable. Nothing
	persists in that mode and it says so loudly in the output.
]]

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local GameConfig = require(game:GetService("ReplicatedStorage").Shared.Config.GameConfig)

local Store = {}
Store.__index = Store

local MAX_ATTEMPTS = 4
local RETRY_BASE_SECONDS = 1
--- Attempts to acquire a held lock before giving up and stealing it.
local LOCK_ATTEMPTS = 5
local LOCK_WAIT_SECONDS = 3

export type Entry = {
	data: any,
	lockServer: string?,
	lockHeartbeat: number?,
}

export type Store = typeof(setmetatable(
	{} :: {
		name: string,
		store: DataStore?,
		serverId: string,
		--- userId -> loaded data, for profiles this server currently owns.
		active: { [number]: any },
		--- Populated instead of `store` when DataStores are unavailable.
		memoryOnly: boolean,
		memory: { [number]: any },
	},
	Store
))

local function keyFor(userId: number): string
	return `player_{userId}`
end

--- Retries a DataStore call with exponential backoff.
local function attempt<T>(label: string, fn: () -> T): (boolean, T?)
	local lastError: any = nil
	for tries = 1, MAX_ATTEMPTS do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastError = result
		if tries < MAX_ATTEMPTS then
			task.wait(RETRY_BASE_SECONDS * 2 ^ (tries - 1))
		end
	end
	warn(`[Store] {label} failed after {MAX_ATTEMPTS} attempts: {lastError}`)
	return false, nil
end

function Store.new(name: string): Store
	local self = setmetatable({
		name = name,
		store = nil :: DataStore?,
		serverId = if RunService:IsStudio() then `studio_{os.time()}` else game.JobId,
		active = {},
		memoryOnly = false,
		memory = {},
	}, Store)

	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(name)
	end)
	if ok and result then
		self.store = result
	else
		self.memoryOnly = true
		warn(`[Store] DataStores unavailable ({result}); running memory-only. Progress will NOT be saved.`)
	end

	return self
end

--- True when a lock belongs to another server and is still being refreshed.
local function lockIsLive(entry: Entry, serverId: string, now: number): boolean
	if not entry.lockServer or entry.lockServer == serverId then
		return false
	end
	local heartbeat = entry.lockHeartbeat or 0
	return now - heartbeat < GameConfig.SESSION_LOCK_TIMEOUT
end

--[[
	Loads a profile and takes the session lock.

	Returns nil only when the datastore is genuinely unreachable, in which case
	the caller should refuse to let the player play rather than hand them a fresh
	profile that will overwrite their real save.
]]
function Store.load(self: Store, userId: number): any?
	if self.memoryOnly then
		local existing = self.memory[userId]
		self.active[userId] = existing
		return existing
	end

	local store = self.store
	if not store then
		return nil
	end

	for tries = 1, LOCK_ATTEMPTS do
		--[[
			Studio takes the lock at once instead of queueing behind it.

			The lock exists so two real servers cannot both hold one player's
			save, which cannot happen in a Studio session — but every stopped
			play test leaves its lock behind, so the next test spent up to
			twelve seconds standing in a world it could not touch, waiting out
			its own predecessor, and got kicked outright if the throttled
			datastore then failed the final attempt. That is what "the controls
			are broken" looks like from inside the game.
		]]
		local stolen = tries == LOCK_ATTEMPTS or RunService:IsStudio()
		local ok, loaded = attempt(`load {userId}`, function()
			return store:UpdateAsync(keyFor(userId), function(raw: any)
				local entry: Entry = if type(raw) == "table" then raw else { data = nil }
				local now = os.time()

				-- On the final attempt the previous holder has had ample time to
				-- release; take the lock rather than lock the player out forever.
				if not stolen and lockIsLive(entry, self.serverId, now) then
					return nil
				end

				entry.lockServer = self.serverId
				entry.lockHeartbeat = now
				return entry
			end)
		end)

		if ok and loaded ~= nil then
			local entry = loaded :: Entry
			self.active[userId] = entry.data
			return entry.data
		end

		if tries < LOCK_ATTEMPTS then
			task.wait(LOCK_WAIT_SECONDS)
		end
	end

	warn(`[Store] could not acquire a session lock for {userId}`)
	return nil
end

--- Writes the profile back and refreshes the lock heartbeat.
function Store.save(self: Store, userId: number, data: any): boolean
	self.active[userId] = data

	if self.memoryOnly then
		self.memory[userId] = data
		return true
	end

	local store = self.store
	if not store then
		return false
	end

	local ok = attempt(`save {userId}`, function()
		return store:UpdateAsync(keyFor(userId), function(raw: any)
			local entry: Entry = if type(raw) == "table" then raw else {}
			-- Another server owns this profile now; drop our write rather than
			-- clobber whatever they have been doing with it.
			if entry.lockServer and entry.lockServer ~= self.serverId then
				return nil
			end
			entry.data = data
			entry.lockServer = self.serverId
			entry.lockHeartbeat = os.time()
			return entry
		end)
	end)

	return ok
end

--- Final write plus lock release, so another server can pick the player up.
function Store.release(self: Store, userId: number, data: any?): boolean
	local payload = data or self.active[userId]
	self.active[userId] = nil

	if self.memoryOnly then
		if payload ~= nil then
			self.memory[userId] = payload
		end
		return true
	end

	local store = self.store
	if not store then
		return false
	end

	local ok = attempt(`release {userId}`, function()
		return store:UpdateAsync(keyFor(userId), function(raw: any)
			local entry: Entry = if type(raw) == "table" then raw else {}
			if entry.lockServer and entry.lockServer ~= self.serverId then
				return nil
			end
			if payload ~= nil then
				entry.data = payload
			end
			entry.lockServer = nil
			entry.lockHeartbeat = nil
			return entry
		end)
	end)

	return ok
end

--- Releases every profile this server still holds. Call from BindToClose.
function Store.releaseAll(self: Store)
	local pending = {}
	for userId, data in self.active do
		table.insert(pending, { userId = userId, data = data })
	end

	local remaining = #pending
	if remaining == 0 then
		return
	end

	for _, item in pending do
		task.spawn(function()
			Store.release(self, item.userId, item.data)
			remaining -= 1
		end)
	end

	local deadline = os.clock() + 20
	while remaining > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end

return Store
