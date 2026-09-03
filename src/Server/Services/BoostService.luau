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
local RunState = require(script.Parent.RunState)
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
	local run = RunState.find(player)
	if not tool or not run then
		return
	end

	-- Someone who already owns it outright gets the time as a cash boost
	-- instead, rather than paying for something they have.
	if run.ownedTools[toolId] and not rentals[player] then
		BoostService.grantCashBoost(player, 2, seconds)
		EconomyService.notify(player, "reward", `You already own the {tool.name} — have 2x cash instead`, nil)
		return
	end

	local existing = rentals[player]

	-- Buying the same rental again tops it up rather than restarting the
	-- clock, the same way a cash boost stacks below. Otherwise topping up
	-- five seconds before it ran out would have thrown away whatever was
	-- left of the first purchase.
	if existing and existing.toolId == toolId then
		existing.expiresAt = math.max(existing.expiresAt, os.clock()) + seconds
		EconomyService.notify(player, "reward", `{tool.name} extended — {Format.clock(seconds)} more`, nil)
		changedSignal:Fire(player)
		return
	end

	--[[
		A different rental was already running underneath this one.

		`rentals` holds one entry per player, so buying a second rental before
		the first ran out simply replaced it — the old tool's `ownedTools`
		flag was set by `grantRental` and nothing ever cleared it again,
		because `expireRental` and `carryRentals` only ever look at whatever
		is in `rentals[player]` right now. The old tool became permanently
		owned for the rest of the run, for whatever the *rental* cost rather
		than what owning it costs: renting the Zero-Turn (49 Robux) and then
		the Riding Mower (25 Robux) before the first ran out left a Zero-Turn
		— 260 Robux to own for the run outright — sitting in the bag for
		free, with the Riding Mower still correctly expiring on schedule.

		Revoking the old one here, the same way its own expiry would have,
		closes that off: whichever rental is running is the only one that is
		ever "owned" by renting.
	]]
	if existing then
		run.ownedTools[existing.toolId] = nil
		if run.equippedTool == existing.toolId then
			run.equippedTool = existing.previousToolId
		end
	end

	local previous = if existing then existing.previousToolId else run.equippedTool

	run.ownedTools[toolId] = true
	run.equippedTool = toolId

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

	local run = RunState.find(player)
	if not run then
		return
	end

	run.ownedTools[rental.toolId] = nil
	if run.equippedTool == rental.toolId then
		run.equippedTool = rental.previousToolId
	end

	-- If they are sitting on the rented mower, put them back on their feet.
	VehicleService.dismount(player)

	local tool = Tools.get(rental.toolId)
	EconomyService.notify(player, "stall", `The {if tool then tool.name else "rental"} went back to the shop`, nil)
	changedSignal:Fire(player)
end

--[[
	Carries a live rental across a round rotation.

	`beginRun` calls `RunState.resetAll()`, and that is right for everything
	bought with run cash: a run starts from nothing. A rental is not that. It
	was bought with Robux and sold as a span of time — "Two minutes on the
	mower everybody wants" — so a round that rotates thirty seconds into it was
	quietly taking ninety seconds of paid-for time away.

	Worse than losing it silently: `rentals` kept ticking against a state that
	no longer had the tool, so the HUD counted down a rental the player did not
	have, and `expireRental` then wrote back a `previousToolId` belonging to a
	run that no longer existed — a tool they do not own, cannot cut with, and
	were never told about.

	The clock is not restarted. They get the time that is left.
]]
function BoostService.carryRentals()
	local now = os.clock()
	for player, rental in rentals do
		local run = RunState.find(player)
		if not run or rental.expiresAt <= now then
			rentals[player] = nil
		else
			-- What the fresh state starts them with is what the rental hands
			-- back when it runs out; the old run's tool is gone with the run.
			rental.previousToolId = run.equippedTool
			run.ownedTools[rental.toolId] = true
			run.equippedTool = rental.toolId
			changedSignal:Fire(player)
		end
	end
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
