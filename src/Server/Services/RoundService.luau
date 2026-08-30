--!strict
--[[
	RoundService — the timer, the shared completion bar and the map rotation.

	A round is one property against a clock, with every player on the server
	working the same lawn. Reaching 100% ends it early and pays a bonus scaled by
	how much of the work each player actually did, then the map rotates to the
	largest property anyone present has earned.

	Cash and upgrades survive the rotation. The lawn does not.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local GameConfig = require(Shared.Config.GameConfig)
local Properties = require(Shared.Config.Properties)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)
local BagService = require(script.Parent.BagService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local ReplicationService = require(script.Parent.ReplicationService)
local TileService = require(script.Parent.TileService)
local WorldService = require(script.Parent.WorldService)

local RoundService = {}

export type Phase = "playing" | "intermission"

local phase: Phase = "playing"
local endsAt = 0
local roundIndex = 0
local propertyIndex = 1
--- Units cleared this round, per player, for the completion payout split.
local contribution: { [Player]: number } = {}

local roundState: RemoteEvent

--- How often round state is broadcast, in Hz. The client interpolates the timer.
local BROADCAST_HZ = 2

--------------------------------------------------------------------
-- State
--------------------------------------------------------------------

function RoundService.phase(): Phase
	return phase
end

function RoundService.secondsLeft(): number
	return math.max(endsAt - os.clock(), 0)
end

function RoundService.contributionOf(player: Player): number
	return contribution[player] or 0
end

local function totalContribution(): number
	local total = 0
	for _, units in contribution do
		total += units
	end
	return total
end

local function broadcast()
	local property = WorldService.property
	roundState:FireAllClients({
		phase = phase,
		secondsLeft = RoundService.secondsLeft(),
		completion = WorldService.completion(),
		propertyId = if property then property.id else "",
		propertyName = if property then property.name else "",
		roundIndex = roundIndex,
	})
end

RoundService.broadcast = broadcast

--------------------------------------------------------------------
-- Rotation
--------------------------------------------------------------------

--[[
	The next property to load.

	Picks from what the *most advanced player present* has unlocked, so a veteran
	is never held on the starter house by a newcomer, and cycles so the same map
	does not repeat back to back.
]]
local function chooseNextProperty(): Types.PropertyDef
	local best = 0
	for _, profile in DataService.all() do
		best = math.max(best, profile.lifetimeCash)
	end

	local unlocked = Properties.unlockedFor(best)
	if #unlocked == 0 then
		return Properties.expect(Properties.STARTER_ID)
	end

	propertyIndex += 1
	if propertyIndex > #unlocked then
		propertyIndex = 1
	end
	return unlocked[propertyIndex]
end

--------------------------------------------------------------------
-- Payout
--------------------------------------------------------------------

local function payOut(completed: boolean)
	local total = totalContribution()
	if total <= 0 then
		return
	end

	local pool = GameConfig.ROUND_COMPLETION_BONUS
	local property = WorldService.property
	if property then
		pool *= property.payoutMultiplier
	end
	if not completed then
		-- A round that ran out of clock still pays, but far less: finishing the
		-- job is the point.
		pool *= 0.35
	end

	for player, units in contribution do
		if player.Parent then
			local share = units / total
			local amount = pool * share
			EconomyService.award(player, amount)
			EconomyService.notify(
				player,
				"reward",
				`Round bonus {Format.cash(amount)} for {Format.percent(share)} of the work`,
				amount
			)

			DataService.withProfile(player, function(profile)
				if completed then
					profile.stats.roundsCompleted += 1
				end
			end)
		end
	end
end

--------------------------------------------------------------------
-- Flow
--------------------------------------------------------------------

local function startRound(property: Types.PropertyDef)
	roundIndex += 1
	table.clear(contribution)

	ReplicationService.reset()
	WorldService.load(property.id)
	ReplicationService.broadcastWorldInfo()

	-- The old map's clippings are gone with the map; keeping them would let a
	-- player bank a bag across a rotation and sell it at a richer property.
	BagService.clearAll()

	phase = "playing"
	endsAt = os.clock() + property.roundSeconds

	EconomyService.notifyAll("round", `{property.name} — {property.tagline}`, nil)
	broadcast()
end

local function finishRound(completed: boolean)
	if phase ~= "playing" then
		return
	end
	phase = "intermission"
	endsAt = os.clock() + GameConfig.INTERMISSION_SECONDS

	local property = WorldService.property
	if completed then
		EconomyService.notifyAll("round", `{if property then property.name else "The property"} is clear! 100%`, nil)
	else
		EconomyService.notifyAll("round", "Out of time — next property coming up", nil)
	end

	payOut(completed)
	broadcast()
end

RoundService.finishRound = finishRound

--- Ends the current round early and rotates. Used by the round-time product.
function RoundService.extend(seconds: number)
	if phase == "playing" then
		endsAt += seconds
		broadcast()
	end
end

function RoundService.start()
	roundState = Remotes.event(Remotes.ROUND_STATE)

	Players.PlayerRemoving:Connect(function(player)
		contribution[player] = nil
	end)

	Players.PlayerAdded:Connect(function()
		task.defer(broadcast)
	end)

	-- Credit whoever actually did the cutting, so the completion bonus is split
	-- by work rather than shared flat between everyone standing around.
	TileService.Cut:Connect(function(player: Player, _index: number, _debrisId: number, levels: number)
		contribution[player] = (contribution[player] or 0) + levels
	end)

	local startProperty = WorldService.property or Properties.expect(Properties.STARTER_ID)
	phase = "playing"
	endsAt = os.clock() + startProperty.roundSeconds

	task.spawn(function()
		while true do
			task.wait(1 / BROADCAST_HZ)

			if phase == "playing" then
				if WorldService.completion() >= 1 then
					finishRound(true)
				elseif RoundService.secondsLeft() <= 0 then
					finishRound(false)
				else
					broadcast()
				end
			else
				if RoundService.secondsLeft() <= 0 then
					startRound(chooseNextProperty())
				else
					broadcast()
				end
			end
		end
	end)
end

return RoundService
