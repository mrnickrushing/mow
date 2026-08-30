--!strict
--[[
	BoostService — timed grants: rentals, cash boosts and server-wide events.

	One generic mechanism behind all of them, so "rent a zero-turn for two
	minutes" and "3x cash for five minutes" are config rows rather than new code,
	and any future timed product is a table entry.

	Nothing here is persisted. A boost is bought for a session and dies with it,
	which also means a disconnect can never duplicate one.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Tools = require(Shared.Config.Tools)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local VehicleService = require(script.Parent.VehicleService)

local BoostService = {}

export type Rental = {
	toolId: string,
	expiresAt: number,
	--- What they were holding before, so it can be handed back.
	previousToolId: string,
}

export type CashBoost = {
	multiplier: number,
	expiresAt: number,
}

local rentals: { [Player]: Rental } = {}
local cashBoosts: { [Player]: CashBoost } = {}
local serverBoost: { multiplier: number, expiresAt: number, buyer: string }? = nil

-- Fired when a grant starts or ends. PlayerService listens and pushes fresh
-- state; going the other way would make these two services mutually dependent.
local changedSignal = Instance.new("BindableEvent")
BoostService.Changed = changedSignal.Event

--------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------

local function alive(expiresAt: number): boolean
	return os.clock() < expiresAt
end

--- The tool a rental is currently lending this player, if any.
function BoostService.rentedTool(player: Player): string?
	local rental = rentals[player]
	if rental and alive(rental.expiresAt) then
		return rental.toolId
	end
	return nil
end

function BoostService.rentalSecondsLeft(player: Player): number
	local rental = rentals[player]
	if not rental then
		return 0
	end
	return math.max(rental.expiresAt - os.clock(), 0)
end

function BoostService.cashMultiplier(player: Player): number
	local boost = cashBoosts[player]
	if boost and alive(boost.expiresAt) then
		return boost.multiplier
	end
	return 1
end

function BoostService.serverMultiplier(): number
	if serverBoost and alive(serverBoost.expiresAt) then
		return serverBoost.multiplier
	end
	return 1
end

function BoostService.serverBoostSecondsLeft(): number
	if not serverBoost then
		return 0
	end
	return math.max(serverBoost.expiresAt - os.clock(), 0)
end

--------------------------------------------------------------------
-- Granting
--------------------------------------------------------------------

--[[
	Lends a tool for `seconds`.

	The rental is granted through the same ownership table the shop writes to,
	so every existing check — equipping, cutting, mounting a vehicle — just works
	without knowing rentals exist. Expiry removes the grant and hands back
	whatever the player was holding before.
]]
function BoostService.grantRental(player: Player, toolId: string, seconds: number)
	local tool = Tools.get(toolId)
	local profile = DataService.get(player)
	if not tool or not profile then
		return
	end

	-- Someone who already owns it outright gets the time as a cash boost
	-- instead, rather than paying for something they have.
	if profile.ownedTools[toolId] and not rentals[player] then
		BoostService.grantCashBoost(player, 2, seconds)
		EconomyService.notify(player, "reward", `You already own the {tool.name} — have 2x cash instead`, nil)
		return
	end

	local existing = rentals[player]
	local previous = if existing then existing.previousToolId else profile.equippedTool

	profile.ownedTools[toolId] = true
	profile.equippedTool = toolId

	rentals[player] = {
		toolId = toolId,
		expiresAt = os.clock() + seconds,
		previousToolId = previous,
	}

	EconomyService.notify(player, "reward", `{tool.name} for {Format.clock(seconds)} — go`, nil)
	changedSignal:Fire(player)
end

function BoostService.grantCashBoost(player: Player, multiplier: number, seconds: number)
	local existing = cashBoosts[player]
	local base = if existing and alive(existing.expiresAt) then existing.expiresAt else os.clock()

	cashBoosts[player] = {
		multiplier = multiplier,
		-- Buying the same boost twice extends it rather than wasting the second.
		expiresAt = base + seconds,
	}
	EconomyService.notify(player, "reward", `{multiplier}x cash for {Format.clock(seconds)}`, nil)
	changedSignal:Fire(player)
end

function BoostService.grantServerBoost(buyer: Player, multiplier: number, seconds: number)
	local base = if serverBoost and alive(serverBoost.expiresAt) then serverBoost.expiresAt else os.clock()
	serverBoost = {
		multiplier = multiplier,
		expiresAt = base + seconds,
		buyer = buyer.DisplayName,
	}
	EconomyService.notifyAll(
		"reward",
		`{buyer.DisplayName} bought {multiplier}x cash for the whole server — {Format.clock(seconds)}`,
		nil
	)
end

--------------------------------------------------------------------
-- Expiry
--------------------------------------------------------------------

local function expireRental(player: Player)
	local rental = rentals[player]
	if not rental then
		return
	end
	rentals[player] = nil

	local profile = DataService.get(player)
	if not profile then
		return
	end

	profile.ownedTools[rental.toolId] = nil
	if profile.equippedTool == rental.toolId then
		profile.equippedTool = rental.previousToolId
	end

	-- If they are sitting on the rented mower, put them back on their feet.
	VehicleService.dismount(player)

	local tool = Tools.get(rental.toolId)
	EconomyService.notify(player, "stall", `The {if tool then tool.name else "rental"} went back to the shop`, nil)
	changedSignal:Fire(player)
end

function BoostService.start()
	Players.PlayerRemoving:Connect(function(player)
		rentals[player] = nil
		cashBoosts[player] = nil
	end)

	-- Rentals are advertised in seconds, so a one-second tick is precise enough
	-- and costs nothing.
	task.spawn(function()
		while true do
			task.wait(1)
			for player, rental in rentals do
				if not alive(rental.expiresAt) then
					expireRental(player)
				end
			end
			for player, boost in cashBoosts do
				if not alive(boost.expiresAt) then
					cashBoosts[player] = nil
				end
			end
			if serverBoost and not alive(serverBoost.expiresAt) then
				serverBoost = nil
			end
		end
	end)

	-- Feed the multiplier stack rather than being consulted by it directly.
	EconomyService.addModifierSource(function(player: Player)
		return {
			cashBoost = BoostService.cashMultiplier(player),
			serverBoost = BoostService.serverMultiplier(),
		}
	end)
end

return BoostService
